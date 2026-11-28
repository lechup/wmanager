//go:build fido2 && cgo && !windows

package fido

import (
	"errors"
	"testing"
)

// The test by hand with a real security key is wmanager-sign itself (docs/sign.md); this only checks that libfido2
// is reached and that no key is reported as none.
func TestOpenWithoutAKey(t *testing.T) {
	d, err := Open(func([]string) (int, error) { return 0, nil })
	if err == nil {
		d.Close()
		t.Skip("a security key is plugged in")
	}
	if !errors.Is(err, ErrNoDevice) {
		t.Fatalf("Open: %v", err)
	}
}
