// Package softkey is a software FIDO2 authenticator for tests. It signs the way a security key does, and it can be
// told to misbehave (no touch, a synced passkey, another relying party) so that every refusal can be tested.
//
// It is never used outside tests: a key in software is not a security key.
package softkey

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/binary"
	"fmt"

	"github.com/fxamacker/cbor/v2"

	"github.com/lechup/wmanager/verify"
)

// Key is one credential of the software authenticator.
type Key struct {
	Alg     verify.Alg
	signer  crypto.Signer
	counter uint32
}

// New makes a key for one of the allowed algorithms.
func New(alg verify.Alg) (*Key, error) {
	var s crypto.Signer
	var err error
	switch alg {
	case verify.ES256:
		s, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	case verify.EdDSA:
		_, s, err = ed25519.GenerateKey(rand.Reader)
	case verify.RS256:
		s, err = rsa.GenerateKey(rand.Reader, 2048)
	default:
		return nil, fmt.Errorf("softkey: algorithm %v", alg)
	}
	if err != nil {
		return nil, err
	}
	return &Key{Alg: alg, signer: s}, nil
}

// PublicKey is the key as the admin list holds it.
func (k *Key) PublicKey() verify.PublicKey {
	return verify.PublicKey{Alg: k.Alg, Key: k.signer.Public()}
}

// COSEKey is the public key in the COSE form a FIDO2 key gives at registration.
func (k *Key) COSEKey() []byte {
	m := map[int]any{3: int(k.Alg)}
	switch pk := k.signer.Public().(type) {
	case *ecdsa.PublicKey:
		b, err := pk.Bytes()
		if err != nil {
			panic(err)
		}
		m[1], m[-1], m[-2], m[-3] = 2, 1, b[1:33], b[33:]
	case ed25519.PublicKey:
		m[1], m[-1], m[-2] = 1, 6, []byte(pk)
	case *rsa.PublicKey:
		e := make([]byte, 4)
		binary.BigEndian.PutUint32(e, uint32(pk.E))
		for len(e) > 1 && e[0] == 0 {
			e = e[1:]
		}
		m[1], m[-1], m[-2] = 3, pk.N.Bytes(), e
	}
	enc, err := cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
	b, err := enc.Marshal(m)
	if err != nil {
		panic(err)
	}
	return b
}

// Options change how the key signs, to test the refusals. The zero value signs as a good security key would.
type Options struct {
	RPID           string // default verify.RPID
	NoTouch        bool   // user present not set
	NoPIN          bool   // user verified not set
	BackupEligible bool   // a synced passkey
	ExtraFlags     byte   // other flags of the authenticator data, set as given
	ClientData     []byte // default verify.ClientDataJSON(hash)
}

// Sign signs a statement's hash.
func (k *Key) Sign(statementHash [32]byte, o Options) (verify.Assertion, error) {
	rpID := o.RPID
	if rpID == "" {
		rpID = verify.RPID
	}
	clientData := o.ClientData
	if clientData == nil {
		clientData = verify.ClientDataJSON(statementHash)
	}
	flags := byte(0x01 | 0x04)
	if o.NoTouch {
		flags &^= 0x01
	}
	if o.NoPIN {
		flags &^= 0x04
	}
	if o.BackupEligible {
		flags |= 0x08
	}
	flags |= o.ExtraFlags
	k.counter++
	rpHash := sha256.Sum256([]byte(rpID))
	ad := make([]byte, 0, 37)
	ad = append(ad, rpHash[:]...)
	ad = append(ad, flags)
	ad = binary.BigEndian.AppendUint32(ad, k.counter)

	clientHash := sha256.Sum256(clientData)
	signed := append(append([]byte{}, ad...), clientHash[:]...)
	var sig []byte
	var err error
	switch k.Alg {
	case verify.EdDSA:
		sig, err = k.signer.Sign(rand.Reader, signed, crypto.Hash(0))
	default:
		h := sha256.Sum256(signed)
		sig, err = k.signer.Sign(rand.Reader, h[:], crypto.SHA256)
	}
	if err != nil {
		return verify.Assertion{}, err
	}
	return verify.Assertion{AuthenticatorData: ad, ClientDataJSON: clientData, Signature: sig}, nil
}
