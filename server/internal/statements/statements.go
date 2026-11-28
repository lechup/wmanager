// Package statements keeps what wmanager-sign signs besides admin lists: the drafts made in the panel, the files
// they name by hash, the signed states the server hands out, and the secrets' values. It checks each statement it
// takes the way a computer will (verify), against the company's stored chain, so a broken one never reaches a
// computer; what makes it count is the computers' own check.
package statements

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Limits.
const (
	MaxDraft  = 8 << 20 // a draft's JSON, as large as the largest statement
	MaxFile   = 8 << 20 // a file's content (larger files come with add-file)
	MaxDrafts = 100     // drafts waiting in a company
)

// Errors.
var (
	ErrNotAdmin   = chains.ErrNotAdmin
	ErrNotMember  = chains.ErrNotMember
	ErrNoChain    = errors.New("statements: the company has no admin list yet")
	ErrBadDraft   = errors.New("statements: a draft is a JSON object of a known type")
	ErrTooMany    = errors.New("statements: too many drafts waiting")
	ErrTooLarge   = errors.New("statements: too large")
	ErrNoFile     = errors.New("statements: no such file")
	ErrNoDraft    = errors.New("statements: no such draft")
	ErrMissing    = errors.New("statements: the statement names files or secrets the server doesn't have")
	ErrNewer      = errors.New("statements: the server has a state with that serial already")
	ErrBadSecret  = errors.New("statements: a secret's value doesn't match its hash in the state")
	ErrWrongPlace = errors.New("statements: the state names another server")
)

// member checks that the account is in the company, and an administrator when admin is set.
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

// Draft is a change waiting for wmanager-sign. Drafts lists them without their bodies, which DraftBody gives.
type Draft struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Body      []byte    `json:"body,omitzero"` // the exact JSON the panel made
	CreatedBy string    `json:"created_by"`
	CreatedAt time.Time `json:"created_at"`
}

// SaveDraft keeps a draft made by one of the company's administrators.
func SaveDraft(ctx context.Context, s *store.Store, accountID, companyID, typ string, body []byte) (string, error) {
	if len(body) > MaxDraft {
		return "", ErrTooLarge
	}
	if (typ != verify.TypeState && typ != verify.TypeJob && typ != verify.TypeStop) || !jsontext.Value(body).IsValid() ||
		jsontext.Value(body).Kind() != '{' {
		return "", ErrBadDraft
	}
	var id string
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		var n int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM drafts WHERE company_id = $1`, companyID).Scan(&n); err != nil {
			return err
		}
		if n >= MaxDrafts {
			return ErrTooMany
		}
		return tx.QueryRow(ctx, `INSERT INTO drafts (company_id, type, body, created_by) VALUES ($1, $2, $3, $4) RETURNING id`,
			companyID, typ, body, accountID).Scan(&id)
	})
	return id, err
}

// DraftBody is a waiting draft whole, for one of the company's administrators.
func DraftBody(ctx context.Context, s *store.Store, accountID, companyID, id string) (Draft, error) {
	var d Draft
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `SELECT d.id, d.type, d.body, coalesce(a.email, ''), d.created_at FROM drafts d
		                         LEFT JOIN accounts a ON a.id = d.created_by WHERE d.company_id = $1 AND d.id = $2`,
			companyID, id).Scan(&d.ID, &d.Type, &d.Body, &d.CreatedBy, &d.CreatedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoDraft
		}
		return err
	})
	return d, err
}

// Drafts is the company's waiting drafts, oldest first, without their bodies, for one of its administrators.
func Drafts(ctx context.Context, s *store.Store, accountID, companyID string) ([]Draft, error) {
	var out []Draft
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT d.id, d.type, coalesce(a.email, ''), d.created_at FROM drafts d
		                            LEFT JOIN accounts a ON a.id = d.created_by
		                            WHERE d.company_id = $1 ORDER BY d.created_at, d.id`, companyID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (Draft, error) {
			var d Draft
			return d, r.Scan(&d.ID, &d.Type, &d.CreatedBy, &d.CreatedAt)
		})
		return err
	})
	return out, err
}

