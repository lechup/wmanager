// Package accounts keeps the accounts, the companies and who belongs to which, with every change in the audit log.
package accounts

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/store"
)

// Roles in a company.
const (
	RoleAdmin  = "admin"
	RolePerson = "person"
)

// Errors.
var (
	ErrNotOwner  = errors.New("accounts: only the owner of the server can do that")
	ErrExists    = errors.New("accounts: it exists already")
	ErrBadEmail  = errors.New("accounts: not an e-mail address")
	ErrBadName   = errors.New("accounts: a name of 1 to 100 printable characters")
	ErrBadRole   = errors.New("accounts: the role is admin or person")
	ErrNoAccount = errors.New("accounts: no such account")
	ErrNoCompany = errors.New("accounts: no such company")
)

// Actor is who makes a change: "system" for the server's own commands, or an account.
type Actor struct {
	AccountID string // "" for the system
}

// SystemActor is the server's command line (e.g. making the first owner).
var SystemActor = Actor{}

func (a Actor) String() string {
	if a.AccountID == "" {
		return "system"
	}
	return "account:" + a.AccountID
}

func checkEmail(e string) error {
	at := strings.IndexByte(e, '@')
	if at < 1 || at != strings.LastIndexByte(e, '@') || at == len(e)-1 || len(e) > 254 ||
		strings.ContainsFunc(e, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) {
		return ErrBadEmail
	}
	return nil
}

func checkName(n string, allowEmpty bool) error {
	if (n == "" && allowEmpty) ||
		(n != "" && len([]rune(n)) <= 100 && !strings.ContainsFunc(n, unicode.IsControl) && strings.TrimSpace(n) == n) {
		return nil
	}
	return ErrBadName
}

func uniqueViolation(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "23505"
}

// isOwner checks, inside the transaction, that the actor is the owner of the server.
func isOwner(ctx context.Context, tx pgx.Tx, a Actor) error {
	if a.AccountID == "" {
		return nil
	}
	var owner bool
	err := tx.QueryRow(ctx, `SELECT is_owner FROM accounts WHERE id = $1 AND NOT disabled`, a.AccountID).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && !owner) {
		return ErrNotOwner
	}
	return err
}

// CreateAccount makes an account. Only the owner of the server, or the server's own command line, makes
// accounts. The second factor is set up at the first sign-in.
func CreateAccount(ctx context.Context, s *store.Store, by Actor, email, name, password string, owner bool) (string, error) {
	email = auth.NormalizeEmail(email)
	if err := checkEmail(email); err != nil {
		return "", err
	}
	if err := checkName(name, true); err != nil {
		return "", err
	}
	hash, err := auth.HashPassword(ctx, password)
	if err != nil {
		return "", err
	}
	var id string
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `INSERT INTO accounts (email, name, password_hash, is_owner) VALUES ($1, $2, $3, $4)
		                         RETURNING id`, email, name, hash, owner).Scan(&id)
		if uniqueViolation(err) {
			return ErrExists
		}
		if err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", by.String(), "account.create",
			map[string]any{"account": id, "email": email, "owner": owner})
		return err
	})
	return id, err
}

// CreateCompany makes a company. Only the owner of the server makes companies.
func CreateCompany(ctx context.Context, s *store.Store, by Actor, name string) (string, error) {
	if err := checkName(name, false); err != nil {
		return "", err
	}
	var id string
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `INSERT INTO companies (name) VALUES ($1) RETURNING id`, name).Scan(&id)
		if uniqueViolation(err) {
			return ErrExists
		}
		if err != nil {
			return err
		}
		if _, err := audit.Append(ctx, tx, audit.ServerChain, "", by.String(), "company.create",
			map[string]any{"company": id, "name": name}); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.CompanyChain(id), id, by.String(), "company.create",
			map[string]any{"name": name})
		return err
	})
	return id, err
}

// AddMember gives an account a role in a company, or changes it. Only the owner of the server does it in stage
// 1; a company's administrators come with the panel.
func AddMember(ctx context.Context, s *store.Store, by Actor, companyID, accountID, role string) error {
	if role != RoleAdmin && role != RolePerson {
		return ErrBadRole
	}
	if !isUUID(accountID) {
		return ErrNoAccount
	}
	if !isUUID(companyID) {
		return ErrNoCompany
	}
	return s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		var email string
		if err := tx.QueryRow(ctx, `SELECT email FROM accounts WHERE id = $1`, accountID).Scan(&email); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return ErrNoAccount
			}
			return err
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM companies WHERE id = $1)`, companyID).Scan(&exists); err != nil {
			return err
		}
		if !exists {
			return ErrNoCompany
		}
		if _, err := tx.Exec(ctx, `INSERT INTO memberships (account_id, company_id, role) VALUES ($1, $2, $3)
		                           ON CONFLICT (account_id, company_id) DO UPDATE SET role = excluded.role`,
			accountID, companyID, role); err != nil {
			return err
		}
		_, err := audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, by.String(), "member.set",
			map[string]any{"account": accountID, "email": email, "role": role})
		return err
	})
}

// Company is a company an account belongs to.
type Company struct {
	ID, Name, Role string
}

// CompaniesOf lists the companies of an account. (The tables of companies and memberships have no row-level
// security: they hold no company's data.)
func CompaniesOf(ctx context.Context, s *store.Store, accountID string) ([]Company, error) {
	var out []Company
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT c.id, c.name, m.role FROM memberships m JOIN companies c ON c.id = m.company_id
		                            WHERE m.account_id = $1 ORDER BY c.name`, accountID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Company, error) {
			var c Company
			return c, r.Scan(&c.ID, &c.Name, &c.Role)
		})
		return err
	})
	if err != nil {
		return nil, fmt.Errorf("accounts: %w", err)
	}
	return out, nil
}

