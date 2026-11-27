// Package audit is the audit log (requirement 25): who did what and when, in chains that can't be changed
// unnoticed. Each entry holds the hash of the one before; the newest hash, the head, is written down off the
// server (docs/architecture.md, "The server inside"), so the history up to a head seen there can be checked.
package audit

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/store"
)

// ServerChain is the chain of the server's own events (accounts, companies, sign-ins of the owner).
const ServerChain = "server"

// CompanyChain is the chain of one company.
func CompanyChain(companyID string) string { return "company:" + companyID }

// Entry is one event, as it is hashed.
type Entry struct {
	Seq     int64          `json:"seq"`
	At      time.Time      `json:"at"`
	Chain   string         `json:"chain"`
	Actor   string         `json:"actor"` // "account:<id>", "system"
	Action  string         `json:"action"`
	Details map[string]any `json:"details,omitzero"`
}

// Head is the newest entry of a chain.
type Head struct {
	Chain string
	Seq   int64
	Hash  [32]byte
}

func (h Head) String() string { return fmt.Sprintf("%s #%d %x", h.Chain, h.Seq, h.Hash) }

// Append adds an entry to a chain, in the transaction of the change it records, so both are kept or neither. The
// transaction must be the server's own (store.System).
func Append(ctx context.Context, tx pgx.Tx, chain, companyID, actor, action string, details map[string]any) (Head, error) {
	if (chain == ServerChain) != (companyID == "") || (companyID != "" && chain != CompanyChain(companyID)) {
		return Head{}, fmt.Errorf("audit: chain %q doesn't fit company %q", chain, companyID)
	}
	// The head row is locked until the transaction ends, so two entries never take the same place.
	if _, err := tx.Exec(ctx, `INSERT INTO audit_heads (chain, seq, hash) VALUES ($1, 0, $2)
	                           ON CONFLICT (chain) DO NOTHING`, chain, make([]byte, 32)); err != nil {
		return Head{}, fmt.Errorf("audit: %w", err)
	}
	var seq int64
	var prev []byte
	if err := tx.QueryRow(ctx, `SELECT seq, hash FROM audit_heads WHERE chain = $1 FOR UPDATE`, chain).
		Scan(&seq, &prev); err != nil {
		return Head{}, fmt.Errorf("audit: %w", err)
	}
	e := Entry{Seq: seq + 1, At: time.Now().UTC().Truncate(time.Microsecond), Chain: chain, Actor: actor,
		Action: action, Details: details}
	raw, err := json.Marshal(e, json.Deterministic(true))
	if err != nil {
		return Head{}, fmt.Errorf("audit: %w", err)
	}
	h := link(prev, raw)
	var company any
	if companyID != "" {
		company = companyID
	}
	if _, err := tx.Exec(ctx, `INSERT INTO audit_log (chain, seq, company_id, entry, hash) VALUES ($1, $2, $3, $4, $5)`,
		chain, e.Seq, company, raw, h[:]); err != nil {
		return Head{}, fmt.Errorf("audit: %w", err)
	}
	if _, err := tx.Exec(ctx, `UPDATE audit_heads SET seq = $2, hash = $3 WHERE chain = $1`, chain, e.Seq, h[:]); err != nil {
		return Head{}, fmt.Errorf("audit: %w", err)
	}
	return Head{Chain: chain, Seq: e.Seq, Hash: h}, nil
}

func link(prev, entry []byte) [32]byte {
	d := sha256.New()
	d.Write(prev)
	d.Write(entry)
	var h [32]byte
	d.Sum(h[:0])
	return h
}

// ErrBroken means the stored chain doesn't hash to what it says, or doesn't lead to a head seen elsewhere.
var ErrBroken = errors.New("audit: the chain is broken")

// Record is an entry as stored, with its hash.
type Record struct {
	Entry Entry
	Raw   []byte
	Hash  [32]byte
}

// Read returns a chain's entries in order, checking each link. who decides, through row-level security, which
// chains can be read.
func Read(ctx context.Context, s *store.Store, who store.Who, chain string) ([]Record, error) {
	var out []Record
	err := s.Tx(ctx, who, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT seq, entry, hash FROM audit_log WHERE chain = $1 ORDER BY seq`, chain)
		if err != nil {
			return err
		}
		defer rows.Close()
		prev := make([]byte, 32)
		for rows.Next() {
			var seq int64
			var raw, stored []byte
			if err := rows.Scan(&seq, &raw, &stored); err != nil {
				return err
			}
			var e Entry
			if err := json.Unmarshal(raw, &e, json.RejectUnknownMembers(true)); err != nil {
				return fmt.Errorf("%w: entry %d: %v", ErrBroken, seq, err)
			}
			h := link(prev, raw)
			want := int64(len(out) + 1)
			if e.Seq != seq || seq != want || e.Chain != chain || !bytes.Equal(h[:], stored) {
				return fmt.Errorf("%w at entry %d", ErrBroken, want)
			}
			out = append(out, Record{Entry: e, Raw: raw, Hash: h})
			prev = h[:]
		}
		return rows.Err()
	})
	return out, err
}

// Verify checks a whole chain and, when a head seen elsewhere is given (e.g. the one wmanager-sign remembers),
// that the chain still leads to it.
func Verify(ctx context.Context, s *store.Store, who store.Who, chain string, seen *Head) (Head, error) {
	recs, err := Read(ctx, s, who, chain)
	if err != nil {
		return Head{}, err
	}
	head := Head{Chain: chain}
	if len(recs) > 0 {
		head.Seq, head.Hash = recs[len(recs)-1].Entry.Seq, recs[len(recs)-1].Hash
	}
	if seen != nil {
		if seen.Chain != chain || seen.Seq < 1 || seen.Seq > int64(len(recs)) || recs[seen.Seq-1].Hash != seen.Hash {
			return head, fmt.Errorf("%w: it no longer leads to the head seen (%s)", ErrBroken, seen)
		}
	}
	return head, nil
}

// ExportJSON writes a chain as JSON lines: each entry exactly as hashed, with its hash, so anyone can check it.
func ExportJSON(w io.Writer, recs []Record) error {
	for _, r := range recs {
		line, err := json.Marshal(struct {
			Entry jsontext.Value `json:"entry"`
			Hash  string         `json:"hash"`
		}{jsontext.Value(r.Raw), hex.EncodeToString(r.Hash[:])}, json.Deterministic(true))
		if err != nil {
			return err
		}
		if _, err := w.Write(append(line, '\n')); err != nil {
			return err
		}
	}
	return nil
}

// ExportCSV writes a chain as CSV, for a spreadsheet; the JSON export is the one to check hashes with.
func ExportCSV(w io.Writer, recs []Record) error {
	cw := csv.NewWriter(w)
	if err := cw.Write([]string{"seq", "at", "actor", "action", "details", "hash"}); err != nil {
		return err
	}
	for _, r := range recs {
		details := ""
		if len(r.Entry.Details) > 0 {
			b, err := json.Marshal(r.Entry.Details, json.Deterministic(true))
			if err != nil {
				return err
			}
			details = string(b)
		}
		if err := cw.Write([]string{fmt.Sprint(r.Entry.Seq), r.Entry.At.Format(time.RFC3339Nano), cell(r.Entry.Actor),
			cell(r.Entry.Action), cell(details), hex.EncodeToString(r.Hash[:])}); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// cell keeps a spreadsheet from reading a value as a formula: text that starts with = + - @ or a tab gets a quote
// in front (a name or a detail can come from a user).
func cell(v string) string {
	if v != "" && strings.ContainsRune("=+-@\t\r", rune(v[0])) {
		return "'" + v
	}
	return v
}
