package auth_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	jsonv1 "encoding/json"

	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/auth/authtest"
	"github.com/lechup/wmanager/server/internal/store"
)

var rp = auth.RP{ID: "wm.example.com", Origin: "https://wm.example.com"}

func newFakePasskey(t *testing.T) *fake {
	t.Helper()
	return &fake{t: t, p: authtest.NewPasskey(rp.ID, rp.Origin)}
}

type fake struct {
	t *testing.T
	p *authtest.Passkey
}

func (f *fake) register(t *testing.T, opts []byte) []byte {
	b, err := f.p.Register(opts)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (f *fake) assert(t *testing.T, opts []byte) []byte {
	b, err := f.p.Assert(opts)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestPasskeyAsSecondFactor(t *testing.T) {
	svc, c, _, _ := setup(t)
	ctx := context.Background()
	full, _, _ := enroll(t, svc, c)
	pk := newFakePasskey(t)

	opts, err := svc.BeginPasskeyRegistration(ctx, rp, full)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "", pk.register(t, opts)); !errors.Is(err, auth.ErrBadName) {
		t.Fatalf("an empty name: %v", err)
	}
	// The empty name was refused before the ceremony was used, so the same challenge still works.
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "laptop", pk.register(t, opts)); err != nil {
		t.Fatalf("registering: %v", err)
	}
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "again", pk.register(t, opts)); !errors.Is(err, auth.ErrNoCeremony) {
		t.Fatalf("the same answer twice: %v", err)
	}
	keys, err := svc.Passkeys(ctx, full)
	if err != nil || len(keys) != 1 || keys[0].Name != "laptop" {
		t.Fatalf("passkeys: %+v %v", keys, err)
	}

	// The next sign-in: the password, then the passkey.
	c.add(time.Minute)
	tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if err != nil {
		t.Fatal(err)
	}
	if has, _ := svc.HasPasskeys(ctx, rp, tok); !has {
		t.Fatal("HasPasskeys")
	}
	opts, err = svc.BeginPasskeySignIn(ctx, rp, tok)
	if err != nil {
		t.Fatal(err)
	}
	answer := pk.assert(t, opts)
	full2, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, answer)
	if err != nil {
		t.Fatalf("signing in with the passkey: %v", err)
	}
	if ses, err := svc.Lookup(ctx, full2); err != nil || !ses.Full {
		t.Fatalf("%+v %v", ses, err)
	}

	// The same answer again, at a new sign-in: its challenge is gone, and a new challenge doesn't fit it.
	tok, _ = svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, answer); !errors.Is(err, auth.ErrNoCeremony) {
		t.Fatalf("an answer without a ceremony: %v", err)
	}
	svc.BeginPasskeySignIn(ctx, rp, tok)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, answer); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("an old answer replayed: %v", err)
	}
	// From another origin (a phishing page): refused.
	evil := &fake{t: t, p: pk.p.WithOrigin("https://wm.example.com.evil.test")}
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, evil.assert(t, opts)); !errors.Is(err, auth.ErrPasskey) ||
		!strings.Contains(strings.ToLower(err.Error()), "origin") {
		t.Fatalf("an answer for another origin: %v", err)
	}
	// Another key, not registered: refused.
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, newFakePasskey(t).assert(t, opts)); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("an unknown key: %v", err)
	}

	// Removing it.
	if err := svc.RemovePasskey(ctx, full2, keys[0].ID); err != nil {
		t.Fatal(err)
	}
	if err := svc.RemovePasskey(ctx, full2, keys[0].ID); !errors.Is(err, auth.ErrNoSuchKey) {
		t.Fatalf("removing twice: %v", err)
	}
	if _, err := svc.BeginPasskeySignIn(ctx, rp, tok); !errors.Is(err, auth.ErrNoPasskeys) {
		t.Fatalf("a passkey sign-in without passkeys: %v", err)
	}
}

// addPasskey registers a passkey on a fresh full session.
func addPasskey(t *testing.T, svc *auth.Service, full string) *fake {
	t.Helper()
	ctx := context.Background()
	pk := newFakePasskey(t)
	opts, err := svc.BeginPasskeyRegistration(ctx, rp, full)
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "key", pk.register(t, opts)); err != nil {
		t.Fatal(err)
	}
	return pk
}

