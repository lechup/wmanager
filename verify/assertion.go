// Package verify checks what a computer acts on: the statements and their FIDO2 signatures.
//
// The same code runs in the server, the agent and wmanager-sign, so the three read a statement the same way
// (docs/architecture.md, "Signed statements").
package verify

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json/v2"
	"errors"
	"fmt"
)

// RPID is the relying party id of the signing keys. No website can claim it, so a page in a browser can't get a
// signature from them.
const RPID = "wmanager-sign.invalid"

// Origin is the only origin accepted in the client data. A browser always puts the page's https:// address there.
const Origin = "wmanager-sign:v1"

// Alg is a COSE algorithm identifier.
type Alg int

// The algorithms a signing key may use.
const (
	ES256 Alg = -7
	EdDSA Alg = -8
	RS256 Alg = -257
)

func (a Alg) String() string {
	switch a {
	case ES256:
		return "ES256"
	case EdDSA:
		return "EdDSA"
	case RS256:
		return "RS256"
	}
	return fmt.Sprintf("alg(%d)", int(a))
}

// PublicKey is a signing key's public key with the one algorithm the admin list names for it.
type PublicKey struct {
	Alg Alg
	Key any // *ecdsa.PublicKey (P-256), ed25519.PublicKey or *rsa.PublicKey
}

// Assertion is what a FIDO2 key returns when it signs: its authenticator data, the client data JSON that
// wmanager-sign built, and the signature over both.
type Assertion struct {
	AuthenticatorData []byte
	ClientDataJSON    []byte
	Signature         []byte
}

// Flags of the authenticator data (WebAuthn, section 6.1).
const (
	flagUserPresent    = 0x01
	flagUserVerified   = 0x04
	flagBackupEligible = 0x08
	flagBackupState    = 0x10
	flagAttestedData   = 0x40
	flagExtensions     = 0x80
)

// ErrSignature is returned for any assertion that doesn't pass. Its message says which check failed.
var ErrSignature = errors.New("signature refused")

func refuse(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrSignature, fmt.Sprintf(format, args...))
}

// clientData is the client data JSON as wmanager-sign builds it. Nothing else is accepted.
type clientData struct {
	Type        string `json:"type"`
	Challenge   string `json:"challenge"`
	Origin      string `json:"origin"`
	CrossOrigin *bool  `json:"crossOrigin,omitzero"`
}

// ClientDataJSON builds the client data for a statement's hash, the way wmanager-sign does.
func ClientDataJSON(statementHash [32]byte) []byte {
	b, err := json.Marshal(clientData{
		Type:      "webauthn.get",
		Challenge: base64.RawURLEncoding.EncodeToString(statementHash[:]),
		Origin:    Origin,
	})
	if err != nil {
		panic(err) // a fixed struct of strings can't fail
	}
	return b
}

// CheckAssertion checks a signature over a statement's hash (checks 3 to 5 of docs/architecture.md): the client
// data, the authenticator data and the signature with the algorithm pinned for the key.
func CheckAssertion(statementHash [32]byte, a Assertion, key PublicKey) error {
	if err := checkClientData(statementHash, a.ClientDataJSON); err != nil {
		return err
	}
	if err := checkAuthenticatorData(a.AuthenticatorData); err != nil {
		return err
	}
	clientHash := sha256.Sum256(a.ClientDataJSON)
	signed := make([]byte, 0, len(a.AuthenticatorData)+len(clientHash))
	signed = append(append(signed, a.AuthenticatorData...), clientHash[:]...)
	return checkSignature(key, signed, a.Signature)
}

func checkClientData(statementHash [32]byte, raw []byte) error {
	var cd clientData
	// Version 2 refuses a member that appears twice and matches names exactly; unknown members are refused too.
	if err := json.Unmarshal(raw, &cd, json.RejectUnknownMembers(true)); err != nil {
		return refuse("client data: %v", err)
	}
	if cd.Type != "webauthn.get" {
		return refuse("client data: type %q", cd.Type)
	}
	if cd.Origin != Origin {
		return refuse("client data: origin %q", cd.Origin)
	}
	if cd.CrossOrigin != nil && *cd.CrossOrigin {
		return refuse("client data: crossOrigin is true")
	}
	want := base64.RawURLEncoding.EncodeToString(statementHash[:])
	if cd.Challenge != want {
		return refuse("client data: the challenge is not the statement's hash")
	}
	return nil
}

func checkAuthenticatorData(ad []byte) error {
	// rpIdHash (32), flags (1), signCount (4); an assertion carries no attested data, and we ask for no extensions.
	if len(ad) != 37 {
		return refuse("authenticator data: %d bytes, want 37", len(ad))
	}
	rpHash := sha256.Sum256([]byte(RPID))
	if !bytes.Equal(ad[:32], rpHash[:]) {
		return refuse("authenticator data: not for the relying party %s", RPID)
	}
	flags := ad[32]
	switch {
	case flags&flagUserPresent == 0:
		return refuse("authenticator data: user present not set (no touch)")
	case flags&flagUserVerified == 0:
		return refuse("authenticator data: user verified not set (no PIN or biometrics)")
	case flags&(flagBackupEligible|flagBackupState) != 0:
		return refuse("authenticator data: backup eligible (a synced passkey)")
	case flags&(flagAttestedData|flagExtensions) != 0:
		return refuse("authenticator data: unexpected attested data or extensions")
	}
	return nil
}

func checkSignature(key PublicKey, signed, sig []byte) error {
	switch key.Alg {
	case ES256:
		pk, ok := key.Key.(*ecdsa.PublicKey)
		if !ok {
			return refuse("the key is not ECDSA")
		}
		h := sha256.Sum256(signed)
		if !ecdsa.VerifyASN1(pk, h[:], sig) {
			return refuse("ES256 signature doesn't match")
		}
	case EdDSA:
		pk, ok := key.Key.(ed25519.PublicKey)
		if !ok {
			return refuse("the key is not Ed25519")
		}
		if !ed25519.Verify(pk, signed, sig) {
			return refuse("EdDSA signature doesn't match")
		}
	case RS256:
		pk, ok := key.Key.(*rsa.PublicKey)
		if !ok {
			return refuse("the key is not RSA")
		}
		h := sha256.Sum256(signed)
		if err := rsa.VerifyPKCS1v15(pk, cryptoSHA256, h[:], sig); err != nil {
			return refuse("RS256 signature doesn't match")
		}
	default:
		return refuse("algorithm %v not allowed", key.Alg)
	}
	return nil
}
