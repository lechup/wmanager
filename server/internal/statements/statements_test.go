package statements

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

const server = "https://wm.example.com"

type env struct {
	t                      *testing.T
	s                      *store.Store
	company, other         string
	admin, person, outside string
	key                    *softkey.Key
	chain                  *verify.Chain
}

func setup(t *testing.T) *env {
	t.Helper()
	ctx := context.Background()
	s := storetest.New(t)
	owner, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, "owner@example.com", "Owner", "a long enough password", true)
	if err != nil {
		t.Fatal(err)
	}
	by := accounts.Actor{AccountID: owner}
	e := &env{t: t, s: s}
	e.company, _ = accounts.CreateCompany(ctx, s, by, "Acme")
	e.other, _ = accounts.CreateCompany(ctx, s, by, "Other")
	for _, p := range []struct {
		id      *string
		email   string
		company string
		role    string
	}{{&e.admin, "admin@example.com", e.company, "admin"}, {&e.person, "person@example.com", e.company, "person"},
		{&e.outside, "outside@example.com", e.other, "admin"}} {
		if *p.id, err = accounts.CreateAccount(ctx, s, accounts.SystemActor, p.email, "P", "a long enough password", false); err != nil {
			t.Fatal(err)
		}
		if err := accounts.AddMember(ctx, s, by, p.company, *p.id, p.role); err != nil {
			t.Fatal(err)
		}
	}
	if e.key, err = softkey.New(verify.ES256); err != nil {
		t.Fatal(err)
	}
	raw, _ := verify.Marshal(verify.Admins{Format: 1, Type: "admins", SignedAt: time.Now().UTC().Truncate(time.Second),
		Nonce: strings.Repeat("cd", 16), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Anna", Keys: []verify.Key{e.key.ListKey()}}}})
	first, err := e.key.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if e.chain, err = chains.Append(ctx, s, e.admin, e.company, first); err != nil {
		t.Fatal(err)
	}
	return e
}

// state signs a state of the company with the files' hashes and the secrets' hashes.
func (e *env) state(by *softkey.Key, serial int64, srv string, files map[string][]byte, secrets map[string]string) verify.Signed {
	e.t.Helper()
	fs := map[string]string{}
	for p, c := range files {
		h := sha256.Sum256(c)
		fs[p] = hex.EncodeToString(h[:])
	}
	if secrets == nil {
		secrets = map[string]string{}
	}
	raw, err := verify.Marshal(verify.State{Format: 1, Type: "state", SignedAt: time.Now().UTC().Truncate(time.Second),
		Company: e.chain.CompanyID(), Serial: serial, Server: srv, Release: strings.Repeat("ab", 32),
		Computers: []verify.Computer{}, Files: fs, Version: verify.Version{Name: "v1.0.0", Files: map[string]string{}},
		Secrets: secrets})
	if err != nil {
		e.t.Fatal(err)
	}
	s, err := by.SignStatement(raw, softkey.Options{})
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

func TestDrafts(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	id, err := SaveDraft(ctx, e.s, e.admin, e.company, "state", []byte(`{"files": {}}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		account, company, typ, body string
		want                        error
	}{
		{e.person, e.company, "state", `{}`, ErrNotAdmin},
		{e.outside, e.company, "state", `{}`, ErrNotMember},
		{e.admin, e.company, "admins", `{}`, ErrBadDraft},
		{e.admin, e.company, "state", `[1]`, ErrBadDraft},
		{e.admin, e.company, "state", `{"a":`, ErrBadDraft},
	} {
		if _, err := SaveDraft(ctx, e.s, c.account, c.company, c.typ, []byte(c.body)); !errors.Is(err, c.want) {
			t.Errorf("SaveDraft(%s, %s): %v, want %v", c.typ, c.body, err, c.want)
		}
	}
	ds, err := Drafts(ctx, e.s, e.admin, e.company)
	if err != nil || len(ds) != 1 || ds[0].ID != id || ds[0].Body != nil || ds[0].CreatedBy != "admin@example.com" {
		t.Fatalf("Drafts: %+v %v", ds, err)
	}
	if d, err := DraftBody(ctx, e.s, e.admin, e.company, id); err != nil || string(d.Body) != `{"files": {}}` || d.Type != "state" {
		t.Fatalf("DraftBody: %+v %v", d, err)
	}
	if _, err := DraftBody(ctx, e.s, e.person, e.company, id); !errors.Is(err, ErrNotAdmin) {
		t.Fatalf("a person's DraftBody: %v", err)
	}
	if _, err := DraftBody(ctx, e.s, e.outside, e.other, id); !errors.Is(err, ErrNoDraft) {
		t.Fatalf("another company's draft by id: %v", err)
	}
	if _, err := Drafts(ctx, e.s, e.outside, e.company); !errors.Is(err, ErrNotMember) {
		t.Fatalf("another company's drafts: %v", err)
	}
}

func TestStates(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	script := []byte("Write-Output 'hello'\n")
	if _, err := PutFile(ctx, e.s, e.admin, e.company, script); err != nil {
		t.Fatal(err)
	}
	if _, err := PutFile(ctx, e.s, e.person, e.company, script); !errors.Is(err, ErrNotAdmin) {
		t.Fatalf("a person's file: %v", err)
	}
	h := sha256.Sum256(script)
	if got, err := File(ctx, e.s, e.person, e.company, h); err != nil || string(got) != string(script) {
		t.Fatalf("File: %q %v", got, err)
	}
	if _, err := File(ctx, e.s, e.outside, e.company, h); !errors.Is(err, ErrNotMember) {
		t.Fatalf("another company's file: %v", err)
	}
	if _, err := File(ctx, e.s, e.admin, e.company, [32]byte{1}); !errors.Is(err, ErrNoFile) {
		t.Fatalf("no file: %v", err)
	}

	salt := make([]byte, verify.SecretSaltSize)
	value := []byte("wifi password")
	secret := verify.SecretHash(e.chain.CompanyID(), "wifi-office", salt, value)
	files := map[string][]byte{"groups/office/hello.ps1": script}
	draft, _ := SaveDraft(ctx, e.s, e.admin, e.company, "state", []byte(`{}`))

	// The refusals, each before anything is kept.
	other, _ := softkey.New(verify.ES256)
	for name, c := range map[string]struct {
		signed  verify.Signed
		account string
		draft   string
		secrets []Secret
		want    error
	}{
		"a key not in the list":  {e.state(other, 1, server, files, nil), e.admin, "", nil, verify.ErrSignature},
		"another server":         {e.state(e.key, 1, "https://other.example.com", files, nil), e.admin, "", nil, ErrWrongPlace},
		"a file not here":        {e.state(e.key, 1, server, map[string][]byte{"a.ps1": []byte("x")}, nil), e.admin, "", nil, ErrMissing},
		"a secret with no value": {e.state(e.key, 1, server, files, map[string]string{"wifi-office": secret}), e.admin, "", nil, ErrMissing},
		"a value of another hash": {e.state(e.key, 1, server, files, map[string]string{"wifi-office": secret}), e.admin, "",
			[]Secret{{"wifi-office", salt, []byte("another")}}, ErrBadSecret},
		"a value the state doesn't name": {e.state(e.key, 1, server, files, nil), e.admin, "",
			[]Secret{{"wifi-office", salt, value}}, ErrBadSecret},
		"a person":          {e.state(e.key, 1, server, files, nil), e.person, "", nil, ErrNotAdmin},
		"another's company": {e.state(e.key, 1, server, files, nil), e.outside, "", nil, ErrNotMember},
		"no such draft":     {e.state(e.key, 1, server, files, nil), e.admin, "00000000-0000-4000-8000-000000000000", nil, ErrNoDraft},
		"another company's id": {func() verify.Signed {
			st, _ := verify.ParseState(e.state(e.key, 1, server, files, nil).Statement)
			st.Company = strings.Repeat("ab", 32)
			raw, _ := verify.Marshal(st)
			s, _ := e.key.SignStatement(raw, softkey.Options{})
			return s
		}(), e.admin, "", nil, verify.ErrStatement},
	} {
		if _, err := SubmitState(ctx, e.s, server, c.account, e.company, c.signed, c.draft, c.secrets); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	if st, err := NewestState(ctx, e.s, e.admin, e.company); err != nil || st != nil {
		t.Fatalf("a state kept after the refusals: %v %v", st, err)
	}

	first := e.state(e.key, 1, server, files, map[string]string{"wifi-office": secret})
	if n, err := SubmitState(ctx, e.s, server, e.admin, e.company, first, draft, []Secret{{"wifi-office", salt, value}}); err != nil || n != 1 {
		t.Fatalf("SubmitState: %d %v", n, err)
	}
	if ds, _ := Drafts(ctx, e.s, e.admin, e.company); len(ds) != 0 {
		t.Fatalf("the draft is still waiting: %+v", ds)
	}
	// The next state names the same secret: its value is here already.
	second := e.state(e.key, 2, server, files, map[string]string{"wifi-office": secret})
	if _, err := SubmitState(ctx, e.s, server, e.admin, e.company, second, "", nil); err != nil {
		t.Fatal(err)
	}
	for _, again := range []verify.Signed{first, e.state(e.key, 2, server, files, nil)} {
		if _, err := SubmitState(ctx, e.s, server, e.admin, e.company, again, "", nil); !errors.Is(err, ErrNewer) {
			t.Errorf("a state not newer: %v", err)
		}
	}
	st, err := NewestState(ctx, e.s, e.person, e.company)
	if err != nil || st == nil || string(st.Statement) != string(second.Statement) {
		t.Fatalf("NewestState: %v", err)
	}
	if _, err := NewestState(ctx, e.s, e.outside, e.company); !errors.Is(err, ErrNotMember) {
		t.Fatalf("another company's state: %v", err)
	}

	if hs, err := SecretHashes(ctx, e.s, e.admin, e.company); err != nil || len(hs) != 1 || hs[0].Name != "wifi-office" || hs[0].Hash != secret {
		t.Fatalf("SecretHashes: %+v %v", hs, err)
	}
	if _, err := SecretHashes(ctx, e.s, e.person, e.company); !errors.Is(err, ErrNotAdmin) {
		t.Fatalf("a person's SecretHashes: %v", err)
	}
	// Secrets' values are the server's own: a member's queries see none of them, even past the member check.
	var n int
	if err := e.s.Tx(ctx, store.Who{Account: e.admin}, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM secrets`).Scan(&n)
	}); err != nil || n != 0 {
		t.Fatalf("a member's query sees %d secrets: %v", n, err)
	}
}

func TestNoChainYet(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	if _, err := SubmitState(ctx, e.s, server, e.outside, e.other, e.state(e.key, 1, server, nil, nil), "", nil); !errors.Is(err, ErrNoChain) {
		t.Fatalf("a company without a chain: %v", err)
	}
}
