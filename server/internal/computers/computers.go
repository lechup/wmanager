// Package computers keeps the company's computers: the enrollment tokens administrators make for installers, and
// each computer's public key, which checks every request it makes (docs/agent.md). Being enrolled lets a computer
// ask for its company's statements; what it acts on is only what they say, checked by the computer itself.
package computers

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Limits of enrollment tokens, and of a proof's time.
const (
	DefaultTokenLife = 7 * 24 * time.Hour
	MinTokenLife     = time.Hour
	MaxTokenLife     = 30 * 24 * time.Hour
	MaxUses          = 1000
	ProofAge         = 10 * time.Minute
)

// The prefixes of what a computer's key signs: each use its own, so a signature made for one can't pass for another.
const (
	EnrollPrefix  = "wmanager-agent enroll v1\x00"
	RequestPrefix = "wmanager-agent request v1\x00"
)

// Errors.
var (
	ErrNotAdmin     = chains.ErrNotAdmin
	ErrNotMember    = chains.ErrNotMember
	ErrToken        = errors.New("computers: the enrollment token is not valid (wrong, used up, ended or expired)")
	ErrTokenLimits  = errors.New("computers: a token is valid for 1 hour to 30 days, for 1 to 1000 computers")
	ErrKey          = errors.New("computers: not an ECDSA P-256 public key")
	ErrProof        = errors.New("computers: the proof is not the key's signature of this enrollment")
	ErrName         = errors.New("computers: a computer's name has 1 to 100 characters, with no control character")
	ErrOtherCompany = errors.New("computers: the computer is enrolled in another company")
	ErrNoComputer   = errors.New("computers: no such computer")
)

// tokenAlphabet has no letters that look alike, as sign codes.
const tokenAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// newToken is 25 characters of 31 (about 124 bits), in groups of 5.
func newToken() string {
	var b strings.Builder
	for i := 0; i < 25; i++ {
		if i > 0 && i%5 == 0 {
			b.WriteByte('-')
		}
		for {
			var r [1]byte
			rand.Read(r[:])
			if int(r[0]) < 256-256%len(tokenAlphabet) {
				b.WriteByte(tokenAlphabet[int(r[0])%len(tokenAlphabet)])
				break
			}
		}
	}
	return b.String()
}

// normal is a token as typed: case, dashes and spaces don't matter.
func normal(token string) string {
	return strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(token)))
}

// TokenHash is the hash a token is kept as, and the one an enrollment's proof names (hex).
func TokenHash(token string) [32]byte {
	return sha256.Sum256([]byte("wmanager enrollment token\x00" + normal(token)))
}

func member(ctx context.Context, tx pgx.Tx, accountID, companyID string, admin bool) error {
	r, err := chains.Role(ctx, tx, accountID, companyID)
	switch {
	case err != nil:
		return err
	case r == "":
		return ErrNotMember
	case admin && r != "admin":
		return ErrNotAdmin
	}
	return nil
}

// Token is an enrollment token as the panel lists it.
type Token struct {
	ID        string
	UsesLeft  int
	Expires   time.Time
	CreatedBy string
	CreatedAt time.Time
}

// CreateToken makes an enrollment token for the company, by one of its administrators. The token is returned once
// and kept as a hash.
func CreateToken(ctx context.Context, s *store.Store, accountID, companyID string, life time.Duration, uses int, now time.Time) (string, error) {
	if life < MinTokenLife || life > MaxTokenLife || uses < 1 || uses > MaxUses {
		return "", ErrTokenLimits
	}
	token := newToken()
	h := TokenHash(token)
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		var id string
		if err := tx.QueryRow(ctx, `INSERT INTO enrollment_tokens (company_id, token_hash, uses_left, expires_at, created_by)
		                            VALUES ($1, $2, $3, $4, $5) RETURNING id`, companyID, h[:], uses, now.Add(life), accountID).Scan(&id); err != nil {
			return err
		}
		_, err := audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, "enrollment-token.made",
			map[string]any{"token": id, "uses": uses, "expires": now.Add(life).UTC()})
		return err
	})
	if err != nil {
		return "", err
	}
	return token, nil
}

// Tokens is the company's enrollment tokens still valid, for one of its administrators.
func Tokens(ctx context.Context, s *store.Store, accountID, companyID string, now time.Time) ([]Token, error) {
	var out []Token
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT t.id, t.uses_left, t.expires_at, coalesce(a.email, ''), t.created_at
		                            FROM enrollment_tokens t LEFT JOIN accounts a ON a.id = t.created_by
		                            WHERE t.company_id = $1 AND t.uses_left > 0 AND t.expires_at > $2
		                            ORDER BY t.created_at`, companyID, now)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Token, error) {
			var t Token
			return t, r.Scan(&t.ID, &t.UsesLeft, &t.Expires, &t.CreatedBy, &t.CreatedAt)
		})
		return err
	})
	return out, err
}

// EndToken ends an enrollment token, for one of the company's administrators.
func EndToken(ctx context.Context, s *store.Store, accountID, companyID, tokenID string) error {
	return s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE enrollment_tokens SET uses_left = 0 WHERE id = $1 AND company_id = $2 AND uses_left > 0`,
			tokenID, companyID)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, "enrollment-token.ended",
			map[string]any{"token": tokenID})
		return err
	})
}

// ID is a computer's id: the SHA-256 of its public key (SPKI), in hex.
func ID(spki []byte) string {
	h := sha256.Sum256(spki)
	return hex.EncodeToString(h[:])
}