// Unlock ends an account's lockout after wrong second-factor codes, and its doubling. Only the owner of the
// server, or the server's own command line, does it; a recovery code does it too.
func Unlock(ctx context.Context, s *store.Store, by Actor, email string) error {
	email = auth.NormalizeEmail(email)
	return s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		var id string
		err := tx.QueryRow(ctx, `UPDATE accounts SET failed_codes = 0, lockouts = 0, locked_until = NULL
		                         WHERE email = $1 RETURNING id`, email).Scan(&id)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoAccount
		}
		if err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", by.String(), "account.unlock",
			map[string]any{"account": id, "email": email})
		return err
	})
}

// Invite makes an account without a password and returns a one-time link token for it, valid for
// auth.SetupLinkValid: its person sets the password and second factor, and the owner never knows them. Only the
// owner of the server invites. now is the clock that the sign-in checks the link with.
func Invite(ctx context.Context, s *store.Store, by Actor, email, name string, now time.Time) (id, token string, err error) {
	email = auth.NormalizeEmail(email)
	if err := checkEmail(email); err != nil {
		return "", "", err
	}
	if err := checkName(name, true); err != nil {
		return "", "", err
	}
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `INSERT INTO accounts (email, name) VALUES ($1, $2) RETURNING id`, email, name).Scan(&id)
		if uniqueViolation(err) {
			return ErrExists
		}
		if err != nil {
			return err
		}
		if token, err = auth.CreateSetupLink(ctx, tx, id, now); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", by.String(), "account.invite",
			map[string]any{"account": id, "email": email})
		return err
	})
	return id, token, err
}

// AccountInfo is an account as the owner's page lists it.
type AccountInfo struct {
	ID, Email, Name          string
	Owner, Disabled, HasTOTP bool
	Pending                  bool       // no password yet: the setup link hasn't been used
	LinkExpires              *time.Time // when its setup link stops working, if it has one
	Locked                   bool       // locked now after wrong codes
}

// List returns every account, for the owner of the server.
func List(ctx context.Context, s *store.Store, by Actor) ([]AccountInfo, error) {
	var out []AccountInfo
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id, email, name, is_owner, disabled, totp_secret IS NOT NULL,
		                                   password_hash IS NULL,
		                                   (SELECT max(expires_at) FROM setup_links l WHERE l.account_id = a.id),
		                                   coalesce(locked_until > now(), false)
		                            FROM accounts a ORDER BY email`)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (AccountInfo, error) {
			var a AccountInfo
			return a, r.Scan(&a.ID, &a.Email, &a.Name, &a.Owner, &a.Disabled, &a.HasTOTP, &a.Pending, &a.LinkExpires,
				&a.Locked)
		})
		return err
	})
	return out, err
}

// AllCompanies returns every company, for the owner of the server (names only, not their data).
func AllCompanies(ctx context.Context, s *store.Store, by Actor) ([]Company, error) {
	var out []Company
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id, name, '' FROM companies ORDER BY name`)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Company, error) {
			var c Company
			return c, r.Scan(&c.ID, &c.Name, &c.Role)
		})
		return err
	})
	return out, err
}

// Member is an account in a company.
type Member struct {
	AccountID, Email, Name, Role string
}

// Members lists a company's members, for one of its members.
func Members(ctx context.Context, s *store.Store, accountID, companyID string) ([]Member, error) {
	var out []Member
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM memberships WHERE account_id = $1 AND company_id = $2)`,
			accountID, companyID).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNoCompany
		}
		rows, err := tx.Query(ctx, `SELECT a.id, a.email, a.name, m.role FROM memberships m JOIN accounts a ON a.id = m.account_id
		                            WHERE m.company_id = $1 ORDER BY a.email`, companyID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Member, error) {
			var m Member
			return m, r.Scan(&m.AccountID, &m.Email, &m.Name, &m.Role)
		})
		return err
	})
	return out, err
}

// isUUID checks the form of an id from a form, so a wrong one is "not found" rather than a database error.
func isUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range s {
		switch {
		case i == 8 || i == 13 || i == 18 || i == 23:
			if c != '-' {
				return false
			}
		case !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f'):
			return false
		}
	}
	return true
}

// ErrNotPending means the account has set its password already, so a setup link would do nothing.
var ErrNotPending = errors.New("accounts: the account is set up already")

// NewLink makes a new one-time setup link for an account that hasn't used its link yet (lost or expired),
// replacing the old one. Only the owner of the server does it.
func NewLink(ctx context.Context, s *store.Store, by Actor, accountID string, now time.Time) (email, token string, err error) {
	if !isUUID(accountID) {
		return "", "", ErrNoAccount
	}
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := isOwner(ctx, tx, by); err != nil {
			return err
		}
		var pending bool
		err := tx.QueryRow(ctx, `SELECT email, password_hash IS NULL FROM accounts WHERE id = $1 FOR UPDATE`, accountID).
			Scan(&email, &pending)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoAccount
		}
		if err != nil {
			return err
		}
		if !pending {
			return ErrNotPending
		}
		if token, err = auth.CreateSetupLink(ctx, tx, accountID, now); err != nil {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.ServerChain, "", by.String(), "account.newlink",
			map[string]any{"account": accountID, "email": email})
		return err
	})
	return email, token, err
}
