package auth_test

import (
	"context"
	"errors"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

const pw = "a long enough password"

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

func setup(t *testing.T) (*auth.Service, *clock, *store.Store, string) {
	t.Helper()
	s := storetest.New(t)
	id, err := accounts.CreateAccount(context.Background(), s, accounts.SystemActor, "Anna@Example.com", "Anna", pw, true)
	if err != nil {
		t.Fatal(err)
	}
	c := &clock{t: time.Now()}
	svc := auth.New(s)
	svc.Now = c.now
	return svc, c, s, id
}

func secretOf(t *testing.T, otpauth string) []byte {
	t.Helper()
	u, err := url.Parse(otpauth)
	if err != nil {
		t.Fatal(err)
	}
	b, err := auth.DecodeB32(u.Query().Get("secret"))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func code(secret []byte, at time.Time) string { return auth.TOTPCode(secret, at.Unix()/auth.TOTPStep) }

// enroll signs in for the first time and sets up TOTP; it returns the full session, the secret and the codes.
func enroll(t *testing.T, svc *auth.Service, c *clock) (string, []byte, []string) {
	t.Helper()
	ctx := context.Background()
	tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok, "000000"); !errors.Is(err, auth.ErrNeedsTOTP) {
		t.Fatalf("a code before TOTP is set up: %v", err)
	}
	ses, err := svc.Lookup(ctx, tok)
	if err != nil || ses.Full || ses.HasTOTP {
		t.Fatalf("after the password: %+v %v", ses, err)
	}
	otpauth, err := svc.BeginTOTP(ctx, tok)
	if err != nil {
		t.Fatal(err)
	}
	secret := secretOf(t, otpauth)
	full, codes, err := svc.ConfirmTOTP(ctx, "198.51.100.1", tok, code(secret, c.now()))
	if err != nil {
		t.Fatal(err)
	}
	if len(codes) != 10 {
		t.Fatalf("%d recovery codes", len(codes))
	}
	if _, err := svc.Lookup(ctx, tok); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("the token from before the second factor still works: %v", err)
	}
	return full, secret, codes
}

func TestFirstSignInSetsUpTOTP(t *testing.T) {
	svc, c, _, id := setup(t)
	full, _, _ := enroll(t, svc, c)
	ses, err := svc.Lookup(context.Background(), full)
	if err != nil || !ses.Full || !ses.HasTOTP || ses.AccountID != id || !ses.IsOwner || ses.Email != "anna@example.com" {
		t.Fatalf("full session: %+v %v", ses, err)
	}
}

func TestSecondSignIn(t *testing.T) {
	svc, c, _, _ := setup(t)
	ctx := context.Background()
	_, secret, codes := enroll(t, svc, c)
	c.add(time.Minute)

	tok, err := svc.SignIn(ctx, "198.51.100.1", "ANNA@example.com ", pw)
	if err != nil {
		t.Fatal(err)
	}
	if ses, _ := svc.Lookup(ctx, tok); ses.Full {
		t.Fatal("full before the second factor")
	}
	if _, err := svc.BeginTOTP(ctx, tok); !errors.Is(err, auth.ErrHasTOTP) {
		t.Fatalf("a second TOTP secret offered: %v", err)
	}
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok, "123456"); !errors.Is(err, auth.ErrCode) {
		t.Fatalf("a wrong code: %v", err)
	}
	full, err := svc.SecondFactor(ctx, "198.51.100.1", tok, code(secret, c.now()))
	if err != nil {
		t.Fatal(err)
	}
	if ses, err := svc.Lookup(ctx, full); err != nil || !ses.Full {
		t.Fatalf("%+v %v", ses, err)
	}

	// The same code again, in the same step: refused.
	tok2, _ := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok2, code(secret, c.now())); !errors.Is(err, auth.ErrCode) {
		t.Fatalf("a code used twice: %v", err)
	}
	// A recovery code works once.
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok2, strings.ToLower(codes[3])); err != nil {
		t.Fatalf("a recovery code: %v", err)
	}
	tok3, _ := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok3, codes[3]); !errors.Is(err, auth.ErrCode) {
		t.Fatalf("a recovery code used twice: %v", err)
	}
}

func TestWrongPasswordAndUnknownAccountLookTheSame(t *testing.T) {
	svc, _, _, _ := setup(t)
	ctx := context.Background()
	_, e1 := svc.SignIn(ctx, "198.51.100.2", "anna@example.com", "wrong password here")
	_, e2 := svc.SignIn(ctx, "198.51.100.2", "nobody@example.com", pw)
	if !errors.Is(e1, auth.ErrSignIn) || !errors.Is(e2, auth.ErrSignIn) || e1.Error() != e2.Error() {
		t.Fatalf("%v / %v", e1, e2)
	}
}

func TestLockout(t *testing.T) {
	svc, c, s, _ := setup(t)
	ctx := context.Background()
	for i := range auth.MaxFailures - 1 {
		if _, err := svc.SignIn(ctx, "198.51.100.3", "anna@example.com", "wrong password here"); !errors.Is(err, auth.ErrSignIn) {
			t.Fatalf("attempt %d: %v", i+1, err)
		}
		c.add(10 * time.Second) // within the limit per address
	}
	if _, err := svc.SignIn(ctx, "198.51.100.3", "anna@example.com", "wrong password here"); !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("the last attempt: %v", err)
	}
	if _, err := svc.SignIn(ctx, "198.51.100.4", "anna@example.com", pw); !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("the right password while locked: %v", err)
	}
	c.add(auth.LockFor + time.Second)
	if _, err := svc.SignIn(ctx, "198.51.100.4", "anna@example.com", pw); err != nil {
		t.Fatalf("after the lockout: %v", err)
	}
	recs, err := audit.Read(ctx, s, store.System, audit.ServerChain)
	if err != nil {
		t.Fatal(err)
	}
	var locked bool
	for _, r := range recs {
		locked = locked || r.Entry.Action == "signin.locked"
	}
	if !locked {
		t.Fatal("no signin.locked in the audit log")
	}
}

func TestLimitPerAddress(t *testing.T) {
	svc, _, _, _ := setup(t)
	ctx := context.Background()
	var err error
	for range auth.PerAddress + 1 {
		_, err = svc.SignIn(ctx, "198.51.100.5", "nobody@example.com", pw)
	}
	if !errors.Is(err, auth.ErrTooMany) {
		t.Fatalf("attempt %d from one address: %v", auth.PerAddress+1, err)
	}
	if _, err := svc.SignIn(ctx, "198.51.100.6", "nobody@example.com", pw); !errors.Is(err, auth.ErrSignIn) {
		t.Fatalf("another address: %v", err)
	}
}

func TestSessionEnds(t *testing.T) {
	svc, c, _, _ := setup(t)
	ctx := context.Background()
	full, secret, _ := enroll(t, svc, c)

	c.add(auth.SessionIdle + time.Minute)
	if _, err := svc.Lookup(ctx, full); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("an idle session: %v", err)
	}

	c.add(time.Minute)
	tok, _ := svc.SignIn(ctx, "198.51.100.7", "anna@example.com", pw)
	c.add(auth.PasswordStage + time.Second)
	if _, err := svc.SecondFactor(ctx, "198.51.100.7", tok, code(secret, c.now())); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("a second factor after the password step expired: %v", err)
	}

	tok, _ = svc.SignIn(ctx, "198.51.100.7", "anna@example.com", pw)
	full, err := svc.SecondFactor(ctx, "198.51.100.7", tok, code(secret, c.now()))
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.SignOut(ctx, full); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Lookup(ctx, full); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("after sign-out: %v", err)
	}
}
