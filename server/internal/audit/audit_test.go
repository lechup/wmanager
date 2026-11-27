package audit_test

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func add(s *store.Store, chain, company string, n int) (audit.Head, error) {
	var h audit.Head
	for i := range n {
		err := s.Tx(context.Background(), store.System, func(tx pgx.Tx) error {
			var err error
			h, err = audit.Append(context.Background(), tx, chain, company, "system", "test.event", map[string]any{"i": i})
			return err
		})
		if err != nil {
			return h, err
		}
	}
	return h, nil
}

func appendN(t *testing.T, s *store.Store, chain, company string, n int) audit.Head {
	t.Helper()
	h, err := add(s, chain, company, n)
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestChain(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	h := appendN(t, s, audit.ServerChain, "", 5)
	if h.Seq != 5 {
		t.Fatalf("seq %d", h.Seq)
	}
	got, err := audit.Verify(ctx, s, store.System, audit.ServerChain, &h)
	if err != nil || got != h {
		t.Fatalf("%v %v", got, err)
	}
	recs, _ := audit.Read(ctx, s, store.System, audit.ServerChain)
	early := audit.Head{Chain: audit.ServerChain, Seq: 2, Hash: recs[1].Hash}
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, &early); err != nil {
		t.Fatalf("an older head seen: %v", err)
	}
	fake := early
	fake.Hash[0] ^= 1
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, &fake); !errors.Is(err, audit.ErrBroken) {
		t.Fatalf("a head that isn't in the chain: %v", err)
	}
	if _, err := audit.Verify(ctx, s, store.System, "company:00000000-0000-0000-0000-000000000000", nil); !errors.Is(err, audit.ErrNoChain) {
		t.Fatalf("an unknown chain: %v", err)
	}
}

func TestConcurrentAppends(t *testing.T) {
	s := storetest.New(t)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := add(s, audit.ServerChain, "", 5); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	h, err := audit.Verify(context.Background(), s, store.System, audit.ServerChain, nil)
	if err != nil || h.Seq != 40 {
		t.Fatalf("%v %v", h, err)
	}
}

// Someone with the database itself (here: the superuser) changes an entry: Verify sees it, because the stored
// hash no longer matches, and a head seen elsewhere no longer matches either when the hashes are recomputed.
func TestTamperingIsSeen(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	appendN(t, s, audit.ServerChain, "", 3)
	recs, _ := audit.Read(ctx, s, store.System, audit.ServerChain)
	seen := audit.Head{Chain: audit.ServerChain, Seq: 3, Hash: recs[2].Hash}

	admin := storetest.Superuser(t, s)
	// The append-only triggers stop even the superuser, until it turns triggers off, as it can.
	if _, err := admin.Exec(ctx, `UPDATE audit_log SET entry = entry WHERE seq = 1`); err == nil {
		t.Fatal("the append-only trigger let an update through")
	}
	if _, err := admin.Exec(ctx, `SET session_replication_role = replica`); err != nil {
		t.Fatal(err)
	}
	tag, err := admin.Exec(ctx, `UPDATE audit_log SET entry = convert_to(replace(convert_from(entry, 'UTF8'), '"i":1', '"i":7'), 'UTF8')
	                             WHERE chain = 'server' AND seq = 2 AND position('"i":1' in convert_from(entry, 'UTF8')) > 0`)
	if err != nil || tag.RowsAffected() != 1 {
		t.Fatalf("changing an entry: %v, %d rows", err, tag.RowsAffected())
	}
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, nil); !errors.Is(err, audit.ErrBroken) {
		t.Fatalf("a changed entry: %v", err)
	}
	// Recompute every hash after the change, as a hacked server could: the chain is whole again, but it no
	// longer leads to the head seen before.
	rows, _ := admin.Query(ctx, `SELECT seq, entry FROM audit_log WHERE chain = 'server' ORDER BY seq`)
	type row struct {
		seq   int64
		entry []byte
	}
	all, _ := pgx.CollectRows(rows, func(r pgx.CollectableRow) (row, error) { var x row; return x, r.Scan(&x.seq, &x.entry) })
	prev := make([]byte, 32)
	for _, r := range all {
		h := sha(prev, r.entry)
		admin.Exec(ctx, `UPDATE audit_log SET hash = $2 WHERE chain = 'server' AND seq = $1`, r.seq, h)
		prev = h
	}
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, nil); !errors.Is(err, audit.ErrBroken) {
		t.Fatalf("a recomputed chain against the head the server keeps: %v", err)
	}
	admin.Exec(ctx, `UPDATE audit_heads SET hash = $1 WHERE chain = 'server'`, prev)
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, nil); err != nil {
		t.Fatalf("a chain and head both recomputed: %v", err)
	}
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, &seen); !errors.Is(err, audit.ErrBroken) {
		t.Fatalf("a recomputed chain against the head seen before: %v", err)
	}
}

