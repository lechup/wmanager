package statements

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

func (e *env) job(by *softkey.Key, id, script string, computers ...string) verify.Signed {
	e.t.Helper()
	now := time.Now().UTC().Truncate(time.Second)
	raw, err := verify.Marshal(verify.Job{Format: 1, Type: "job", SignedAt: now, Company: e.chain.CompanyID(), ID: id,
		Computers: computers, Script: script, RunAs: "system", Secrets: []string{}, StartAfter: now,
		Expires: now.Add(24 * time.Hour), Limit: 600})
	if err != nil {
		e.t.Fatal(err)
	}
	s, err := by.SignStatement(raw, softkey.Options{})
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

func (e *env) stop(by *softkey.Key, job string, computers ...string) verify.Signed {
	e.t.Helper()
	raw, _ := verify.Marshal(verify.Stop{Format: 1, Type: "stop", SignedAt: time.Now().UTC().Truncate(time.Second),
		Company: e.chain.CompanyID(), Job: job, Computers: computers})
	s, err := by.SignStatement(raw, softkey.Options{})
	if err != nil {
		e.t.Fatal(err)
	}
	return s
}

func TestJobs(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	script := []byte("Restart-Service Spooler\n")
	h, _ := PutFile(ctx, e.s, e.admin, e.company, script)
	sh := hex.EncodeToString(h[:])
	pc := func(n string) string { x := sha256.Sum256([]byte(n)); return hex.EncodeToString(x[:]) }
	id := strings.Repeat("1a", 16)
	draft, _ := SaveDraft(ctx, e.s, e.admin, e.company, "job", []byte(`{}`))

	other, _ := softkey.New(verify.ES256)
	for name, c := range map[string]struct {
		signed  verify.Signed
		account string
		want    error
	}{
		"a key not in the list": {e.job(other, id, sh, pc("a")), e.admin, verify.ErrSignature},
		"a script not here":     {e.job(e.key, id, strings.Repeat("ee", 32), pc("a")), e.admin, ErrMissing},
		"a person":              {e.job(e.key, id, sh, pc("a")), e.person, ErrNotAdmin},
		"another's company":     {e.job(e.key, id, sh, pc("a")), e.outside, ErrNotMember},
		"a state as a job":      {e.state(e.key, 1, server, nil, nil), e.admin, verify.ErrStatement},
	} {
		if err := SubmitJob(ctx, e.s, c.account, e.company, c.signed, ""); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	if err := SubmitJob(ctx, e.s, e.admin, e.company, e.job(e.key, id, sh, pc("a"), pc("b")), draft); err != nil {
		t.Fatal(err)
	}
	if ds, _ := Drafts(ctx, e.s, e.admin, e.company); len(ds) != 0 {
		t.Fatal("the job's draft still waits")
	}
	if err := SubmitJob(ctx, e.s, e.admin, e.company, e.job(e.key, id, sh, pc("c")), ""); !errors.Is(err, ErrJobTaken) {
		t.Fatalf("the same id again: %v", err)
	}
	js, err := Jobs(ctx, e.s, e.person, e.company)
	if err != nil || len(js) != 1 {
		t.Fatalf("Jobs: %d %v", len(js), err)
	}
	if _, err := Jobs(ctx, e.s, e.outside, e.company); !errors.Is(err, ErrNotMember) {
		t.Fatalf("another company's jobs: %v", err)
	}

	for name, c := range map[string]struct {
		signed verify.Signed
		want   error
	}{
		"no such job":                {e.stop(e.key, strings.Repeat("2b", 16), pc("a")), ErrNoJob},
		"a computer the job doesn't": {e.stop(e.key, id, pc("c")), ErrNoJob},
		"a key not in the list":      {e.stop(other, id, pc("a")), verify.ErrSignature},
	} {
		if err := SubmitStop(ctx, e.s, e.admin, e.company, c.signed, ""); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	if err := SubmitStop(ctx, e.s, e.admin, e.company, e.stop(e.key, id, pc("a")), ""); err != nil {
		t.Fatal(err)
	}
	// A second stop of the same job, for the other computer.
	if err := SubmitStop(ctx, e.s, e.admin, e.company, e.stop(e.key, id, pc("b")), ""); err != nil {
		t.Fatal(err)
	}
}
