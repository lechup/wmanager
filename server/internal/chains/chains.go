// Package chains keeps each company's chain of admin lists and the signing keys people register. It checks every
// list it takes, the way a computer will (verify.Chain), so a broken list never reaches one; but what makes a list
// count is the computers' own check of the whole chain, not the server.
package chains

import (
	"context"
	"encoding/json/v2"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Errors.
var (
	ErrNotAdmin = errors.New("chains: only an administrator of the company may do that")
	ErrBroken   = errors.New("chains: the stored chain doesn't check")
	ErrKeyTaken = errors.New("chains: the key is registered by another account")
	ErrBadKey   = errors.New("chains: not a signing key a security key makes")
)

// role is the account's role in the company, or "".
func role(ctx context.Context, tx pgx.Tx, accountID, companyID string) (string, error) {
	var r string
	err := tx.QueryRow(ctx, `SELECT role FROM memberships WHERE account_id = $1 AND company_id = $2`, accountID, companyID).Scan(&r)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return r, err
}

func load(ctx context.Context, tx pgx.Tx, companyID string) ([]verify.Signed, error) {
	rows, err := tx.Query(ctx, `SELECT signed FROM admin_lists WHERE company_id = $1 ORDER BY sequence`, companyID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []verify.Signed
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		var s verify.Signed
		if err := json.Unmarshal(raw, &s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// Load returns a company's chain, for one of its members.
func Load(ctx context.Context, s *store.Store, accountID, companyID string) ([]verify.Signed, error) {
	var out []verify.Signed
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		r, err := role(ctx, tx, accountID, companyID)
		if err != nil {
			return err
		}
		if r == "" {
			return ErrNotAdmin
		}
		out, err = load(ctx, tx, companyID)
		return err
	})
	return out, err
}

// held checks a stored chain again (it was checked when stored; a database changed by hand is caught here).
func held(stored []verify.Signed) (*verify.Chain, error) {
	return verify.VerifyChain(verify.Fingerprint(stored[0].Hash()), stored)
}

// Append takes the company's next admin list from one of its administrators: the first one (signed by a key of its
// own), or one that extends the stored chain.
func Append(ctx context.Context, s *store.Store, accountID, companyID string, next verify.Signed) (*verify.Chain, error) {
	var chain *verify.Chain
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		// One list at a time per company.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM companies WHERE id = $1 FOR UPDATE`, companyID); err != nil {
			return err
		}
		r, err := role(ctx, tx, accountID, companyID)
		if err != nil {
			return err
		}
		if r != "admin" {
			return ErrNotAdmin
		}
		stored, err := load(ctx, tx, companyID)
		if err != nil {
			return err
		}
		if len(stored) == 0 {
			chain, err = verify.VerifyChain(verify.Fingerprint(next.Hash()), []verify.Signed{next})
		} else if chain, err = held(stored); err != nil {
			return fmt.Errorf("%w: %w", ErrBroken, err)
		} else {
			err = chain.Update(append(stored, next))
		}
		if err != nil {
			return err
		}
		raw, err := json.Marshal(next)
		if err != nil {
			return err
		}
		cur := chain.Current()
		if _, err := tx.Exec(ctx, `INSERT INTO admin_lists (company_id, sequence, signed) VALUES ($1, $2, $3)`,
			companyID, cur.Sequence, raw); err != nil {
			return err
		}
		var names []string
		for _, a := range cur.Administrators {
			names = append(names, a.Name)
		}
		_, err = audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, "admins.signed",
			map[string]any{"sequence": cur.Sequence, "fingerprint": verify.Fingerprint(chain.Company),
				"administrators": names, "signed_by": next.Key})
		return err
	})
	return chain, err
}

// Summary is what the panel shows of a company's chain.
type Summary struct {
	Fingerprint    string
	Sequence       int64
	Administrators []verify.Administrator
}

// Summarize checks a company's stored chain and sums it up, for one of its members; nil when there is none yet.
func Summarize(ctx context.Context, s *store.Store, accountID, companyID string) (*Summary, error) {
	stored, err := Load(ctx, s, accountID, companyID)
	if err != nil || len(stored) == 0 {
		return nil, err
	}
	c, err := held(stored)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrBroken, err)
	}
	return &Summary{Fingerprint: verify.Fingerprint(c.Company), Sequence: c.Current().Sequence,
		Administrators: c.Current().Administrators}, nil
}

// Key is a registered signing key.
type Key struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	COSE  []byte `json:"cose"`
}

// RegisterKey keeps a signing key a person made in wmanager-sign, so an administrator can add it to a list. It
// changes nothing by itself: a key counts only once a signed list names it, after its fingerprint was typed.
func RegisterKey(ctx context.Context, s *store.Store, accountID string, cose []byte) (string, error) {
	pk, err := verify.ParseCOSEKey(cose)
	if err != nil {
		return "", ErrBadKey
	}
	if err := verify.CheckKey(pk); err != nil {
		return "", ErrBadKey
	}
	id := verify.KeyID(cose)
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO signing_keys (id, account_id, cose) VALUES ($1, $2, $3)
		                           ON CONFLICT (id) DO NOTHING`, id, accountID, cose); err != nil {
			return err
		}
		var owner string
		if err := tx.QueryRow(ctx, `SELECT account_id FROM signing_keys WHERE id = $1`, id).Scan(&owner); err != nil {
			return err
		}
		if owner != accountID {
			return ErrKeyTaken
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", "account:"+accountID, "signing-key.registered",
			map[string]any{"key": id})
		return err
	})
	return id, err
}

// CompanyKeys lists the keys registered by the company's members, for one of its administrators.
func CompanyKeys(ctx context.Context, s *store.Store, accountID, companyID string) ([]Key, error) {
	var out []Key
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		r, err := role(ctx, tx, accountID, companyID)
		if err != nil {
			return err
		}
		if r != "admin" {
			return ErrNotAdmin
		}
		rows, err := tx.Query(ctx, `SELECT k.id, a.email, k.cose FROM signing_keys k
		                            JOIN memberships m ON m.account_id = k.account_id AND m.company_id = $1
		                            JOIN accounts a ON a.id = k.account_id ORDER BY a.email, k.created_at`, companyID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Key, error) {
			var k Key
			return k, r.Scan(&k.ID, &k.Email, &k.COSE)
		})
		return err
	})
	return out, err
}
