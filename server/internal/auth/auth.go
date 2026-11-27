// Package auth is the panel's sign-in: a password and a mandatory second factor for every account (requirement 2),
// sessions, a lockout after failed attempts and a limit per address.
//
// Signing in to the panel never signs a statement: that needs a key in wmanager-sign (docs/architecture.md).
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// Limits of sign-in.
const (
	MaxFailures    = 10               // failed attempts in a row before the account is locked
	LockFor        = 15 * time.Minute // how long a lockout lasts
	PasswordStage  = 10 * time.Minute // time to give the second factor after the password
	SessionIdle    = 8 * time.Hour    // a session not used for this long ends
	SessionMax     = 7 * 24 * time.Hour
	PerAddress     = 20 // attempts per address per minute
	touchEvery     = time.Minute
	addressWindow  = time.Minute
	maxEmailLength = 254
)

// Errors of sign-in. ErrSignIn doesn't say whether the e-mail address or the password was wrong.
var (
	ErrSignIn       = errors.New("auth: wrong e-mail address or password")
	ErrCode         = errors.New("auth: wrong code")
	ErrLocked       = errors.New("auth: too many failed attempts, the account is locked for a while")
	ErrTooMany      = errors.New("auth: too many attempts from this address, try again in a minute")
	ErrNoSession    = errors.New("auth: no session, or it has ended")
	ErrNeedsTOTP    = errors.New("auth: the account has no second factor yet")
	ErrHasTOTP      = errors.New("auth: the account already has a second factor")
	ErrWrongStage   = errors.New("auth: the session is not at that step")
	ErrNoSuchSecret = errors.New("auth: start setting up the second factor first")
)

// Service signs people in.
type Service struct {
	Store *store.Store
	Now   func() time.Time

	mu        sync.Mutex
	addresses map[string]*window
}

type window struct {
	start time.Time
	n     int
}

// New returns the service.
func New(s *store.Store) *Service {
	return &Service{Store: s, Now: time.Now, addresses: map[string]*window{}}
}

// allow counts an attempt from an address and refuses more than PerAddress a minute.
func (s *Service) allow(addr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.Now()
	for a, w := range s.addresses {
		if now.Sub(w.start) > addressWindow {
			delete(s.addresses, a)
		}
	}
	w := s.addresses[addr]
	if w == nil {
		w = &window{start: now}
		s.addresses[addr] = w
	}
	w.n++
	if w.n > PerAddress {
		return ErrTooMany
	}
	return nil
}

// Session is a signed-in browser.
type Session struct {
	AccountID string
	Email     string
	IsOwner   bool
	Full      bool // the second factor is given
	HasTOTP   bool
}

func newToken() (token string, hash []byte) {
	raw := make([]byte, 32)
	rand.Read(raw)
	token = base64.RawURLEncoding.EncodeToString(raw)
	return token, tokenHash(token)
}

