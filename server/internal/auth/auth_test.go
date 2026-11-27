package auth_test

import (
	"context"
	"errors"
	"fmt"
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

func TestWrongPasswordsSlowDownOnlyThatAddress(t *testing.T) {
	svc, c, _, _ := setup(t)
	ctx := context.Background()
	enroll(t, svc, c)
	for i := range auth.FreePasswords + 3 {
		if _, err := svc.SignIn(ctx, "203.0.113.9", "anna@example.com", "wrong password here"); !errors.Is(err, auth.ErrSignIn) {
			t.Fatalf("wrong password %d: %v", i+1, err)
		}
	}
	// From that address even the right password waits, with the same answer as a wrong one.
	if _, err := svc.SignIn(ctx, "203.0.113.9", "anna@example.com", pw); !errors.Is(err, auth.ErrSignIn) {
		t.Fatalf("the right password from the slowed address: %v", err)
	}
	// From the person's own address nothing changes: nobody locks another out by typing wrong passwords.
	if _, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw); err != nil {
		t.Fatalf("from another address: %v", err)
	}
	c.add(auth.MaxPasswordDelay)
	if _, err := svc.SignIn(ctx, "203.0.113.9", "anna@example.com", pw); err != nil {
		t.Fatalf("after the wait: %v", err)
	}
}

func TestWrongCodesLockTheAccountLongerEachTime(t *testing.T) {
	svc, c, s, _ := setup(t)
	ctx := context.Background()
	_, secret, _ := enroll(t, svc, c)
	wrongCodes := func() {
		t.Helper()
		c.add(time.Minute)
		tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
		if err != nil {
			t.Fatal(err)
		}
		for i := range auth.MaxFailures {
			want := auth.ErrCode
			if i == auth.MaxFailures-1 {
				want = auth.ErrLocked
			}
			if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok, "000000"); !errors.Is(err, want) {
				t.Fatalf("wrong code %d: %v, want %v", i+1, err, want)
			}
		}
		if _, err := svc.SecondFactor(ctx, "198.51.100.1", tok, code(secret, c.now())); !errors.Is(err, auth.ErrLocked) {
			t.Fatalf("the right code while locked: %v", err)
		}
		if _, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw); !errors.Is(err, auth.ErrLocked) {
			t.Fatalf("the right password while locked: %v", err)
		}
	}
	signsIn := func() error {
		tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
		if err != nil {
			return err
		}
		_, err = svc.SecondFactor(ctx, "198.51.100.1", tok, code(secret, c.now()))
		return err
	}

	wrongCodes() // 15 minutes
	c.add(auth.LockFor + time.Second)
	tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if err != nil {
		t.Fatal(err)
	}
	for range auth.MaxFailures {
		svc.SecondFactor(ctx, "198.51.100.1", tok, "000000")
	}
	// The second lockout in a row lasts 30 minutes.
	c.add(auth.LockFor + time.Minute)
	if _, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw); !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("16 minutes into the second lockout: %v", err)
	}
	c.add(auth.LockFor)
	if err := signsIn(); err != nil {
		t.Fatalf("after the second lockout: %v", err)
	}
	// A sign-in resets it: the next lockout is 15 minutes again.
	wrongCodes()
	c.add(auth.LockFor + time.Second)
	if err := signsIn(); err != nil {
		t.Fatalf("after a first lockout again: %v", err)
	}
	recs, err := audit.Read(ctx, s, store.System, audit.ServerChain)
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, r := range recs {
		if r.Entry.Action == "signin.locked" {
			n++
		}
	}
	if n != 3 {
		t.Fatalf("%d signin.locked entries, want 3", n)
	}
}

func TestParallelWrongCodes(t *testing.T) {
	svc, c, s, id := setup(t)
	ctx := context.Background()
	enroll(t, svc, c)
	c.add(time.Minute)
	tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 15)
	for i := range 15 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := svc.SecondFactor(ctx, fmt.Sprintf("192.0.2.%d", i), tok, "000000")
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	counts := map[error]int{}
	for err := range results {
		switch {
		case errors.Is(err, auth.ErrCode):
			counts[auth.ErrCode]++
		case errors.Is(err, auth.ErrLocked):
			counts[auth.ErrLocked]++
		default:
			t.Fatalf("unexpected: %v", err)
		}
	}
	// Every attempt is counted, in turn: exactly MaxFailures-1 wrong codes are answered as such.
	if counts[auth.ErrCode] != auth.MaxFailures-1 || counts[auth.ErrLocked] != 15-(auth.MaxFailures-1) {
		t.Fatalf("answers %v", counts)
	}
	var lockouts int
	s.Pool.QueryRow(ctx, `SELECT lockouts FROM accounts WHERE id = $1`, id).Scan(&lockouts)
	if lockouts != 1 {
		t.Fatalf("%d lockouts", lockouts)
	}
}

func TestWrongCodeWhenSettingUp(t *testing.T) {
	svc, _, _, _ := setup(t)
	ctx := context.Background()
	tok, err := svc.SignIn(ctx, "198.51.100.1", "anna@example.com", pw)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := svc.ConfirmTOTP(ctx, "198.51.100.1", tok, "000000"); !errors.Is(err, auth.ErrNoSuchSecret) {
		t.Fatalf("a code before a secret is offered: %v", err)
	}
	if _, err := svc.BeginTOTP(ctx, tok); err != nil {
		t.Fatal(err)
	}
	for i := range auth.MaxFailures {
		want := auth.ErrCode
		if i == auth.MaxFailures-1 {
			want = auth.ErrLocked
		}
		if _, _, err := svc.ConfirmTOTP(ctx, "198.51.100.1", tok, "000000"); !errors.Is(err, want) {
			t.Fatalf("wrong new code %d: %v", i+1, err)
		}
	}
	if _, err := svc.BeginTOTP(ctx, tok); !errors.Is(err, auth.ErrLocked) {
		t.Fatalf("a new secret while locked: %v", err)
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

	// Used every hour, a session lasts past SessionIdle, up to SessionMax.
	for h := time.Duration(0); h < auth.SessionMax-time.Hour; h += time.Hour {
		c.add(time.Hour)
		if _, err := svc.Lookup(ctx, full); err != nil {
			t.Fatalf("a session in use, %v after the sign-in: %v", h+time.Hour, err)
		}
	}
	c.add(time.Hour + time.Minute)
	if _, err := svc.Lookup(ctx, full); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("a session past SessionMax: %v", err)
	}

	tok, _ := svc.SignIn(ctx, "198.51.100.7", "anna@example.com", pw)
	full, err := svc.SecondFactor(ctx, "198.51.100.7", tok, code(secret, c.now()))
	if err != nil {
		t.Fatal(err)
	}
	c.add(auth.SessionIdle + time.Minute)
	if _, err := svc.Lookup(ctx, full); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("an idle session: %v", err)
	}

	c.add(time.Minute)
	tok, _ = svc.SignIn(ctx, "198.51.100.7", "anna@example.com", pw)
	c.add(auth.PasswordStage + time.Second)
	if _, err := svc.SecondFactor(ctx, "198.51.100.7", tok, code(secret, c.now())); !errors.Is(err, auth.ErrNoSession) {
		t.Fatalf("a second factor after the password step expired: %v", err)
	}

	tok, _ = svc.SignIn(ctx, "198.51.100.7", "anna@example.com", pw)
	full, err = svc.SecondFactor(ctx, "198.51.100.7", tok, code(secret, c.now()))
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
