// Package auth is the panel's sign-in: a password and a mandatory second factor for every account (requirement 2),
// sessions, and limits on guessing.
//
// Signing in to the panel never signs a statement: that needs a key in wmanager-sign (docs/architecture.md).
//
// Guessing is limited in three ways:
//   - per address: PerAddress attempts a minute (an IPv6 address counts by its /64);
//   - wrong passwords slow down further attempts at that account from that address only, so nobody can lock
//     another person out by typing wrong passwords for them;
//   - wrong second-factor codes, which need the right password first, lock the account, each lockout twice as
//     long as the one before (from LockFor up to MaxLock), until the account signs in.
//
// Every answer to a password attempt that isn't right, for an unknown address, a wrong password or one slowed
// down, is the same ErrSignIn after the same work, so the answers don't tell which e-mail addresses have
// accounts.
package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// Limits of sign-in.
const (
	PerAddress       = 20 // attempts per address (IPv6: per /64) per minute
	FreePasswords    = 5  // wrong passwords for one account from one address before slowing down
	MaxPasswordDelay = 15 * time.Minute
	MaxFailures      = 5 // wrong second-factor codes in a row before a lockout
	LockFor          = 15 * time.Minute
	MaxLock          = 24 * time.Hour
	PasswordStage    = 10 * time.Minute // time to give the second factor after the password
	SessionIdle      = 8 * time.Hour    // a session not used for this long ends
	SessionMax       = 7 * 24 * time.Hour
	touchEvery       = time.Minute
	addressWindow    = time.Minute
	forgetAfter      = time.Hour
	maxEmailLength   = 254
)

// Errors of sign-in. ErrSignIn doesn't say whether the e-mail address or the password was wrong.
var (
	ErrSignIn       = errors.New("auth: wrong e-mail address or password")
	ErrCode         = errors.New("auth: wrong code")
	ErrLocked       = errors.New("auth: too many wrong codes, the account is locked for a while")
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
	addresses map[string]*window   // attempts per address in the current minute
	passwords map[string]*slowdown // wrong passwords per account and address
	swept     time.Time
}

type window struct {
	start time.Time
	n     int
}

type slowdown struct {
	failures int
	until    time.Time
	last     time.Time
}

// New returns the service.
func New(s *store.Store) *Service {
	return &Service{Store: s, Now: time.Now, addresses: map[string]*window{}, passwords: map[string]*slowdown{}}
}

// addressKey is what the limit per address counts: an IPv4 address, or the /64 of an IPv6 one, which one
// connection usually has whole.
func addressKey(addr string) string {
	host := addr
	if h, _, err := net.SplitHostPort(addr); err == nil {
		host = h
	}
	ip := net.ParseIP(host)
	switch {
	case ip == nil:
		return host
	case ip.To4() != nil:
		return ip.To4().String()
	}
	return ip.Mask(net.CIDRMask(64, 128)).String() + "/64"
}

// allow counts an attempt from an address and refuses more than PerAddress a minute.
func (s *Service) allow(addr string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.Now()
	if now.Sub(s.swept) > addressWindow {
		for a, w := range s.addresses {
			if now.Sub(w.start) > addressWindow {
				delete(s.addresses, a)
			}
		}
		for k, d := range s.passwords {
			if now.Sub(d.last) > forgetAfter && now.After(d.until) {
				delete(s.passwords, k)
			}
		}
		s.swept = now
	}
	key := addressKey(addr)
	w := s.addresses[key]
	if w == nil || now.Sub(w.start) > addressWindow {
		w = &window{start: now}
		s.addresses[key] = w
	}
	w.n++
	if w.n > PerAddress {
		return ErrTooMany
	}
	return nil
}

func passwordKey(email, addr string) string { return email + "\x00" + addressKey(addr) }

// slowed tells whether password attempts at this account from this address are on hold.
func (s *Service) slowed(key string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.passwords[key]
	return d != nil && s.Now().Before(d.until)
}

// wrongPassword counts a wrong password; after FreePasswords each one doubles the wait, up to MaxPasswordDelay.
func (s *Service) wrongPassword(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.Now()
	d := s.passwords[key]
	if d == nil {
		d = &slowdown{}
		s.passwords[key] = d
	}
	d.failures++
	d.last = now
	if over := d.failures - FreePasswords; over > 0 {
		d.until = now.Add(min(time.Second<<min(over-1, 20), MaxPasswordDelay))
	}
}

func (s *Service) rightPassword(key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.passwords, key)
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
	lockouts        int
	lockedUntil     *time.Time
}

