// Package authtest has a software passkey for tests: it writes what a browser and a security key would send back
// for the panel's passkeys. It is never used outside tests.
package authtest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	jsonv1 "encoding/json"
	"fmt"

	"github.com/fxamacker/cbor/v2"
)

// Passkey is one software passkey, for one relying party id and origin.
type Passkey struct {
	RPID, Origin string
	key          *ecdsa.PrivateKey
	id           []byte
	counter      uint32
}

// NewPasskey makes a passkey for the relying party id and origin.
func NewPasskey(rpID, origin string) *Passkey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	id := make([]byte, 16)
	rand.Read(id)
	return &Passkey{RPID: rpID, Origin: origin, key: k, id: id}
}

// WithOrigin is the same key answering as if from another origin (a phishing page).
func (p *Passkey) WithOrigin(origin string) *Passkey {
	q := *p
	q.Origin = origin
	return &q
}

var b64 = base64.RawURLEncoding

func challenge(options []byte) (string, error) {
	var o struct {
		PublicKey struct {
			Challenge string `json:"challenge"`
		} `json:"publicKey"`
	}
	if err := jsonv1.Unmarshal(options, &o); err != nil || o.PublicKey.Challenge == "" {
		return "", fmt.Errorf("no challenge in %s: %v", options, err)
	}
	return o.PublicKey.Challenge, nil
}

func (p *Passkey) clientData(typ, challenge string) []byte {
	b, _ := jsonv1.Marshal(map[string]any{"type": typ, "challenge": challenge, "origin": p.Origin})
	return b
}

func (p *Passkey) authData(flags byte, attested bool) []byte {
	rpHash := sha256.Sum256([]byte(p.RPID))
	p.counter++
	ad := append([]byte{}, rpHash[:]...)
	ad = append(ad, flags)
	ad = binary.BigEndian.AppendUint32(ad, p.counter)
	if attested {
		ad = append(ad, make([]byte, 16)...) // AAGUID
		ad = binary.BigEndian.AppendUint16(ad, uint16(len(p.id)))
		ad = append(ad, p.id...)
		enc, _ := cbor.CoreDetEncOptions().EncMode()
		x, y := p.key.X.FillBytes(make([]byte, 32)), p.key.Y.FillBytes(make([]byte, 32))
		key, _ := enc.Marshal(map[int]any{1: 2, 3: -7, -1: 1, -2: x, -3: y})
		ad = append(ad, key...)
	}
	return ad
}

// Register answers the options of navigator.credentials.create.
func (p *Passkey) Register(options []byte) ([]byte, error) {
	ch, err := challenge(options)
	if err != nil {
		return nil, err
	}
	enc, _ := cbor.CoreDetEncOptions().EncMode()
	att, err := enc.Marshal(map[string]any{"fmt": "none", "attStmt": map[string]any{}, "authData": p.authData(0x45, true)})
	if err != nil {
		return nil, err
	}
	return jsonv1.Marshal(map[string]any{
		"id": b64.EncodeToString(p.id), "rawId": b64.EncodeToString(p.id), "type": "public-key",
		"response": map[string]string{
			"attestationObject": b64.EncodeToString(att),
			"clientDataJSON":    b64.EncodeToString(p.clientData("webauthn.create", ch)),
		},
	})
}

// Assert answers the options of navigator.credentials.get.
func (p *Passkey) Assert(options []byte) ([]byte, error) {
	ch, err := challenge(options)
	if err != nil {
		return nil, err
	}
	ad := p.authData(0x05, false)
	cd := p.clientData("webauthn.get", ch)
	h := sha256.Sum256(cd)
	digest := sha256.Sum256(append(append([]byte{}, ad...), h[:]...))
	sig, err := ecdsa.SignASN1(rand.Reader, p.key, digest[:])
	if err != nil {
		return nil, err
	}
	return jsonv1.Marshal(map[string]any{
		"id": b64.EncodeToString(p.id), "rawId": b64.EncodeToString(p.id), "type": "public-key",
		"response": map[string]string{
			"authenticatorData": b64.EncodeToString(ad),
			"clientDataJSON":    b64.EncodeToString(cd),
			"signature":         b64.EncodeToString(sig),
		},
	})
}
