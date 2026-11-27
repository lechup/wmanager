package tpmkey

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"errors"
	"testing"
)

// The software provider works on any Windows (CI's runner too); the TPM only where there is one. Machine keys
// need an administrator, as CI's runner is.
func TestKeyLifecycle(t *testing.T) {
	for _, provider := range []string{SoftwareProvider, PlatformProvider} {
		t.Run(provider, func(t *testing.T) {
			name := "wmanager-test-" + t.Name()[len(t.Name())-8:]
			k, err := Replace(provider, name)
			if err != nil {
				if provider == PlatformProvider {
					t.Skipf("no TPM here: %v", err)
				}
				t.Fatal(err)
			}
			if _, err := Create(provider, name); !errors.Is(err, ErrExists) {
				t.Fatalf("Create over an existing key: %v", err)
			}
			digest := sha256.Sum256([]byte("wmanager test"))
			sig, err := k.SignDigest(digest[:])
			if err != nil {
				t.Fatal(err)
			}
			if !ecdsa.VerifyASN1(k.Public(), digest[:], sig) {
				t.Fatal("the signature doesn't verify")
			}
			pub := k.Public()
			k.Close()
			again, err := Open(provider, name)
			if err != nil {
				t.Fatal(err)
			}
			if !again.Public().Equal(pub) {
				t.Fatal("another key after opening again")
			}
			if err := again.Delete(); err != nil {
				t.Fatal(err)
			}
			if _, err := Open(provider, name); !errors.Is(err, ErrNotFound) {
				t.Fatalf("after Delete: %v", err)
			}
			if _, err := again.SignDigest(digest[:8]); err == nil {
				t.Fatal("a short digest signed")
			}
		})
	}
}
