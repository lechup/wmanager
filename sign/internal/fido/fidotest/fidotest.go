// Package fidotest is a software security key for wmanager-sign's tests, made of softkey keys. It is never used
// outside tests: a key in software is not a security key.
package fidotest

import (
	"bytes"
	"crypto/rand"
	"sync"

	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

// Device is a software security key. Its zero value needs no PIN; PIN sets one.
type Device struct {
	PIN     string
	Options softkey.Options // how its signatures misbehave, for the refusals
	// SyncedCredentials makes it report new credentials as backup eligible (a synced passkey).
	SyncedCredentials bool

	mu    sync.Mutex
	creds []cred
	// Touches counts the signatures and credentials it made: each a touch of a real key.
	Touches int
}

type cred struct {
	id   []byte
	user fido.User
	key  *softkey.Key
}

var _ fido.Device = (*Device)(nil)

func (d *Device) Name() string   { return "software key (tests)" }
func (d *Device) NeedsPIN() bool { return d.PIN != "" }
func (d *Device) Close() error   { return nil }

// MakeCredential makes an ES256 key, as a security key does.
func (d *Device) MakeCredential(user fido.User, clientDataHash [32]byte, pin string) (fido.Credential, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if pin != d.PIN {
		return fido.Credential{}, fido.ErrPIN
	}
	k, err := softkey.New(verify.ES256)
	if err != nil {
		return fido.Credential{}, err
	}
	id := make([]byte, 32)
	rand.Read(id)
	// A security key replaces a discoverable credential with the same user id.
	kept := d.creds[:0]
	for _, c := range d.creds {
		if !bytes.Equal(c.user.ID, user.ID) {
			kept = append(kept, c)
		}
	}
	d.creds = append(kept, cred{id: id, user: user, key: k})
	d.Touches++
	flags := byte(fido.FlagUserPresent | fido.FlagUserVerified | fido.FlagAttested)
	if d.SyncedCredentials {
		flags |= fido.FlagBackupEligible
	}
	return fido.Credential{ID: id, COSE: k.COSEKey(), Flags: flags}, nil
}

// Assert signs with every credential, or the allowed ones.
func (d *Device) Assert(clientDataHash [32]byte, allow [][]byte, pin string) ([]fido.Assertion, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if pin != d.PIN {
		return nil, fido.ErrPIN
	}
	var out []fido.Assertion
	for _, c := range d.creds {
		if allow != nil && !contains(allow, c.id) {
			continue
		}
		ad, sig, err := c.key.SignClientDataHash(clientDataHash, d.Options)
		if err != nil {
			return nil, err
		}
		out = append(out, fido.Assertion{CredentialID: c.id, AuthenticatorData: ad, Signature: sig})
	}
	if len(out) == 0 {
		return nil, fido.ErrNoCreds
	}
	d.Touches++
	return out, nil
}

// Key is the software key behind a credential the device made, by its key id, to sign as it directly.
func (d *Device) Key(id string) *softkey.Key {
	d.mu.Lock()
	defer d.mu.Unlock()
	for _, c := range d.creds {
		if c.key.ID() == id {
			return c.key
		}
	}
	return nil
}

// Forget removes every credential, as a reset of the key does.
func (d *Device) Forget() {
	d.mu.Lock()
	d.creds = nil
	d.mu.Unlock()
}

// Count is how many credentials it holds.
func (d *Device) Count() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.creds)
}

func contains(list [][]byte, id []byte) bool {
	for _, x := range list {
		if bytes.Equal(x, id) {
			return true
		}
	}
	return false
}
