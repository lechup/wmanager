package verify_test

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"errors"
	"strings"
	"testing"

	"github.com/fxamacker/cbor/v2"

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
	cd := func(rest string) []byte {
		return []byte(`{"type":"webauthn.get","challenge":"` + b64(h) + `"` + rest + `}`)
	}
	cases := []struct {
		name   string
		opts   softkey.Options
		hash   [32]byte // the hash the agent checks against; zero means h
		mangle func(*verify.Assertion)
		reason string
	}{
		{name: "another relying party", opts: softkey.Options{RPID: "panel.example.com"}, reason: "not for the relying party"},
		{name: "no touch", opts: softkey.Options{NoTouch: true}, reason: "user present not set"},
		{name: "no PIN", opts: softkey.Options{NoPIN: true}, reason: "user verified not set"},
		{name: "synced passkey", opts: softkey.Options{BackupEligible: true}, reason: "backup eligible"},
		{name: "backed up without eligible", opts: softkey.Options{ExtraFlags: 0x10}, reason: "backup eligible"},
		{name: "attested data in a signature", opts: softkey.Options{ExtraFlags: 0x40}, reason: "attested data or extensions"},
		{name: "extensions", opts: softkey.Options{ExtraFlags: 0x80}, reason: "attested data or extensions"},
		{name: "a web page's origin", opts: softkey.Options{ClientData: cd(`,"origin":"https://panel.example.com"`)}, reason: "origin"},
		{name: "cross origin", opts: softkey.Options{ClientData: cd(`,"origin":"wmanager-sign:v1","crossOrigin":true`)}, reason: "crossOrigin is true"},
		{name: "a registration, not a signature", opts: softkey.Options{ClientData: []byte(
			`{"type":"webauthn.create","challenge":"` + b64(h) + `","origin":"wmanager-sign:v1"}`)}, reason: `type "webauthn.create"`},
		{name: "an unknown member", opts: softkey.Options{ClientData: cd(`,"origin":"wmanager-sign:v1","topOrigin":"x"`)}, reason: "unknown object member"},
		{name: "a member twice", opts: softkey.Options{ClientData: cd(`,"origin":"https://evil","origin":"wmanager-sign:v1"`)}, reason: "duplicate object member"},
		{name: "a member in other case", opts: softkey.Options{ClientData: cd(`,"Origin":"wmanager-sign:v1"`)}, reason: "unknown object member"},
		{name: "another statement", hash: other, reason: "challenge is not the statement's hash"},
		{name: "changed authenticator data", mangle: func(a *verify.Assertion) { a.AuthenticatorData[36] ^= 1 }, reason: "signature doesn't match"},
		{name: "changed signature", mangle: func(a *verify.Assertion) { a.Signature[len(a.Signature)-1] ^= 1 }, reason: "signature doesn't match"},
		{name: "extra bytes after the authenticator data", mangle: func(a *verify.Assertion) {
			a.AuthenticatorData = append(a.AuthenticatorData, 0)
		}, reason: "38 bytes, want 37"},
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
				if !errors.Is(err, verify.ErrSignature) || !strings.Contains(err.Error(), c.reason) {
					t.Fatalf("err = %v, want a refusal for %q", err, c.reason)
				}
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
	es := newKey(t, verify.ES256).COSEKey()
	ed := newKey(t, verify.EdDSA).COSEKey()
	rs := newKey(t, verify.RS256).COSEKey()
	enc := func(v any) []byte {
		b, err := cbor.CoreDetEncOptions().EncMode()
		if err != nil {
			t.Fatal(err)
		}
		out, err := b.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	with := func(base []byte, change func(map[int]any)) []byte {
		var mm map[int]any
		mustUnmarshal(t, base, &mm)
		change(mm)
		return enc(mm)
	}
	identity := make([]byte, 32)
	identity[0] = 1 // the Ed25519 identity point: with it, a fixed signature verifies on any message
	smallRSA := func() []byte {
		var mm map[int]any
		mustUnmarshal(t, rs, &mm)
		mm[-1] = mm[-1].([]byte)[:128] // 1024 bits
		return enc(mm)
	}
	cases := map[string][]byte{
		"empty":     {},
		"not a map": {0x01},
		// The first map key, written again at the end: a valid key with one duplicate label.
		"duplicate key label":   append(append([]byte{es[0] + 1}, es[1:]...), 0x01, 0x02),
		"indefinite length map": append(append([]byte{0xbf}, es[1:]...), 0xff),
		"a tag around it":       append([]byte{0xd8, 0x18}, es...),
		"an unknown label":      with(es, func(mm map[int]any) { mm[-4] = []byte{1} }),
		"x as an array of numbers": with(es, func(mm map[int]any) {
			var arr []int
			for _, c := range mm[-2].([]byte) {
				arr = append(arr, int(c))
			}
			mm[-2] = arr
		}),
		"a non-shortest integer": func() []byte {
			b := append([]byte{}, es...)
			// kty 2 (0x02) written as a one-byte integer (0x18 0x02)
			i := bytes.Index(b, []byte{0x01, 0x02})
			return append(append(append([]byte{}, b[:i+1]...), 0x18, 0x02), b[i+2:]...)
		}(),
		"EC2 with EdDSA":           with(es, func(mm map[int]any) { mm[3] = -8 }),
		"unknown key type":         with(es, func(mm map[int]any) { mm[1] = 4 }),
		"P-256 x of 31 bytes":      with(es, func(mm map[int]any) { mm[-2] = mm[-2].([]byte)[1:] }),
		"a point off the curve":    with(es, func(mm map[int]any) { y := append([]byte{}, mm[-3].([]byte)...); y[31] ^= 1; mm[-3] = y }),
		"Ed25519 of small order":   with(ed, func(mm map[int]any) { mm[-2] = identity }),
		"Ed25519 of 31 bytes":      with(ed, func(mm map[int]any) { mm[-2] = mm[-2].([]byte)[1:] }),
		"RSA of 1024 bits":         smallRSA(),
		"RSA with exponent 3":      with(rs, func(mm map[int]any) { mm[-2] = []byte{3} }),
		"RSA exponent with a zero": with(rs, func(mm map[int]any) { mm[-2] = []byte{0, 1, 0, 1} }),
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := verify.ParseCOSEKey(raw); err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

func mustUnmarshal(t *testing.T, b []byte, v any) {
	t.Helper()
	if err := cbor.Unmarshal(b, v); err != nil {
		t.Fatal(err)
	}
}

func TestCheckKeyRefusesKeysNoAuthenticatorMakes(t *testing.T) {
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	for name, k := range map[string]verify.PublicKey{
		"ES256 on P-384":       {Alg: verify.ES256, Key: &p384.PublicKey},
		"EdDSA of 31 bytes":    {Alg: verify.EdDSA, Key: ed25519.PublicKey(make([]byte, 31))},
		"EdDSA identity point": {Alg: verify.EdDSA, Key: ed25519.PublicKey(append([]byte{1}, make([]byte, 31)...))},
		"RS256 without a key":  {Alg: verify.RS256, Key: &rsa.PublicKey{}},
		"an unknown algorithm": {Alg: verify.Alg(-36), Key: &p384.PublicKey},
	} {
		if err := verify.CheckKey(k); err == nil {
			t.Errorf("%s accepted", name)
		}
	}
}
