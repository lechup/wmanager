package accounts_test

import (
	"context"
	"errors"
	"testing"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

const pw = "a long enough password"

func TestOnlyTheOwnerMakesAccountsAndCompanies(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	owner, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, "owner@example.com", "Owner", pw, true)
	if err != nil {
		t.Fatal(err)
	}
	by := accounts.Actor{AccountID: owner}
	admin, err := accounts.CreateAccount(ctx, s, by, "admin@example.com", "", pw, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateAccount(ctx, s, accounts.Actor{AccountID: admin}, "x@example.com", "", pw, false); !errors.Is(err, accounts.ErrNotOwner) {
		t.Fatalf("an account made by one that isn't the owner: %v", err)
	}
	if _, err := accounts.CreateCompany(ctx, s, accounts.Actor{AccountID: admin}, "Acme"); !errors.Is(err, accounts.ErrNotOwner) {
		t.Fatalf("a company made by one that isn't the owner: %v", err)
	}
	acme, err := accounts.CreateCompany(ctx, s, by, "Acme")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := accounts.CreateCompany(ctx, s, by, "Acme"); !errors.Is(err, accounts.ErrExists) {
		t.Fatalf("the same company twice: %v", err)
	}
	if _, err := accounts.CreateAccount(ctx, s, by, "ADMIN@example.com", "", pw, false); !errors.Is(err, accounts.ErrExists) {
		t.Fatalf("the same e-mail address in other case: %v", err)
	}
	if err := accounts.AddMember(ctx, s, by, acme, admin, "root"); !errors.Is(err, accounts.ErrBadRole) {
		t.Fatalf("an unknown role: %v", err)
	}
	if err := accounts.AddMember(ctx, s, by, acme, admin, accounts.RoleAdmin); err != nil {
		t.Fatal(err)
	}
	cs, err := accounts.CompaniesOf(ctx, s, admin)
	if err != nil || len(cs) != 1 || cs[0].Name != "Acme" || cs[0].Role != accounts.RoleAdmin {
		t.Fatalf("%+v %v", cs, err)
	}
	if cs, _ := accounts.CompaniesOf(ctx, s, owner); len(cs) != 0 {
		t.Fatalf("the owner is in %d companies", len(cs))
	}
	// Each change is in the audit log: the server's chain and the company's.
	if _, err := audit.Verify(ctx, s, store.System, audit.ServerChain, nil); err != nil {
		t.Fatal(err)
	}
	recs, err := audit.Read(ctx, s, store.System, audit.CompanyChain(acme))
	if err != nil || len(recs) != 2 || recs[1].Entry.Action != "member.set" || recs[1].Entry.Actor != "account:"+owner {
		t.Fatalf("%+v %v", recs, err)
	}
}

func TestBadInput(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	for _, e := range []string{"", "no-at", "@example.com", "a@", "a@b@c", "a b@example.com"} {
		if _, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, e, "", pw, false); !errors.Is(err, accounts.ErrBadEmail) {
			t.Errorf("e-mail %q: %v", e, err)
		}
	}
	for _, n := range []string{"", " Acme", "Ac\x00me", string(make([]rune, 101))} {
		if _, err := accounts.CreateCompany(ctx, s, accounts.SystemActor, n); !errors.Is(err, accounts.ErrBadName) {
			t.Errorf("company name %q: %v", n, err)
		}
	}
}
