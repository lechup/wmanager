package verify_test

import (
	"crypto/sha256"
	"errors"
	"testing"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

var algs = []verify.Alg{verify.ES256, verify.EdDSA, verify.RS256}

func statementHash(s string) [32]byte { return sha256.Sum256([]byte(s)) }

func newKey(t *testing.T, alg verify.Alg) *softkey.Key {
	t.Helper()
	k, err := softkey.New(alg)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func TestGoodSignatureEveryAlgorithm(t *testing.T) {
	for _, alg := range algs {
		t.Run(alg.String(), func(t *testing.T) {
			k := newKey(t, alg)
			h := statementHash(`{"type":"job"}`)
			a, err := k.Sign(h, softkey.Options{})
			if err != nil {
				t.Fatal(err)
			}
			if err := verify.CheckAssertion(h, a, k.PublicKey()); err != nil {
				t.Fatalf("a good signature is refused: %v", err)
			}
		})
	}
}

func TestCOSEKeyRoundTrip(t *testing.T) {
	for _, alg := range algs {
		t.Run(alg.String(), func(t *testing.T) {
			k := newKey(t, alg)
			pk, err := verify.ParseCOSEKey(k.COSEKey())
			if err != nil {
				t.Fatal(err)
			}
			h := statementHash("state 42")
			a, err := k.Sign(h, softkey.Options{})
			if err != nil {
				t.Fatal(err)
			}
			if err := verify.CheckAssertion(h, a, pk); err != nil {
				t.Fatalf("the key read from COSE doesn't check its own signature: %v", err)
			}
		})
	}
}

func TestRefusals(t *testing.T) {
	h := statementHash(`{"type":"state","serial":42}`)
	other := statementHash(`{"type":"state","serial":43}`)
	cases := []struct {
		name   string
		opts   softkey.Options
		hash   [32]byte // the hash the agent checks against; zero means h
		mangle func(*verify.Assertion)
	}{
		{name: "another relying party", opts: softkey.Options{RPID: "panel.example.com"}},
		{name: "no touch", opts: softkey.Options{NoTouch: true}},
		{name: "no PIN", opts: softkey.Options{NoPIN: true}},
		{name: "synced passkey", opts: softkey.Options{BackupEligible: true}},
		{name: "a web page's origin", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.get","challenge":"` + b64(h) + `","origin":"https://panel.example.com"}`)}},
		{name: "cross origin", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.get","challenge":"` + b64(h) + `","origin":"wmanager-sign:v1","crossOrigin":true}`)}},
		{name: "a registration, not a signature", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.create","challenge":"` + b64(h) + `","origin":"wmanager-sign:v1"}`)}},
		{name: "an unknown member", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.get","challenge":"` + b64(h) + `","origin":"wmanager-sign:v1","topOrigin":"x"}`)}},
		{name: "a member twice", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.get","challenge":"` + b64(h) + `","origin":"https://evil","origin":"wmanager-sign:v1"}`)}},
		{name: "a member in other case", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.get","challenge":"` + b64(h) + `","Origin":"wmanager-sign:v1"}`)}},
		{name: "another statement", hash: other},
		{name: "changed authenticator data", mangle: func(a *verify.Assertion) { a.AuthenticatorData[36] ^= 1 }},
		{name: "changed signature", mangle: func(a *verify.Assertion) { a.Signature[len(a.Signature)-1] ^= 1 }},
		{name: "extra bytes after the authenticator data", mangle: func(a *verify.Assertion) {
			a.AuthenticatorData = append(a.AuthenticatorData, 0)
		}},
	}
	for _, alg := range algs {
		for _, c := range cases {
			t.Run(alg.String()+"/"+c.name, func(t *testing.T) {
				k := newKey(t, alg)
				a, err := k.Sign(h, c.opts)
				if err != nil {
					t.Fatal(err)
				}
				if c.mangle != nil {
					c.mangle(&a)
				}
				check := h
				if c.hash != ([32]byte{}) {
					check = c.hash
				}
				err = verify.CheckAssertion(check, a, k.PublicKey())
				if !errors.Is(err, verify.ErrSignature) {
					t.Fatalf("accepted (err = %v)", err)
				}
				t.Log(err)
			})
		}
	}
}

func TestAlgorithmIsPinned(t *testing.T) {
	es := newKey(t, verify.ES256)
	ed := newKey(t, verify.EdDSA)
	h := statementHash("job")
	a, err := ed.Sign(h, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	// The admin list names ES256 for this key: an EdDSA signature must not pass, even from the right private key.
	pinned := verify.PublicKey{Alg: verify.ES256, Key: ed.PublicKey().Key}
	if err := verify.CheckAssertion(h, a, pinned); !errors.Is(err, verify.ErrSignature) {
		t.Fatalf("a signature with another algorithm than the pinned one is accepted: %v", err)
	}
	if err := verify.CheckAssertion(h, a, es.PublicKey()); !errors.Is(err, verify.ErrSignature) {
		t.Fatalf("a signature by another key is accepted: %v", err)
	}
}

func TestCOSEKeyRefusals(t *testing.T) {
	cases := map[string][]byte{
		"empty":                 {},
		"not a map":             {0x01},
		"duplicate key label":   {0xa2, 0x01, 0x02, 0x01, 0x02},
		"indefinite length map": {0xbf, 0x01, 0x02, 0xff},
		"EC2 with EdDSA":        cosePrefix(2, -8),
		"unknown key type":      cosePrefix(4, -7),
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := verify.ParseCOSEKey(raw); err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

// cosePrefix is a COSE key map with only kty and alg.
func cosePrefix(kty, alg int) []byte {
	enc := func(n int) byte {
		if n >= 0 {
			return byte(n)
		}
		return 0x20 | byte(-1-n)
	}
	b := []byte{0xa2, 0x01, enc(kty), 0x03}
	if alg >= -24 {
		return append(b, enc(alg))
	}
	return append(b, 0x39, byte((-1-alg)>>8), byte(-1-alg))
}
