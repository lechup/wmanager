// Package fido is what wmanager-sign needs of a FIDO2 security key: making a signing key on it and signing a hash
// with it, under the relying party id verify.RPID. The key itself is libfido2's (build tag fido2, libfido2.go);
// tests use a software key (fidotest).
//
// The keys it makes are discoverable (resident): a security key signs with them on any computer, without a
// credential id kept anywhere, and wmanager-sign finds which of its keys signed by checking the signature against
// the keys the admin list names.
package fido

import (
	"errors"
)

// Flags of the authenticator data (WebAuthn, "Authenticator Data").
const (
	FlagUserPresent    = 0x01
	FlagUserVerified   = 0x04
	FlagBackupEligible = 0x08
	FlagAttested       = 0x40
)

// Credential is a new signing key as the security key made it.
type Credential struct {
	ID   []byte // the credential id
	COSE []byte // its public key, exactly as the key wrote it in its attested credential data
	// Flags are those of the authenticator data of the registration: a key that reports itself backup eligible (a
	// synced passkey) is refused.
	Flags byte
}

// Assertion is one credential's signature over the authenticator data followed by the client data's hash.
type Assertion struct {
	CredentialID      []byte
	AuthenticatorData []byte
	Signature         []byte
}

// User is who a new credential is for. ID is random for each key made: a security key replaces a discoverable
// credential of the same relying party and user id, so a fixed one would overwrite an earlier key.
type User struct {
	ID          []byte
	Name        string
	DisplayName string
}

// Device is one security key.
type Device interface {
	// Name is the key's maker and model, for the screen.
	Name() string
	// NeedsPIN says whether the key verifies its user with a PIN (rather than with a fingerprint of its own).
	NeedsPIN() bool
	// MakeCredential makes a discoverable credential for verify.RPID, verifying the user (the PIN, or the key's own
	// check) and their touch. The key's ES256 is asked for.
	MakeCredential(user User, clientDataHash [32]byte, pin string) (Credential, error)
	// Assert signs the client data's hash with the key's credentials for verify.RPID, or only those allowed when
	// some are, verifying the user and their touch. A key with several credentials returns a signature from each.
	Assert(clientDataHash [32]byte, allow [][]byte, pin string) ([]Assertion, error)
	Close() error
}

// Errors.
var (
	ErrNoDevice   = errors.New("no FIDO2 security key found: plug one in")
	ErrNoSupport  = errors.New("this wmanager-sign was built without security keys (build tag fido2)")
	ErrNoUV       = errors.New("the security key has no PIN or fingerprint set: set a PIN first (e.g. fido2-token -S)")
	ErrPIN        = errors.New("the security key refused the PIN")
	ErrNoCreds    = errors.New("the security key has no signing key of wmanager-sign")
	ErrNotTouched = errors.New("the security key was not touched in time")
)

// Opener opens the security key to use. There is one only when wmanager-sign is built with security keys.
var Opener func(choose func(names []string) (int, error)) (Device, error)

// Open opens the security key plugged in; with several, choose picks one.
func Open(choose func(names []string) (int, error)) (Device, error) {
	if Opener == nil {
		return nil, ErrNoSupport
	}
	return Opener(choose)
}