// PutFile keeps a file of the company, from one of its administrators, and returns its hash.
func PutFile(ctx context.Context, s *store.Store, accountID, companyID string, content []byte) ([32]byte, error) {
	h := sha256.Sum256(content)
	if len(content) > MaxFile {
		return h, ErrTooLarge
	}
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO files (company_id, hash, content) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
			companyID, h[:], content)
		return err
	})
	return h, err
}

// File is a file of the company by its hash, for one of its members.
func File(ctx context.Context, s *store.Store, accountID, companyID string, hash [32]byte) ([]byte, error) {
	var content []byte
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, false); err != nil {
			return err
		}
		err := tx.QueryRow(ctx, `SELECT content FROM files WHERE company_id = $1 AND hash = $2`, companyID, hash[:]).Scan(&content)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNoFile
		}
		return err
	})
	return content, err
}

// NewestState is the company's state with the highest serial, for one of its members; nil when there is none.
func NewestState(ctx context.Context, s *store.Store, accountID, companyID string) (*verify.Signed, error) {
	var out *verify.Signed
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, false); err != nil {
			return err
		}
		var raw []byte
		err := tx.QueryRow(ctx, `SELECT signed FROM statements WHERE company_id = $1 AND type = 'state'
		                         ORDER BY serial DESC LIMIT 1`, companyID).Scan(&raw)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		out = new(verify.Signed)
		return json.Unmarshal(raw, out)
	})
	return out, err
}

// Secret is a secret's value typed in wmanager-sign, with the salt it made for it.
type Secret struct {
	Name  string `json:"name"`
	Salt  []byte `json:"salt"`
	Value []byte `json:"value"`
}

// SubmitState takes a state signed by one of the company's administrators: checked against the stored chain and
// the newest state, naming this server, with every file it names kept here and every secret's value here or given
// with it. The draft it was signed from, if any, is done with.
func SubmitState(ctx context.Context, s *store.Store, server, accountID, companyID string, signed verify.Signed,
	draftID string, secrets []Secret) (int64, error) {
	var serial int64
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		// One statement at a time per company, as for admin lists.
		if _, err := tx.Exec(ctx, `SELECT 1 FROM companies WHERE id = $1 FOR NO KEY UPDATE`, companyID); err != nil {
			return err
		}
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		ch, err := chains.Held(ctx, tx, companyID)
		if err != nil {
			return err
		}
		if ch == nil {
			return ErrNoChain
		}
		var newest int64
		if err := tx.QueryRow(ctx, `SELECT coalesce(max(serial), 0) FROM statements WHERE company_id = $1 AND type = 'state'`,
			companyID).Scan(&newest); err != nil {
			return err
		}
		st, err := ch.VerifyState(signed, newest)
		if err != nil {
			if errors.Is(err, verify.ErrStatement) && newest > 0 {
				if p, perr := verify.ParseState(signed.Statement); perr == nil && p.Serial <= newest {
					return fmt.Errorf("%w (%d)", ErrNewer, newest)
				}
			}
			return err
		}
		if server == "" || st.Server != server {
			return ErrWrongPlace
		}
		if err := haveFiles(ctx, tx, companyID, st); err != nil {
			return err
		}
		if err := keepSecrets(ctx, tx, ch.CompanyID(), companyID, st, secrets); err != nil {
			return err
		}
		raw, err := json.Marshal(signed)
		if err != nil {
			return err
		}
		h := signed.Hash()
		if _, err := tx.Exec(ctx, `INSERT INTO statements (company_id, hash, type, serial, signed, signed_by, created_by)
		                           VALUES ($1, $2, 'state', $3, $4, $5, $6)`,
			companyID, h[:], st.Serial, raw, signed.Key, accountID); err != nil {
			var pg *pgconn.PgError
			if errors.As(err, &pg) && pg.Code == "23505" {
				return ErrNewer
			}
			return err
		}
		if draftID != "" {
			tag, err := tx.Exec(ctx, `DELETE FROM drafts WHERE id = $1 AND company_id = $2 AND type = 'state'`, draftID, companyID)
			if err != nil {
				return err
			}
			if tag.RowsAffected() != 1 {
				return ErrNoDraft
			}
		}
		serial = st.Serial
		signer := ch.AdminKeys()[signed.Key].Name
		_, err = audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, "state.signed",
			map[string]any{"serial": st.Serial, "hash": hex.EncodeToString(h[:]), "signed_by": signed.Key,
				"administrator": signer, "computers": len(st.Computers), "files": len(st.Files)})
		return err
	})
	return serial, err
}

