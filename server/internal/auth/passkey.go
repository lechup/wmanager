package auth

import (
	"bytes"
	"context"
	jsonv1 "encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
	"unicode"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// A passkey is the other second factor, next to TOTP (requirement 2). It signs in to the panel only: signing a
// statement needs a key in wmanager-sign, under another relying party id that no web page can claim.

// RP is the relying party the panel is: its origin as browsers see it (https://host[:port]) and its id (the host).
type RP struct {
	ID, Origin string
}

// RPFor makes the relying party from the panel's public address.
func RPFor(publicURL string) (RP, error) {
	u, err := url.Parse(publicURL)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" {
		return RP{}, fmt.Errorf("auth: %q is not an https address", publicURL)
	}
	return RP{ID: u.Hostname(), Origin: "https://" + u.Host}, nil
}

func (rp RP) webauthn() (*webauthn.WebAuthn, error) {
	return webauthn.New(&webauthn.Config{
		RPID:          rp.ID,
		RPDisplayName: "wmanager",
		RPOrigins:     []string{rp.Origin},
	})
}

// Errors of passkeys.
var (
	ErrPasskey     = errors.New("auth: the passkey was not accepted")
	ErrNoPasskeys  = errors.New("auth: the account has no passkey")
	ErrBadName     = errors.New("auth: a passkey's name has 1 to 60 printable characters")
	ErrNoCeremony  = errors.New("auth: start with the passkey's first step")
	ErrNoSuchKey   = errors.New("auth: no such passkey")
	ceremonyLength = 5 * time.Minute
)

// Passkey is one passkey of an account, as its page lists it.
type Passkey struct {
	ID       []byte
	Name     string
	Created  time.Time
	LastUsed *time.Time
	Synced   bool // backed up, e.g. in a password manager or a phone's account
}

type user struct {
	id          uuid.UUID
	email, name string
	creds       []webauthn.Credential
}

func (u user) WebAuthnID() []byte                         { return u.id[:] }
func (u user) WebAuthnName() string                       { return u.email }
func (u user) WebAuthnDisplayName() string                { return cmp(u.name, u.email) }
func (u user) WebAuthnCredentials() []webauthn.Credential { return u.creds }

func cmp(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func loadUser(ctx context.Context, tx pgx.Tx, accountID string) (user, error) {
	var u user
	var id string
	if err := tx.QueryRow(ctx, `SELECT id, email, name FROM accounts WHERE id = $1`, accountID).
		Scan(&id, &u.email, &u.name); err != nil {
		return u, err
	}
	var err error
	if u.id, err = uuid.Parse(id); err != nil {
		return u, err
	}
	rows, err := tx.Query(ctx, `SELECT credential FROM passkeys WHERE account_id = $1 ORDER BY created_at`, accountID)
	if err != nil {
		return u, err
	}
	defer rows.Close()
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return u, err
		}
		var c webauthn.Credential
		if err := jsonv1.Unmarshal(raw, &c); err != nil {
			return u, fmt.Errorf("auth: a stored passkey: %w", err)
		}
		u.creds = append(u.creds, c)
	}
	return u, rows.Err()
}