// EnrollDigest is what a computer's key signs to enroll: on this server, with this token, as this computer, named so,
// at this time.
func EnrollDigest(server, tokenHashHex, id, name string, at time.Time) [32]byte {
	return sha256.Sum256([]byte(EnrollPrefix + server + "\x00" + tokenHashHex + "\x00" + id + "\x00" + name + "\x00" +
		at.UTC().Format(time.RFC3339)))
}

// RequestDigest is what a computer's key signs for a request.
func RequestDigest(method, pathQuery, at string, body []byte) [32]byte {
	b := sha256.Sum256(body)
	return sha256.Sum256([]byte(RequestPrefix + method + "\x00" + pathQuery + "\x00" + at + "\x00" + hex.EncodeToString(b[:])))
}

// ParseKey reads a computer's public key: ECDSA P-256 in its PKIX form.
func ParseKey(spki []byte) (*ecdsa.PublicKey, error) {
	k, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		return nil, ErrKey
	}
	pub, ok := k.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return nil, ErrKey
	}
	return pub, nil
}

// Computer is an enrolled computer.
type Computer struct {
	ID          string
	Company     string
	Key         *ecdsa.PublicKey
	Name        string
	EnrolledAt  time.Time
	LastContact time.Time
}

// Enroll takes a computer's public key with an enrollment token and the key's proof, and returns the computer. A
// key enrolled already in the token's company gets its computer again, and uses no more of the token.
func Enroll(ctx context.Context, s *store.Store, server, token string, spki []byte, name string, at, now time.Time, proof []byte) (Computer, error) {
	pub, err := ParseKey(spki)
	if err != nil {
		return Computer{}, err
	}
	if verify.CheckName("a computer's name", name) != nil {
		return Computer{}, ErrName
	}
	id := ID(spki)
	th := TokenHash(token)
	d := EnrollDigest(server, hex.EncodeToString(th[:]), id, name, at)
	if server == "" || at.Sub(now).Abs() > ProofAge || !ecdsa.VerifyASN1(pub, d[:], proof) {
		return Computer{}, ErrProof
	}
	var c Computer
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		var tokenID, company string
		var uses int
		var expires time.Time
		err := tx.QueryRow(ctx, `SELECT id, company_id, uses_left, expires_at FROM enrollment_tokens WHERE token_hash = $1 FOR UPDATE`,
			th[:]).Scan(&tokenID, &company, &uses, &expires)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrToken
		}
		if err != nil {
			return err
		}
		if uses < 1 || !now.Before(expires) {
			return ErrToken
		}
		var have string
		err = tx.QueryRow(ctx, `SELECT company_id FROM computers WHERE id = $1`, id).Scan(&have)
		switch {
		case err == nil && have != company:
			return ErrOtherCompany
		case err == nil:
			c = Computer{ID: id, Company: company, Key: pub, Name: name}
			return nil // enrolled already
		case !errors.Is(err, pgx.ErrNoRows):
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO computers (id, company_id, public_key, name, token_id, enrolled_at) VALUES ($1, $2, $3, $4, $5, $6)`,
			id, company, spki, name, tokenID, now); err != nil {
			var pg *pgconn.PgError
			if errors.As(err, &pg) && pg.Code == "23505" {
				return ErrOtherCompany // enrolled meanwhile
			}
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE enrollment_tokens SET uses_left = uses_left - 1 WHERE id = $1`, tokenID); err != nil {
			return err
		}
		c = Computer{ID: id, Company: company, Key: pub, Name: name, EnrolledAt: now}
		_, err = audit.Append(ctx, tx, audit.CompanyChain(company), company, "computer:"+id, "computer.enrolled",
			map[string]any{"computer": id, "name": name, "token": tokenID})
		return err
	})
	return c, err
}

// Lookup is an enrolled computer by its id, for the server's own check of its requests.
func Lookup(ctx context.Context, s *store.Store, id string) (Computer, error) {
	var c Computer
	var spki []byte
	var last *time.Time
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		err := tx.QueryRow(ctx, `SELECT id, company_id, public_key, name, enrolled_at, last_contact FROM computers WHERE id = $1`, id).
			Scan(&c.ID, &c.Company, &spki, &c.Name, &c.EnrolledAt, &last)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoComputer
		}
		return err
	})
	if err != nil {
		return Computer{}, err
	}
	if c.Key, err = ParseKey(spki); err != nil {
		return Computer{}, err
	}
	if last != nil {
		c.LastContact = *last
	}
	return c, nil
}

// ContactEvery is how often a computer's last contact is written down: not at each request.
const ContactEvery = time.Minute

// Contact writes down a computer's last contact and address, when the one kept is older than ContactEvery.
func Contact(ctx context.Context, s *store.Store, id, addr string, now time.Time) error {
	return s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE computers SET last_contact = $2, last_address = $3
		                        WHERE id = $1 AND (last_contact IS NULL OR last_contact < $4)`, id, now, addr, now.Add(-ContactEvery))
		return err
	})
}

// List is the company's computers, for one of its members.
func List(ctx context.Context, s *store.Store, accountID, companyID string) ([]Computer, error) {
	var out []Computer
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, false); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT id, company_id, name, enrolled_at, last_contact FROM computers
		                            WHERE company_id = $1 ORDER BY name, id`, companyID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Computer, error) {
			var c Computer
			var last *time.Time
			err := r.Scan(&c.ID, &c.Company, &c.Name, &c.EnrolledAt, &last)
			if last != nil {
				c.LastContact = *last
			}
			return c, err
		})
		return err
	})
	return out, err
}
