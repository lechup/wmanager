package auth

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// SetupLinkValid is how long a one-time link to set up a new account works.
const SetupLinkValid = 7 * 24 * time.Hour

// ErrNoSetup means the setup link is unknown, used or expired.
var ErrNoSetup = errors.New("auth: the setup link is not valid (used, expired or unknown)")

// CreateSetupLink makes a one-time link for an account, in the transaction that makes or resets the account. It
// replaces the account's earlier links. Only the hash of the token is kept.
func CreateSetupLink(ctx context.Context, tx pgx.Tx, accountID string, now time.Time) (string, error) {
	if _, err := tx.Exec(ctx, `DELETE FROM setup_links WHERE account_id = $1`, accountID); err != nil {
		return "", err
	}
	token, hash := newToken()
	if _, err := tx.Exec(ctx, `INSERT INTO setup_links (token_hash, account_id, expires_at) VALUES ($1, $2, $3)`,
		hash, accountID, now.Add(SetupLinkValid)); err != nil {
		return "", err
	}
	return token, nil
}

func (s *Service) setupAccount(ctx context.Context, tx pgx.Tx, token string, lock bool) (id, email string, err error) {
	q := `SELECT a.id, a.email FROM setup_links l JOIN accounts a ON a.id = l.account_id
	      WHERE l.token_hash = $1 AND l.expires_at > $2 AND NOT a.disabled AND a.password_hash IS NULL`
	if lock {
		q += ` FOR UPDATE OF a` // the account row serializes two uses of one link
	}
	err = tx.QueryRow(ctx, q, tokenHash(token), s.Now()).Scan(&id, &email)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", ErrNoSetup
	}
	return id, email, err
}

// SetupEmail returns the e-mail address of a setup link's account, to show on its page.
func (s *Service) SetupEmail(ctx context.Context, token string) (string, error) {
	var email string
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		var err error
		_, email, err = s.setupAccount(ctx, tx, token, false)
		return err
	})
	return email, err
}

// CompleteSetup sets a new account's password from its setup link and uses the link up. It returns a session at
// the password step: setting up the second factor (BeginTOTP, ConfirmTOTP) comes next.
func (s *Service) CompleteSetup(ctx context.Context, addr, token, password string) (string, error) {
	if err := s.allow(addr); err != nil {
		return "", err
	}
	ctx = context.WithoutCancel(ctx)
	if err := CheckNewPassword(password); err != nil {
		return "", err
	}
	if _, err := s.SetupEmail(ctx, token); err != nil {
		return "", err
	}
	hash, err := HashPassword(ctx, password) // outside any transaction
	if err != nil {
		return "", err
	}
	session, sessionHash := newToken()
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		id, email, err := s.setupAccount(ctx, tx, token, true)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE accounts SET password_hash = $2 WHERE id = $1`, id, hash); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM setup_links WHERE account_id = $1`, id); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO sessions (token_hash, account_id, stage, expires_at)
		                           VALUES ($1, $2, 'password', $3)`, sessionHash, id, s.Now().Add(PasswordStage)); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+id, "account.setup",
			map[string]any{"email": email, "address": addressKey(addr)})
		return err
	})
	if err != nil {
		return "", err
	}
	return session, nil
}
