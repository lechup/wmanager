package auth

import (
	"context"
	"crypto/rand"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// wmanager-sign signs in with a short code made in the panel (the user's choice of the plan's options): the panel
// shows it to a signed-in person, who types it into wmanager-sign, which gets a token of the sign API for
// SignTokenLife. The token reaches only the sign API, never the panel; signing itself always needs the key.
const (
	SignCodeLife  = 5 * time.Minute
	SignTokenLife = 12 * time.Hour
)

// ErrSignCode means the code is unknown, used or expired; ErrSignToken that the token is.
var (
	ErrSignCode  = errors.New("auth: the code is not valid (used, expired or wrong)")
	ErrSignToken = errors.New("auth: the token of wmanager-sign is not valid")
)

// signCodeAlphabet has no letters that look alike (no 0, O, 1, I, L).
const signCodeAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// CreateSignCode makes a code for wmanager-sign, for a full session, replacing the account's earlier code. It has
// 8 characters of 31 (about 40 bits): enough for 5 minutes behind the limit per address.
func (s *Service) CreateSignCode(ctx context.Context, sessionToken string) (string, time.Time, error) {
	b := make([]byte, 8)
	for i := range b {
		var r [1]byte
		for {
			rand.Read(r[:])
			if int(r[0]) < 256-256%len(signCodeAlphabet) {
				break
			}
		}
		b[i] = signCodeAlphabet[int(r[0])%len(signCodeAlphabet)]
	}
	code := string(b[:4]) + "-" + string(b[4:])
	expires := s.Now().Add(SignCodeLife)
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, sessionToken)
		if err != nil {
			return err
		}
		// The account's earlier code, and everyone's expired codes and tokens.
		if _, err := tx.Exec(ctx, `DELETE FROM sign_codes WHERE account_id = $1 OR expires_at <= $2`, r.accountID, s.Now()); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM sign_tokens WHERE expires_at <= $1`, s.Now()); err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO sign_codes (code_hash, account_id, expires_at) VALUES ($1, $2, $3)`,
			signCodeHash(code), r.accountID, expires)
		return err
	})
	return code, expires, err
}

func signCodeHash(code string) []byte {
	norm := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
	return tokenHash("wmanager-sign code\x00" + norm)
}

// ExchangeSignCode turns a code into a token of the sign API. The code works once.
func (s *Service) ExchangeSignCode(ctx context.Context, addr, code string) (token, accountID string, expires time.Time, err error) {
	if err := s.allow(addr); err != nil {
		return "", "", time.Time{}, err
	}
	ctx = context.WithoutCancel(ctx)
	var answer error
	err = s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		var email string
		var disabled bool
		err := tx.QueryRow(ctx, `DELETE FROM sign_codes c USING accounts a
		                         WHERE c.code_hash = $1 AND c.expires_at > $2 AND a.id = c.account_id
		                         RETURNING a.id, a.email, a.disabled`, signCodeHash(code), s.Now()).Scan(&accountID, &email, &disabled)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && disabled) {
			answer = ErrSignCode
			return nil
		}
		if err != nil {
			return err
		}
		var hash []byte
		token, hash = newToken()
		expires = s.Now().Add(SignTokenLife)
		if _, err := tx.Exec(ctx, `INSERT INTO sign_tokens (token_hash, account_id, created_at, expires_at)
		                           VALUES ($1, $2, $3, $4)`, hash, accountID, s.Now(), expires); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+accountID, "sign.connected",
			map[string]any{"email": email, "address": addressKey(addr)})
		return err
	})
	if err != nil {
		return "", "", time.Time{}, err
	}
	if answer != nil {
		return "", "", time.Time{}, answer
	}
	return token, accountID, expires, nil
}

// LookupSignToken returns the account of a token of the sign API.
func (s *Service) LookupSignToken(ctx context.Context, token string) (string, error) {
	var accountID string
	err := s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT t.account_id FROM sign_tokens t JOIN accounts a ON a.id = t.account_id
		                         WHERE t.token_hash = $1 AND t.expires_at > $2 AND NOT a.disabled`,
			tokenHash(token), s.Now()).Scan(&accountID)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrSignToken
		}
		return err
	})
	return accountID, err
}

// RevokeSignTokens ends every token of wmanager-sign of the signed-in account.
func (s *Service) RevokeSignTokens(ctx context.Context, sessionToken string) error {
	return s.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := s.fullSession(ctx, tx, sessionToken)
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM sign_tokens WHERE account_id = $1`, r.accountID)
		if err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+r.accountID, "sign.revoked", nil)
		return err
	})
}
