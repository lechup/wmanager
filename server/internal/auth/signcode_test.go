package auth_test

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/auth"
)

// Wrong codes from many addresses: past SignCodeFailures a minute, nobody connects until the next minute.
func TestSignCodesCappedAcrossAddresses(t *testing.T) {
	svc, c, _, _ := setup(t)
	full, _, _ := enroll(t, svc, c)
	ctx := context.Background()
	code, _, err := svc.CreateSignCode(ctx, full)
	if err != nil {
		t.Fatal(err)
	}
	for i := range auth.SignCodeFailures {
		if _, _, _, err := svc.ExchangeSignCode(ctx, fmt.Sprintf("2001:db8:%x::1", i), "WRONG-CODE0"); !errors.Is(err, auth.ErrSignCode) {
			t.Fatalf("wrong code %d: %v", i, err)
		}
	}
	if _, _, _, err := svc.ExchangeSignCode(ctx, "198.51.100.7", code); !errors.Is(err, auth.ErrTooMany) {
		t.Fatalf("the right code past the cap: %v", err)
	}
	c.add(61 * time.Second)
	if tok, _, _, err := svc.ExchangeSignCode(ctx, "198.51.100.7", code); err != nil || tok == "" {
		t.Fatalf("the right code in the next minute: %v", err)
	}
	if _, _, _, err := svc.ExchangeSignCode(ctx, "198.51.100.7", code); !errors.Is(err, auth.ErrSignCode) {
		t.Fatalf("the code used twice: %v", err)
	}
}