// Row-level security: entries can't be changed or removed by the server's role, and a company's chain is read
// only by its members.
func TestRowLevelSecurity(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	owner, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, "owner@example.com", "", "a long enough password", true)
	if err != nil {
		t.Fatal(err)
	}
	member, _ := accounts.CreateAccount(ctx, s, accounts.Actor{AccountID: owner}, "m@example.com", "", "a long enough password", false)
	outsider, _ := accounts.CreateAccount(ctx, s, accounts.Actor{AccountID: owner}, "o@example.com", "", "a long enough password", false)
	acme, err := accounts.CreateCompany(ctx, s, accounts.Actor{AccountID: owner}, "Acme")
	if err != nil {
		t.Fatal(err)
	}
	if err := accounts.AddMember(ctx, s, accounts.Actor{AccountID: owner}, acme, member, accounts.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	chain := audit.CompanyChain(acme)
	if recs, err := audit.Read(ctx, s, store.Who{Account: member}, chain); err != nil || len(recs) != 2 {
		t.Fatalf("a member reads %d entries: %v", len(recs), err)
	}
	if recs, err := audit.Read(ctx, s, store.Who{Account: outsider}, chain); err != nil || len(recs) != 0 {
		t.Fatalf("an outsider reads %d entries: %v", len(recs), err)
	}
	if recs, err := audit.Read(ctx, s, store.Who{Account: owner}, chain); err != nil || len(recs) != 0 {
		t.Fatalf("the owner reads %d entries of a company it isn't in: %v", len(recs), err)
	}
	if recs, err := audit.Read(ctx, s, store.Who{Account: owner}, audit.ServerChain); err != nil || len(recs) == 0 {
		t.Fatalf("the owner reads %d entries of the server: %v", len(recs), err)
	}
	if recs, _ := audit.Read(ctx, s, store.Who{Account: member}, audit.ServerChain); len(recs) != 0 {
		t.Fatalf("a member reads %d entries of the server", len(recs))
	}
	for name, q := range map[string]string{
		"update":   `UPDATE audit_log SET entry = 'x'`,
		"delete":   `DELETE FROM audit_log`,
		"truncate": `TRUNCATE audit_log`,
	} {
		err := s.Tx(ctx, store.System, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, q); return err })
		if err == nil {
			t.Errorf("%s: allowed for the server's role", name)
		}
	}
	// An entry added straight into the table, as a member rather than the server's own work: refused by the
	// insert policy (not only by the policy of audit_heads, which Append touches first).
	err = s.Tx(ctx, store.Who{Account: member}, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO audit_log (chain, seq, company_id, entry, hash) VALUES ($1, 99, $2, 'x', 'y')`,
			chain, acme)
		return err
	})
	if err == nil || !strings.Contains(err.Error(), "row-level security") {
		t.Fatalf("an entry added as a member: %v", err)
	}
	// A chain that doesn't fit its company.
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO audit_log (chain, seq, company_id, entry, hash) VALUES ('server', 99, $1, 'x', 'y')`, acme)
		return err
	})
	if err == nil {
		t.Fatal("a company's entry in the server's chain")
	}
}

func TestExports(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		_, err := audit.Append(ctx, tx, audit.ServerChain, "", "=SUM(1)", "company.create", map[string]any{"name": "=HYPERLINK(\"x\")"})
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	recs, _ := audit.Read(ctx, s, store.System, audit.ServerChain)
	var j bytes.Buffer
	if err := audit.ExportJSON(&j, recs); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(j.String(), `"entry":{"seq":1,`) || !strings.Contains(j.String(), `"action":"company.create"`) ||
		!strings.Contains(j.String(), `"hash":"`) {
		t.Fatalf("JSON export: %s", j.String())
	}
	var c bytes.Buffer
	if err := audit.ExportCSV(&c, recs); err != nil {
		t.Fatal(err)
	}
	rows, err := csv.NewReader(&c).ReadAll()
	if err != nil || len(rows) != 2 {
		t.Fatalf("%v %v", rows, err)
	}
	if d := rows[1][4]; !strings.HasPrefix(d, `{"name":"=`) {
		t.Fatalf("details %q", d)
	}
	if a := rows[1][3]; a != "company.create" {
		t.Fatalf("action %q", a)
	}
	if a := rows[1][2]; a != "'=SUM(1)" {
		t.Fatalf("a value that a spreadsheet would read as a formula: %q", a)
	}
}

func TestVerifyWhileEntriesAreAdded(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	appendN(t, s, audit.ServerChain, "", 1)
	done := make(chan struct{})
	errs := make(chan error, 1)
	go func() {
		defer close(done)
		if _, err := add(s, audit.ServerChain, "", 100); err != nil {
			errs <- err
		}
	}()
	for {
		select {
		case <-done:
			select {
			case err := <-errs:
				t.Fatal(err)
			default:
			}
			return
		default:
		}
		if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, nil); err != nil {
			t.Fatalf("verify while appending: %v", err)
		}
	}
}

func TestVerifyByOutsiderSaysNothing(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	owner, _ := accounts.CreateAccount(ctx, s, accounts.SystemActor, "owner@example.com", "", "a long enough password", true)
	outsider, _ := accounts.CreateAccount(ctx, s, accounts.Actor{AccountID: owner}, "o@example.com", "", "a long enough password", false)
	acme, _ := accounts.CreateCompany(ctx, s, accounts.Actor{AccountID: owner}, "Acme")
	if _, err := audit.Verify(ctx, s, store.Who{Account: outsider}, audit.CompanyChain(acme), nil); !errors.Is(err, audit.ErrNoChain) {
		t.Fatalf("an outsider verifying a company's chain: %v", err)
	}
}