func haveFiles(ctx context.Context, tx pgx.Tx, companyID string, st *verify.State) error {
	var want [][]byte
	for _, h := range st.Files {
		b, _ := hex.DecodeString(h)
		want = append(want, b)
	}
	if len(want) == 0 {
		return nil
	}
	var n int
	if err := tx.QueryRow(ctx, `SELECT count(DISTINCT hash) FROM files WHERE company_id = $1 AND hash = ANY($2)`,
		companyID, want).Scan(&n); err != nil {
		return err
	}
	distinct := map[string]bool{}
	for _, h := range st.Files {
		distinct[h] = true
	}
	if n != len(distinct) {
		return fmt.Errorf("%w: %d of %d files", ErrMissing, len(distinct)-n, len(distinct))
	}
	return nil
}

// keepSecrets keeps the values given with a state, each checked against the hash the state names for it, and
// checks that every secret the state names has a value here.
func keepSecrets(ctx context.Context, tx pgx.Tx, companyHex, companyID string, st *verify.State, given []Secret) error {
	for _, sec := range given {
		want, ok := st.Secrets[sec.Name]
		if !ok || len(sec.Salt) != verify.SecretSaltSize || verify.SecretHash(companyHex, sec.Name, sec.Salt, sec.Value) != want {
			return ErrBadSecret
		}
		h, _ := hex.DecodeString(want)
		if _, err := tx.Exec(ctx, `INSERT INTO secrets (company_id, name, hash, salt, value) VALUES ($1, $2, $3, $4, $5)
		                           ON CONFLICT DO NOTHING`, companyID, sec.Name, h, sec.Salt, sec.Value); err != nil {
			return err
		}
	}
	var missing []string
	for name, want := range st.Secrets {
		h, _ := hex.DecodeString(want)
		var one int
		err := tx.QueryRow(ctx, `SELECT 1 FROM secrets WHERE company_id = $1 AND name = $2 AND hash = $3`, companyID, name, h).Scan(&one)
		if errors.Is(err, pgx.ErrNoRows) {
			missing = append(missing, name)
			continue
		}
		if err != nil {
			return err
		}
	}
	if len(missing) > 0 {
		slices.Sort(missing)
		return fmt.Errorf("%w: the secrets %v", ErrMissing, missing)
	}
	return nil
}

// SecretHash is a secret's value the server has, by its name and the hash a state names: not the value.
type SecretHash struct {
	Name string `json:"name"`
	Hash string `json:"hash"`
}

// SecretHashes is which secrets' values the server has, for one of the company's administrators: so that
// wmanager-sign asks again for a value the server lacks before it signs a state naming it.
func SecretHashes(ctx context.Context, s *store.Store, accountID, companyID string) ([]SecretHash, error) {
	var out []SecretHash
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT name, hash FROM secrets WHERE company_id = $1 ORDER BY name, created_at`, companyID)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (SecretHash, error) {
			var sh SecretHash
			var h []byte
			err := r.Scan(&sh.Name, &h)
			sh.Hash = hex.EncodeToString(h)
			return sh, err
		})
		return err
	})
	return out, err
}
