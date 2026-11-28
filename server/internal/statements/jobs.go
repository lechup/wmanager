package statements

import (
	"context"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Errors of jobs and stops.
var (
	ErrJobTaken = errors.New("statements: a job with that id is signed already")
	ErrNoJob    = errors.New("statements: no such job")
)

// MaxJobs is how many of the newest jobs Jobs lists.
const MaxJobs = 200

// submit is what jobs and stops share: one at a time per company, an administrator, the stored chain, the
// draft done with, the statement kept, and its audit entry.
func submit(ctx context.Context, s *store.Store, accountID, companyID string, signed verify.Signed, draftID, typ string,
	check func(tx pgx.Tx, ch *verify.Chain) (job string, details map[string]any, err error)) error {
	return s.Tx(ctx, store.System, func(tx pgx.Tx) error {
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
		job, details, err := check(tx, ch)
		if err != nil {
			return err
		}
		raw, err := json.Marshal(signed)
		if err != nil {
			return err
		}
		h := signed.Hash()
		if _, err := tx.Exec(ctx, `INSERT INTO statements (company_id, hash, type, job, signed, signed_by, created_by)
		                           VALUES ($1, $2, $3, $4, $5, $6, $7)`, companyID, h[:], typ, job, raw, signed.Key, accountID); err != nil {
			var pg *pgconn.PgError
			if errors.As(err, &pg) && pg.Code == "23505" {
				return ErrJobTaken
			}
			return err
		}
		if draftID != "" {
			tag, err := tx.Exec(ctx, `DELETE FROM drafts WHERE id = $1 AND company_id = $2 AND type = $3`, draftID, companyID, typ)
			if err != nil {
				return err
			}
			if tag.RowsAffected() != 1 {
				return ErrNoDraft
			}
		}
		details["hash"], details["signed_by"] = hex.EncodeToString(h[:]), signed.Key
		details["administrator"] = ch.AdminKeys()[signed.Key].Name
		_, err = audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, typ+".signed", details)
		return err
	})
}

// SubmitJob takes a job signed by one of the company's administrators: checked against the stored chain, its
// script kept here, its id new. When it may run is the computers' check (stage 5).
func SubmitJob(ctx context.Context, s *store.Store, accountID, companyID string, signed verify.Signed, draftID string) error {
	return submit(ctx, s, accountID, companyID, signed, draftID, verify.TypeJob, func(tx pgx.Tx, ch *verify.Chain) (string, map[string]any, error) {
		j, err := ch.VerifyJob(signed, ch.AdminKeys())
		if err != nil {
			return "", nil, err
		}
		h, _ := hex.DecodeString(j.Script)
		var one int
		if err := tx.QueryRow(ctx, `SELECT 1 FROM files WHERE company_id = $1 AND hash = $2`, companyID, h).Scan(&one); errors.Is(err, pgx.ErrNoRows) {
			return "", nil, fmt.Errorf("%w: the script", ErrMissing)
		} else if err != nil {
			return "", nil, err
		}
		return j.ID, map[string]any{"job": j.ID, "computers": len(j.Computers), "run_as": j.RunAs, "expires": j.Expires}, nil
	})
}

// SubmitStop takes a stop signed by one of the company's administrators, for a job signed here, on computers the
// job names.
func SubmitStop(ctx context.Context, s *store.Store, accountID, companyID string, signed verify.Signed, draftID string) error {
	return submit(ctx, s, accountID, companyID, signed, draftID, verify.TypeStop, func(tx pgx.Tx, ch *verify.Chain) (string, map[string]any, error) {
		st, err := ch.VerifyStop(signed, ch.AdminKeys())
		if err != nil {
			return "", nil, err
		}
		var raw []byte
		err = tx.QueryRow(ctx, `SELECT signed FROM statements WHERE company_id = $1 AND type = 'job' AND job = $2`, companyID, st.Job).Scan(&raw)
		if errors.Is(err, pgx.ErrNoRows) {
			return "", nil, ErrNoJob
		}
		if err != nil {
			return "", nil, err
		}
		var js verify.Signed
		if err := json.Unmarshal(raw, &js); err != nil {
			return "", nil, err
		}
		j, err := verify.ParseJob(js.Statement)
		if err != nil {
			return "", nil, err
		}
		for _, c := range st.Computers {
			if !slices.Contains(j.Computers, c) {
				return "", nil, fmt.Errorf("%w: the stop names a computer the job doesn't", ErrNoJob)
			}
		}
		return st.Job, map[string]any{"job": st.Job, "computers": len(st.Computers)}, nil
	})
}

// Jobs is the company's newest signed jobs, newest first, for one of its members.
func Jobs(ctx context.Context, s *store.Store, accountID, companyID string) ([]verify.Signed, error) {
	var out []verify.Signed
	err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, false); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, `SELECT signed FROM statements WHERE company_id = $1 AND type = 'job'
		                            ORDER BY created_at DESC, hash LIMIT $2`, companyID, MaxJobs)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (verify.Signed, error) {
			var raw []byte
			var s verify.Signed
			if err := r.Scan(&raw); err != nil {
				return s, err
			}
			return s, json.Unmarshal(raw, &s)
		})
		return err
	})
	return out, err
}
