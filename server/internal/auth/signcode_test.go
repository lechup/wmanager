package auth_test

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/auth"
)

// Wrong codes from many addresses, sent side by side: past the cap a minute, nobody connects until the next minute.
func TestSignCodesCappedAcrossAddresses(t *testing.T) {
	svc, c, _, _ := setup(t)
	svc.SignCodeCap = 30
	full, _, _ := enroll(t, svc, c)
	ctx := context.Background()
	code, _, err := svc.CreateSignCode(ctx, full)
	if err != nil {
		t.Fatal(err)
	}
	var wrong, refused atomic.Int32
	var wg sync.WaitGroup
	for i := range 200 {
		wg.Go(func() {
			_, _, _, err := svc.ExchangeSignCode(ctx, fmt.Sprintf("2001:db8:%x::1", i), "WRONG-CODE0")
			switch {
			case errors.Is(err, auth.ErrSignCode):
				wrong.Add(1)
			case errors.Is(err, auth.ErrTooMany):
				refused.Add(1)
			default:
				t.Errorf("wrong code %d: %v", i, err)
			}
		})
	}
	wg.Wait()
	if wrong.Load() != 30 || refused.Load() != 170 {
		t.Fatalf("200 wrong codes side by side under a cap of 30: %d checked, %d refused", wrong.Load(), refused.Load())
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