func loadAccount(ctx context.Context, q interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, where string, lock bool, arg any) (*accountRow, error) {
	sql := `SELECT id, email, password_hash, is_owner, disabled, totp_secret, totp_last_step, failed_codes, lockouts,
	               locked_until
	        FROM accounts WHERE ` + where
	if lock {
		sql += ` FOR UPDATE`
	}
	var a accountRow
	err := q.QueryRow(ctx, sql, arg).Scan(&a.id, &a.email, &a.hash, &a.owner, &a.disabled, &a.totp, &a.lastStep,
		&a.failures, &a.lockouts, &a.lockedUntil)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &a, err
}

func (s *Service) locked(a *accountRow) bool {
	return a.lockedUntil != nil && s.Now().Before(*a.lockedUntil)
}

// SignIn checks the e-mail address and password. It returns a session token at the password step: the second
// factor (SecondFactor) or, for an account without one, setting it up (BeginTOTP, ConfirmTOTP) comes next.
//
// The password is hashed outside any transaction, so a flood of attempts holds no database connection or row.
func (s *Service) SignIn(ctx context.Context, addr, email, password string) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	// A failure is recorded even when the request goes away half-way.
	ctx = context.WithoutCancel(ctx)
	email = NormalizeEmail(email)
	if len(email) > maxEmailLength {
		return "", ErrSignIn
	}
	var a *accountRow
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		var err error
		a, err = loadAccount(ctx, tx, "email = $1", false, email)
		return err
	})
	if err != nil {
		return "", err
	}
	key := passwordKey(email, addr)
	// Every attempt that fails does the same work: one hash and one audit entry.
	failed := func(actor string, details map[string]any) (string, error) {
		details["step"], details["address"] = "password", addressKey(addr)
		err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
			_, err := audit.Append(ctx, tx, audit.ServerChain, "", actor, "signin.failed", details)
			return err
		})
		if err != nil {
			return "", err
		}
		return "", ErrSignIn
	}
	if a == nil {
		checkPassword(ctx, dummyHash, password)
		// Not the address typed: people type passwords into the wrong field.
		return failed("system", map[string]any{"account": "unknown"})
	}
	if s.slowed(key) {
		checkPassword(ctx, dummyHash, password)
		return failed("account:"+a.id, map[string]any{"email": a.email, "slowed": true})
	}
	ok, err := checkPassword(ctx, a.hash, password)
	if err != nil {
		return "", err
	}
	if !ok || a.disabled {
		s.wrongPassword(key)
		return failed("account:"+a.id, map[string]any{"email": a.email})
	}
	s.rightPassword(key)
	if s.locked(a) {
		return "", ErrLocked // only with the right password, so it tells nothing to a guesser
	}
	token, hash := newToken()
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO sessions (token_hash, account_id, stage, expires_at)
		                        VALUES ($1, $2, 'password', $3)`, hash, a.id, s.Now().Add(PasswordStage))
		return err
	})
	if err != nil {
		return "", err
	}
	return token, nil
}

type sessionRow struct {
	accountID, stage string
	seen, expires    time.Time
	pending          []byte
}

func (s *Service) loadSession(ctx context.Context, tx pgx.Tx, token string) (*sessionRow, error) {
	var r sessionRow
	err := tx.QueryRow(ctx, `SELECT account_id, stage, last_seen, expires_at, pending_totp
	                         FROM sessions WHERE token_hash = $1 FOR UPDATE`, tokenHash(token)).
		Scan(&r.accountID, &r.stage, &r.seen, &r.expires, &r.pending)
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

// codeFailure counts a wrong second-factor code. After MaxFailures it locks the account, each lockout since the
// last sign-in twice as long as the one before. It returns the answer to give.
func (s *Service) codeFailure(ctx context.Context, tx pgx.Tx, a *accountRow, step string) (answer, err error) {
	a.failures++
	answer = ErrCode
	details := map[string]any{"email": a.email, "step": step}
	var until any
	if a.failures >= MaxFailures {
		d := min(LockFor<<min(a.lockouts, 16), MaxLock)
		t := s.Now().Add(d)
		until, answer = t, ErrLocked
		a.failures, a.lockouts = 0, a.lockouts+1
		details["locked_until"] = t.UTC().Format(time.RFC3339)
		details["lockouts"] = a.lockouts
	}
	if _, err := tx.Exec(ctx, `UPDATE accounts SET failed_codes = $2, lockouts = $3, locked_until = coalesce($4, locked_until)
	                           WHERE id = $1`, a.id, a.failures, a.lockouts, until); err != nil {
		return nil, err
	}
	action := "signin.failed"
	if answer == ErrLocked {
		action = "signin.locked"
	}
	if _, err := audit.Append(ctx, tx, audit.ServerChain, "", "account:"+a.id, action, details); err != nil {
		return nil, err
	}
	return answer, nil
}

// atPasswordStep loads a session at the password step and its account, locked for update. answer is set when
// the attempt ends there.
func (s *Service) atPasswordStep(ctx context.Context, tx pgx.Tx, token string) (r *sessionRow, a *accountRow, answer, err error) {
	r, err = s.loadSession(ctx, tx, token)
	if errors.Is(err, ErrNoSession) {
		return nil, nil, err, nil
	}
	if err != nil {
		return nil, nil, nil, err
	}
	if r.stage != "password" {
		return nil, nil, ErrWrongStage, nil
	}
	a, err = loadAccount(ctx, tx, "id = $1", true, r.accountID)
	if err != nil {
		return nil, nil, nil, err
	}
	if a == nil || a.disabled {
		return nil, nil, ErrNoSession, nil
	}
	if s.locked(a) {
		return nil, nil, ErrLocked, nil
	}
	return r, a, nil, nil
}

// SecondFactor takes a TOTP code or a recovery code at the password step. It returns the token of the full
// session, which replaces the one given.
func (s *Service) SecondFactor(ctx context.Context, addr, token, code string) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	ctx = context.WithoutCancel(ctx)
	var full string
	var answer error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, a, ans, err := s.atPasswordStep(ctx, tx, token)
		if err != nil || ans != nil {
			answer = ans
			return err
		}
		if a.totp == nil {
			answer = ErrNeedsTOTP
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
				answer, err = s.codeFailure(ctx, tx, a, "recovery code")
				return err
			}
			how = "recovery code"
		} else {
			answer, err = s.codeFailure(ctx, tx, a, "code")
			return err
		}
		full, err = s.makeFull(ctx, tx, token, a, how)
		return err
	})
	if err != nil {
		return "", err
	}
	if answer != nil {
		return "", answer
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
	if _, err := tx.Exec(ctx, `UPDATE accounts SET failed_codes = 0, lockouts = 0, locked_until = NULL WHERE id = $1`,
		a.id); err != nil {
		return "", err
	}
	_, err := audit.Append(ctx, tx, audit.ServerChain, "", "account:"+a.id, "signin",
		map[string]any{"email": a.email, "second_factor": how})
	return full, err
}

// BeginTOTP offers a new TOTP secret to an account that has none, at the password step. It returns the
// otpauth:// address for the QR code.
//
// Until an account sets up its second factor, its password alone gets this far: give a new account's password
// only to its person, who signs in at once (one-time links to set up an account come with the panel, stage 1b).
func (s *Service) BeginTOTP(ctx context.Context, token string) (string, error) {
	var url string
	var answer error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, a, ans, err := s.atPasswordStep(ctx, tx, token)
		if err != nil || ans != nil {
			answer = ans
			return err
		}
		if a.totp != nil {
			answer = ErrHasTOTP
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
	if answer != nil {
		return "", answer
	}
	return url, nil
}

// ConfirmTOTP takes the first code from the new secret and keeps the secret. It returns the token of the full
// session, which replaces the one given, and the recovery codes, shown once.
func (s *Service) ConfirmTOTP(ctx context.Context, addr, token, code string) (string, []string, error) {
	if err := s.allow(addr); err != nil {
		return "", nil, err
	}
	ctx = context.WithoutCancel(ctx)
	var full string
	var codes []string
	var answer error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, a, ans, err := s.atPasswordStep(ctx, tx, token)
		if err != nil || ans != nil {
			answer = ans
			return err
		}
		if a.totp != nil {
			answer = ErrHasTOTP
			return nil
		}
		if r.pending == nil {
			answer = ErrNoSuchSecret
			return nil
		}
		step, ok := checkTOTP(r.pending, code, s.Now(), 0)
		if !ok {
			answer, err = s.codeFailure(ctx, tx, a, "new code")
			return err
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
	if answer != nil {
		return "", nil, answer
	}
	return full, codes, nil
}

// Lookup returns the session of a token. A full session's last use is updated at most once a minute.
func (s *Service) Lookup(ctx context.Context, token string) (Session, error) {
	var out Session
	var answer error
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if errors.Is(err, ErrNoSession) {
			answer = err
			return nil
		}
		if err != nil {
			return err
		}
		var disabled bool
		var totp []byte
		if err := tx.QueryRow(ctx, `SELECT email, is_owner, disabled, totp_secret FROM accounts WHERE id = $1`,
			r.accountID).Scan(&out.Email, &out.IsOwner, &disabled, &totp); err != nil {
			return err
		}
		if disabled {
			answer = ErrNoSession
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
	if answer != nil {
		return Session{}, answer
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