func saveCeremony(ctx context.Context, tx pgx.Tx, token string, sd *webauthn.SessionData) error {
	raw, err := jsonv1.Marshal(sd)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE sessions SET webauthn = $2 WHERE token_hash = $1`, tokenHash(token), raw)
	return err
}

// takeCeremony reads the ceremony of a session (locked by loadSession) and clears it, so a challenge is answered at
// most once.
func takeCeremony(ctx context.Context, tx pgx.Tx, token string) (webauthn.SessionData, error) {
	var raw []byte
	if err := tx.QueryRow(ctx, `SELECT webauthn FROM sessions WHERE token_hash = $1`, tokenHash(token)).Scan(&raw); err != nil {
		return webauthn.SessionData{}, err
	}
	if raw == nil {
		return webauthn.SessionData{}, ErrNoCeremony
	}
	if _, err := tx.Exec(ctx, `UPDATE sessions SET webauthn = NULL WHERE token_hash = $1`, tokenHash(token)); err != nil {
		return webauthn.SessionData{}, err
	}
	var sd webauthn.SessionData
	if err := jsonv1.Unmarshal(raw, &sd); err != nil {
		return webauthn.SessionData{}, err
	}
	return sd, nil
}

func checkPasskeyName(n string) error {
	n = strings.TrimSpace(n)
	if n == "" || len([]rune(n)) > 60 || strings.ContainsFunc(n, unicode.IsControl) {
		return ErrBadName
	}
	return nil
}

func (s *Service) fullSession(ctx context.Context, tx pgx.Tx, token string) (*sessionRow, error) {
	r, err := s.loadSession(ctx, tx, token)
	if err != nil {
		return nil, err
	}
	if r.stage != "full" {
		return nil, ErrWrongStage
	}
	return r, nil
}

// BeginPasskeyRegistration starts adding a passkey to the signed-in account. It returns the options for
// navigator.credentials.create, as JSON.
func (s *Service) BeginPasskeyRegistration(ctx context.Context, rp RP, token string) ([]byte, error) {
	wa, err := rp.webauthn()
	if err != nil {
		return nil, err
	}
	var out []byte
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, token)
		if err != nil {
			return err
		}
		u, err := loadUser(ctx, tx, r.accountID)
		if err != nil {
			return err
		}
		creation, sd, err := wa.BeginRegistration(u,
			webauthn.WithExclusions(webauthn.Credentials(u.creds).CredentialDescriptors()),
			webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementPreferred),
			webauthn.WithAuthenticatorSelection(protocol.AuthenticatorSelection{
				ResidentKey:      protocol.ResidentKeyRequirementPreferred,
				UserVerification: protocol.VerificationPreferred,
			}))
		if err != nil {
			return err
		}
		sd.Expires = s.Now().Add(ceremonyLength)
		if err := saveCeremony(ctx, tx, token, sd); err != nil {
			return err
		}
		out, err = jsonv1.Marshal(creation)
		return err
	})
	return out, err
}

// FinishPasskeyRegistration checks the browser's answer and keeps the passkey under the given name.
func (s *Service) FinishPasskeyRegistration(ctx context.Context, rp RP, token, name string, response []byte) error {
	if err := checkPasskeyName(name); err != nil {
		return err
	}
	wa, err := rp.webauthn()
	if err != nil {
		return err
	}
	parsed, err := protocol.ParseCredentialCreationResponseBody(bytes.NewReader(response))
	if err != nil {
		return fmt.Errorf("%w: %v", ErrPasskey, err)
	}
	return s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, token)
		if err != nil {
			return err
		}
		sd, err := takeCeremony(ctx, tx, token)
		if err != nil {
			return err
		}
		u, err := loadUser(ctx, tx, r.accountID)
		if err != nil {
			return err
		}
		cred, err := wa.CreateCredential(u, sd, parsed)
		if err != nil {
			return fmt.Errorf("%w: %v", ErrPasskey, err)
		}
		raw, err := jsonv1.Marshal(cred)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO passkeys (id, account_id, name, credential) VALUES ($1, $2, $3, $4)`,
			cred.ID, r.accountID, strings.TrimSpace(name), raw); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+r.accountID, "passkey.add",
			map[string]any{"email": u.email, "name": strings.TrimSpace(name), "synced": cred.Flags.BackupEligible})
		return err
	})
}