func tokenHash(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// NormalizeEmail is the form an e-mail address is kept in.
func NormalizeEmail(e string) string { return strings.ToLower(strings.TrimSpace(e)) }

type accountRow struct {
	id, email, hash string
	owner, disabled bool
	totp            []byte
	lastStep        int64
	failures        int
	lockedUntil     *time.Time
}

func loadAccount(ctx context.Context, tx pgx.Tx, where string, arg any) (*accountRow, error) {
	var a accountRow
	err := tx.QueryRow(ctx, `SELECT id, email, password_hash, is_owner, disabled, totp_secret, totp_last_step,
	                                failed_signins, locked_until
	                         FROM accounts WHERE `+where+` FOR UPDATE`, arg).
		Scan(&a.id, &a.email, &a.hash, &a.owner, &a.disabled, &a.totp, &a.lastStep, &a.failures, &a.lockedUntil)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &a, err
}

// failure counts a failed attempt and locks the account after MaxFailures. It returns the error to give.
func (s *Service) failure(ctx context.Context, tx pgx.Tx, a *accountRow, what string, wrong error) error {
	a.failures++
	var lock any
	result := wrong
	details := map[string]any{"email": a.email, "step": what}
	if a.failures >= MaxFailures {
		until := s.Now().Add(LockFor)
		lock, a.failures, result = until, 0, ErrLocked
		details["locked_until"] = until.UTC().Format(time.RFC3339)
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET failed_signins = $2, locked_until = coalesce($3, locked_until)
	                           WHERE id = $1`, a.id, a.failures, lock); err != nil {
		return err
	}
	action := "signin.failed"
	if result == ErrLocked {
		action = "signin.locked"
	}
	if _, err := audit.Append(ctx, tx, audit.ServerChain, "", "account:"+a.id, action, details); err != nil {
		return err
	}
	return result
}

func (s *Service) locked(a *accountRow) bool {
	return a.lockedUntil != nil && s.Now().Before(*a.lockedUntil)
}

// SignIn checks the e-mail address and password. It returns a session token at the password step: the second
// factor (SecondFactor) or, for an account without one, setting it up (BeginTOTP, ConfirmTOTP) comes next.
func (s *Service) SignIn(ctx context.Context, addr, email, password string) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	email = NormalizeEmail(email)
	if len(email) > maxEmailLength {
		return "", ErrSignIn
	}
	var token string
	var result error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		a, err := loadAccount(ctx, tx, "email = $1", email)
		if err != nil {
			return err
		}
		if a == nil {
			checkPassword(ctx, dummyHash, password) // the same time as for an account
			result = ErrSignIn
			return nil
		}
		if s.locked(a) {
			result = ErrLocked
			return nil
		}
		ok, err := checkPassword(ctx, a.hash, password)
		if err != nil {
			return err
		}
		if !ok || a.disabled {
			result = s.failure(ctx, tx, a, "password", ErrSignIn)
			return nil
		}
		var hash []byte
		token, hash = newToken()
		_, err = tx.Exec(ctx, `INSERT INTO sessions (token_hash, account_id, stage, expires_at)
		                       VALUES ($1, $2, 'password', $3)`, hash, a.id, s.Now().Add(PasswordStage))
		return err
	})
	if err != nil {
		return "", err
	}
	if result != nil {
		return "", result
	}
	return token, nil
}

type sessionRow struct {
	accountID, stage string
	created, seen    time.Time
	expires          time.Time
	pending          []byte
}

func (s *Service) loadSession(ctx context.Context, tx pgx.Tx, token string) (*sessionRow, error) {
	var r sessionRow
	err := tx.QueryRow(ctx, `SELECT account_id, stage, created_at, last_seen, expires_at, pending_totp
	                         FROM sessions WHERE token_hash = $1 FOR UPDATE`, tokenHash(token)).
		Scan(&r.accountID, &r.stage, &r.created, &r.seen, &r.expires, &r.pending)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNoSession
	}
	if err != nil {
		return nil, err
	}
	now := s.Now()
	if now.After(r.expires) || (r.stage == "full" && now.Sub(r.seen) > SessionIdle) {
		if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash(token)); err != nil {
			return nil, err
		}
		return nil, ErrNoSession
	}
	return &r, nil
}

// SecondFactor takes a TOTP code or a recovery code at the password step. It returns the token of the full
// session, which replaces the one given.
func (s *Service) SecondFactor(ctx context.Context, addr, token, code string) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	var full string
	var result error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if err != nil {
			result = err
			return nil
		}
		if r.stage != "password" {
			result = ErrWrongStage
			return nil
		}
		a, err := loadAccount(ctx, tx, "id = $1", r.accountID)
		if err != nil {
			return err
		}
		if a == nil || a.disabled {
			result = ErrNoSession
			return nil
		}
		if a.totp == nil {
			result = ErrNeedsTOTP
			return nil
		}
		if s.locked(a) {
			result = ErrLocked
			return nil
		}
		how := "totp"
		if step, ok := checkTOTP(a.totp, code, s.Now(), a.lastStep); ok {
			if _, err := tx.Exec(ctx, `UPDATE accounts SET totp_last_step = $2 WHERE id = $1`, a.id, step); err != nil {
				return err
			}
		} else if looksLikeRecoveryCode(code) {
			tag, err := tx.Exec(ctx, `UPDATE recovery_codes SET used_at = now()
			                          WHERE account_id = $1 AND code_hash = $2 AND used_at IS NULL`, a.id, recoveryHash(code))
			if err != nil {
				return err
			}
			if tag.RowsAffected() != 1 {
				result = s.failure(ctx, tx, a, "recovery code", ErrCode)
				return nil
			}
			how = "recovery code"
		} else {
			result = s.failure(ctx, tx, a, "code", ErrCode)
			return nil
		}
		full, err = s.makeFull(ctx, tx, token, a, how)
		return err
	})
	if err != nil {
		return "", err
	}
	if result != nil {
		return "", result
	}
	return full, nil
}

// makeFull replaces the session at the password step with a full one under a new token: a token seen before the
// second factor is worth nothing after it.
func (s *Service) makeFull(ctx context.Context, tx pgx.Tx, token string, a *accountRow, how string) (string, error) {
	now := s.Now()
	if _, err := tx.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash(token)); err != nil {
		return "", err
	}
	full, hash := newToken()
	if _, err := tx.Exec(ctx, `INSERT INTO sessions (token_hash, account_id, stage, last_seen, expires_at)
	                           VALUES ($1, $2, 'full', $3, $4)`, hash, a.id, now, now.Add(SessionMax)); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET failed_signins = 0, locked_until = NULL WHERE id = $1`, a.id); err != nil {
		return "", err
	}
	_, err := audit.Append(ctx, tx, audit.ServerChain, "", "account:"+a.id, "signin",
		map[string]any{"email": a.email, "second_factor": how})
	return full, err
}

// BeginTOTP offers a new TOTP secret to an account that has none, at the password step. It returns the
// otpauth:// address for the QR code.
func (s *Service) BeginTOTP(ctx context.Context, token string) (string, error) {
	var url string
	var result error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if err != nil {
			result = err
			return nil
		}
		if r.stage != "password" {
			result = ErrWrongStage
			return nil
		}
		a, err := loadAccount(ctx, tx, "id = $1", r.accountID)
		if err != nil {
			return err
		}
		if a == nil {
			result = ErrNoSession
			return nil
		}
		if a.totp != nil {
			result = ErrHasTOTP
			return nil
		}
		secret := newTOTPSecret()
		if _, err := tx.Exec(ctx, `UPDATE sessions SET pending_totp = $2 WHERE token_hash = $1`,
			tokenHash(token), secret); err != nil {
			return err
		}
		url = TOTPURL(secret, a.email)
		return nil
	})
	if err != nil {
		return "", err
	}
	return url, result
}