func TestPasskeyEdges(t *testing.T) {
	svc, c, s, _ := setup(t)
	ctx := context.Background()
	full, secret, _ := enroll(t, svc, c)
	pk := addPasskey(t, svc, full)

	// A refused registration answer uses its challenge up: a good answer to the same challenge is refused after it.
	opts, _ := svc.BeginPasskeyRegistration(ctx, rp, full)
	other := &fake{t: t, p: newFakePasskey(t).p.WithOrigin("https://evil.test")}
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "x", other.register(t, opts)); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("a registration from another origin: %v", err)
	}
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "x", newFakePasskey(t).register(t, opts)); !errors.Is(err, auth.ErrNoCeremony) {
		t.Fatalf("a second answer to a used challenge: %v", err)
	}
	// Adding needs a fresh second factor.
	c.add(auth.FreshFor + time.Minute)
	if _, err := svc.BeginPasskeyRegistration(ctx, rp, full); !errors.Is(err, auth.ErrStale) {
		t.Fatalf("adding a passkey long after the sign-in: %v", err)
	}

	signIn := func() string {
		t.Helper()
		c.add(time.Minute)
		tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	// A ceremony answered too late (by the service's clock).
	tok := signIn()
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	c.add(6 * time.Minute)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, pk.assert(t, opts)); !errors.Is(err, auth.ErrNoCeremony) {
		t.Fatalf("an answer after the ceremony's 5 minutes: %v", err)
	}
	// A counter going back: a cloned authenticator.
	tok = signIn()
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	pk.p.SetCounter(0)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, pk.assert(t, opts)); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("a counter that went back: %v", err)
	}
	pk.p.SetCounter(1000)

	// Another account's passkey at Anna's sign-in.
	if _, err := accountsCreate(ctx, s, "bob@example.com"); err != nil {
		t.Fatal(err)
	}
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, newFakePasskey(t).assert(t, opts)); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("an unknown key: %v", err)
	}

	// Locked by wrong codes, the passkey still works, and refused passkeys then don't count.
	tok = signIn()
	for range auth.MaxFailures {
		svc.SecondFactor(ctx, "198.51.100.1", tok, "000000")
	}
	if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok, code(secret, c.now())); !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("not locked: %v", err)
	}
	opts, _ = svc.BeginPasskeySignIn(ctx, rp, tok)
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, pk.assert(t, opts)); err != nil {
		t.Fatalf("a passkey while locked: %v", err)
	}
}

func TestWrongPasskeysLock(t *testing.T) {
	svc, c, _, _ := setup(t)
	ctx := context.Background()
	full, _, _ := enroll(t, svc, c)
	pk := newFakePasskey(t)
	opts, _ := svc.BeginPasskeyRegistration(ctx, rp, full)
	if err := svc.FinishPasskeyRegistration(ctx, rp, full, "key", pk.register(t, opts)); err != nil {
		t.Fatal(err)
	}
	c.add(time.Minute)
	tok, _ := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	var err error
	for range auth.MaxFailures {
		o, _ := svc.BeginPasskeySignIn(ctx, rp, tok)
		_, err = svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, newFakePasskey(t).assert(t, o))
	}
	if !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("after %d wrong passkeys: %v", auth.MaxFailures, err)
	}
	// Locked now: a code is refused, but a passkey may still be tried (it can't be guessed), and a wrong one
	// is no longer counted.
	opts, err = svc.BeginPasskeySignIn(ctx, rp, tok)
	if err != nil {
		t.Fatalf("a passkey ceremony while locked: %v", err)
	}
	if _, err := svc.FinishPasskeySignIn(ctx, rp, "198.51.100.1", tok, newFakePasskey(t).assert(t, opts)); !errors.Is(err, auth.ErrPasskey) {
		t.Fatalf("a wrong passkey while locked: %v", err)
	}
	var lockouts int
	svc.Store.Pool.QueryRow(ctx, `SELECT lockouts FROM accounts WHERE email = 'anna@example.com'`).Scan(&lockouts)
	if lockouts != 1 {
		t.Fatalf("%d lockouts: a passkey refused while locked was counted", lockouts)
	}
}

func TestPasskeyNeedsAFullSessionToAdd(t *testing.T) {
	svc, _, _, _ := setup(t)
	ctx := context.Background()
	tok, _ := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if _, err := svc.BeginPasskeyRegistration(ctx, rp, tok); !errors.Is(err, auth.ErrWrongStage) {
		t.Fatalf("adding a passkey at the password step: %v", err)
	}
}

func accountsCreate(ctx context.Context, s *store.Store, email string) (string, error) {
	return accounts.CreateAccount(ctx, s, accounts.SystemActor, email, "", pw, false)
}

// A credential as go-webauthn v0.18.2 stored it: an upgrade of the library that can't read it fails here.
func TestStoredCredentialStillDecodes(t *testing.T) {
	frozen := `{"id":"AQID","publicKey":"pQECAyYgASFYIA==","attestationType":"none","transport":["usb"],` +
		`"flags":{"userPresent":true,"userVerified":true,"backupEligible":false,"backupState":false},` +
		`"authenticator":{"AAGUID":"AAAAAAAAAAAAAAAAAAAAAA==","signCount":7,"cloneWarning":false,"attachment":"cross-platform"}}`
	var c webauthn.Credential
	if err := jsonv1.Unmarshal([]byte(frozen), &c); err != nil {
		t.Fatal(err)
	}
	if c.Authenticator.SignCount != 7 || !c.Flags.UserVerified || len(c.ID) != 3 {
		t.Fatalf("decoded %+v", c)
	}
}