// BeginPasskeySignIn starts the second factor with a passkey, at the password step. It returns the options for
// navigator.credentials.get, as JSON.
func (s *Service) BeginPasskeySignIn(ctx context.Context, rp RP, token string) ([]byte, error) {
	wa, err := rp.webauthn()
	if err != nil {
		return nil, err
	}
	var out []byte
	var answer error
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, _, ans, err := s.atPasswordStep(ctx, tx, token, false)
		if err != nil || ans != nil {
			answer = ans
			return err
		}
		u, err := loadUser(ctx, tx, r.accountID)
		if err != nil {
			return err
		}
		if len(u.creds) == 0 {
			answer = ErrNoPasskeys
			return nil
		}
		assertion, sd, err := wa.BeginLogin(u, webauthn.WithUserVerification(protocol.VerificationPreferred))
		if err != nil {
			return err
		}
		sd.Expires = s.Now().Add(ceremonyLength)
		if err := saveCeremony(ctx, tx, token, sd); err != nil {
			return err
		}
		out, err = jsonv1.Marshal(assertion)
		return err
	})
	if err != nil {
		return nil, err
	}
	if answer != nil {
		return nil, answer
	}
	return out, nil
}

// FinishPasskeySignIn checks the browser's answer at the password step. A passkey that isn't accepted counts like
// a wrong code. It returns the token of the full session.
func (s *Service) FinishPasskeySignIn(ctx context.Context, rp RP, addr, token string, response []byte) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	ctx = context.WithoutCancel(ctx)
	wa, err := rp.webauthn()
	if err != nil {
		return "", err
	}
	parsed, perr := protocol.ParseCredentialRequestResponseBody(bytes.NewReader(response))
	var full string
	var answer error
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, a, ans, err := s.atPasswordStep(ctx, tx, token, false)
		if err != nil || ans != nil {
			answer = ans
			return err
		}
		sd, err := takeCeremony(ctx, tx, token)
		if errors.Is(err, ErrNoCeremony) {
			answer = err
			return nil
		}
		if err != nil {
			return err
		}
		u, err := loadUser(ctx, tx, r.accountID)
		if err != nil {
			return err
		}
		var cred *webauthn.Credential
		if perr == nil {
			cred, err = wa.ValidateLogin(u, sd, parsed)
		}
		if perr != nil || err != nil || cred.Authenticator.CloneWarning {
			answer, err = s.codeFailure(ctx, tx, a, "passkey")
			if answer == ErrCode {
				answer = ErrPasskey
			}
			return err
		}
		raw, err := jsonv1.Marshal(cred)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE passkeys SET credential = $2, last_used_at = $3 WHERE id = $1 AND account_id = $4`,
			cred.ID, raw, s.Now(), r.accountID); err != nil {
			return err
		}
		full, err = s.makeFull(ctx, tx, token, a, "passkey")
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

// HasPasskeys tells whether the account of a session has a passkey, for the page of the second factor.
func (s *Service) HasPasskeys(ctx context.Context, token string) (bool, error) {
	var has bool
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.loadSession(ctx, tx, token)
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM passkeys WHERE account_id = $1)`, r.accountID).Scan(&has)
	})
	return has, err
}

// Passkeys lists the passkeys of the signed-in account.
func (s *Service) Passkeys(ctx context.Context, token string) ([]Passkey, error) {
	var out []Passkey
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, token)
		if err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id, name, created_at, last_used_at, credential FROM passkeys
		                            WHERE account_id = $1 ORDER BY created_at`, r.accountID)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var p Passkey
			var raw []byte
			if err := rows.Scan(&p.ID, &p.Name, &p.Created, &p.LastUsed, &raw); err != nil {
				return err
			}
			var c webauthn.Credential
			if jsonv1.Unmarshal(raw, &c) == nil {
				p.Synced = c.Flags.BackupEligible
			}
			out = append(out, p)
		}
		return rows.Err()
	})
	return out, err
}

// RemovePasskey removes one of the signed-in account's passkeys. TOTP and the recovery codes stay.
func (s *Service) RemovePasskey(ctx context.Context, token string, id []byte) error {
	return s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, token)
		if err != nil {
			return err
		}
		var name, email string
		err = tx.QueryRow(ctx, `DELETE FROM passkeys p USING accounts a WHERE p.id = $1 AND p.account_id = $2
		                        AND a.id = p.account_id RETURNING p.name, a.email`, id, r.accountID).Scan(&name, &email)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoSuchKey
		}
		if err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+r.accountID, "passkey.remove",
			map[string]any{"email": email, "name": name})
		return err
	})
}
