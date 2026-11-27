package auth

import (
	"context"
	"strings"
	"testing"
	"time"
)

// RFC 6238, appendix B, SHA-1 (8 digits there; the last 6 here).
func TestTOTPVectors(t *testing.T) {
	secret := []byte("12345678901234567890")
	for unix, want := range map[int64]string{59: "287082", 1111111109: "081804", 1111111111: "050471",
		1234567890: "005924", 2000000000: "279037", 20000000000: "353130"} {
		if got := totpCode(secret, unix/totpStep); got != want {
			t.Errorf("at %d: %s, want %s", unix, got, want)
		}
	}
}

func TestTOTPWindowAndReplay(t *testing.T) {
	secret := newTOTPSecret()
	now := time.Unix(1_800_000_000, 0)
	step := now.Unix() / totpStep
	for _, d := range []int64{-1, 0, 1} {
		if _, ok := checkTOTP(secret, totpCode(secret, step+d), now, 0); !ok {
			t.Errorf("a code %d step(s) away is refused", d)
		}
	}
	for _, d := range []int64{-2, 2} {
		if _, ok := checkTOTP(secret, totpCode(secret, step+d), now, 0); ok {
			t.Errorf("a code %d steps away is accepted", d)
		}
	}
	code := totpCode(secret, step)
	used, ok := checkTOTP(secret, code, now, 0)
	if !ok {
		t.Fatal("refused")
	}
	if _, ok := checkTOTP(secret, code, now, used); ok {
		t.Fatal("the same code is accepted twice")
	}
	if _, ok := checkTOTP(secret, totpCode(secret, step-1), now, used); ok {
		t.Fatal("an older code is accepted after a newer one")
	}
	if _, ok := checkTOTP(secret, "12345", now, 0); ok {
		t.Fatal("a short code is accepted")
	}
}

func TestTOTPURL(t *testing.T) {
	u := TOTPURL([]byte("12345678901234567890"), "anna@example.com")
	for _, want := range []string{"otpauth://totp/wmanager:anna@example.com?", "secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
		"issuer=wmanager", "period=30", "digits=6"} {
		if !strings.Contains(u, want) {
			t.Errorf("%s lacks %s", u, want)
		}
	}
}

func TestPasswords(t *testing.T) {
	ctx := context.Background()
	if _, err := HashPassword(ctx, "short"); err != ErrWeakPassword {
		t.Fatalf("a short password: %v", err)
	}
	if _, err := HashPassword(ctx, strings.Repeat("x", MaxPasswordBytes+1)); err != ErrWeakPassword {
		t.Fatalf("a too long password: %v", err)
	}
	h, err := HashPassword(ctx, "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=65536,t=2,p=2$") {
		t.Fatalf("hash %s", h)
	}
	if ok, err := checkPassword(ctx, h, "correct horse battery staple"); !ok || err != nil {
		t.Fatalf("the right password: %v %v", ok, err)
	}
	if ok, _ := checkPassword(ctx, h, "correct horse battery stapl"); ok {
		t.Fatal("a wrong password passes")
	}
	if _, err := checkPassword(ctx, "$argon2id$v=19$m=99999999,t=2,p=2$AA$AA", "x"); err == nil {
		t.Fatal("a hash asking for too much memory is used")
	}
}

func TestRecoveryCodes(t *testing.T) {
	codes, hashes := newRecoveryCodes()
	if len(codes) != recoveryCodes || len(hashes) != recoveryCodes {
		t.Fatal(len(codes))
	}
	c := codes[0]
	if len(c) != 19 || !looksLikeRecoveryCode(c) {
		t.Fatalf("code %q", c)
	}
	if string(recoveryHash(strings.ToLower(strings.ReplaceAll(c, "-", " ")))) != string(hashes[0]) {
		t.Fatal("a code typed in lower case with spaces doesn't match")
	}
}