// ConfirmTOTP takes the first code from the new secret and keeps the secret. It returns the token of the full
// session, which replaces the one given, and the recovery codes, shown once.
func (s *Service) ConfirmTOTP(ctx context.Context, addr, token, code string) (string, []string, error) {
	if err := s.allow(addr); err != nil {
		return "", nil, err
	}
	var full string
	var codes []string
	var result error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if err != nil {
			result = err
			return nil
		}
		if r.stage != "password" {
			result = ErrWrongStage
			return nil
		}
		if r.pending == nil {
			result = ErrNoSuchSecret
			return nil
		}
		a, err := loadAccount(ctx, tx, "id = $1", r.accountID)
		if err != nil {
			return err
		}
		if a == nil || a.disabled {
			result = ErrNoSession
			return nil
		}
		if a.totp != nil {
			result = ErrHasTOTP
			return nil
		}
		step, ok := checkTOTP(r.pending, code, s.Now(), 0)
		if !ok {
			result = s.failure(ctx, tx, a, "new code", ErrCode)
			return nil
		}
		if _, err := tx.Exec(ctx, `UPDATE accounts SET totp_secret = $2, totp_last_step = $3 WHERE id = $1`,
			a.id, r.pending, step); err != nil {
			return err
		}
		var hashes [][]byte
		codes, hashes = newRecoveryCodes()
		if _, err := tx.Exec(ctx, `DELETE FROM recovery_codes WHERE account_id = $1`, a.id); err != nil {
			return err
		}
		for _, h := range hashes {
			if _, err := tx.Exec(ctx, `INSERT INTO recovery_codes (account_id, code_hash) VALUES ($1, $2)`,
				a.id, h); err != nil {
				return err
			}
		}
		if _, err := audit.Append(ctx, tx, audit.ServerChain, "", "account:"+a.id, "totp.set",
			map[string]any{"email": a.email}); err != nil {
			return err
		}
		full, err = s.makeFull(ctx, tx, token, a, "totp")
		return err
	})
	if err != nil {
		return "", nil, err
	}
	if result != nil {
		return "", nil, result
	}
	return full, codes, nil
}

// Lookup returns the session of a token. A full session's last use is updated at most once a minute.
func (s *Service) Lookup(ctx context.Context, token string) (Session, error) {
	var out Session
	var result error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if err != nil {
			result = err
			return nil
		}
		var disabled bool
		var totp []byte
		if err := tx.QueryRow(ctx, `SELECT email, is_owner, disabled, totp_secret FROM accounts WHERE id = $1`,
			r.accountID).Scan(&out.Email, &out.IsOwner, &disabled, &totp); err != nil {
			return err
		}
		if disabled {
			result = ErrNoSession
			return nil
		}
		out.AccountID, out.Full, out.HasTOTP = r.accountID, r.stage == "full", totp != nil
		if out.Full && s.Now().Sub(r.seen) > touchEvery {
			_, err = tx.Exec(ctx, `UPDATE sessions SET last_seen = $2 WHERE token_hash = $1`, tokenHash(token), s.Now())
		}
		return err
	})
	if err != nil {
		return Session{}, err
	}
	if result != nil {
		return Session{}, result
	}
	return out, nil
}

// SignOut ends a session.
func (s *Service) SignOut(ctx context.Context, token string) error {
	return s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM sessions WHERE token_hash = $1`, tokenHash(token))
		return err
	})
}
