package verify

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rsa"
	"fmt"
	"math/big"

	"github.com/fxamacker/cbor/v2"
)

const cryptoSHA256 = crypto.SHA256

// COSE key parameters (RFC 9052, RFC 9053).
const (
	coseKty    = 1
	coseAlg    = 3
	coseCrvOrN = -1
	coseXOrE   = -2
	coseY      = -3

	ktyOKP = 1
	ktyEC2 = 2
	ktyRSA = 3

	crvP256    = 1
	crvEd25519 = 6
)

// cborStrict decodes CBOR the way a key's public key must look: no duplicate map keys, no indefinite lengths, no
// tags.
var cborStrict = func() cbor.DecMode {
	m, err := cbor.DecOptions{
		DupMapKey:   cbor.DupMapKeyEnforcedAPF,
		IndefLength: cbor.IndefLengthForbidden,
		TagsMd:      cbor.TagsForbidden,
	}.DecMode()
	if err != nil {
		panic(err)
	}
	return m
}()

// ParseCOSEKey reads the public key a FIDO2 key gives at registration (in its attested credential data), with
// the algorithm it was registered for. Only P-256 with ES256, Ed25519 with EdDSA and RSA (2048 to 4096 bits,
// exponent 65537) with RS256 are accepted, and only in the one canonical CBOR form a key has: the parameters of
// its type and no others, shortest integers, byte strings, keys in canonical order. So one key has one encoding.
func ParseCOSEKey(raw []byte) (PublicKey, error) {
	var m map[int]cbor.RawMessage
	if err := cborStrict.Unmarshal(raw, &m); err != nil {
		return PublicKey{}, fmt.Errorf("COSE key: %w", err)
	}
	var kty, alg int
	if err := intParam(m, coseKty, &kty); err != nil {
		return PublicKey{}, err
	}
	if err := intParam(m, coseAlg, &alg); err != nil {
		return PublicKey{}, err
	}
	var pk PublicKey
	canonical := map[int]any{coseKty: kty, coseAlg: alg}
	switch {
	case kty == ktyEC2 && Alg(alg) == ES256:
		var crv int
		var x, y []byte
		if err := intParam(m, coseCrvOrN, &crv); err != nil {
			return PublicKey{}, err
		}
		if crv != crvP256 {
			return PublicKey{}, fmt.Errorf("COSE key: curve %d, want P-256", crv)
		}
		if err := bytesParam(m, coseXOrE, &x); err != nil {
			return PublicKey{}, err
		}
		if err := bytesParam(m, coseY, &y); err != nil {
			return PublicKey{}, err
		}
		if len(x) != 32 || len(y) != 32 {
			return PublicKey{}, fmt.Errorf("COSE key: P-256 coordinates of %d and %d bytes", len(x), len(y))
		}
		uncompressed := append(append([]byte{4}, x...), y...)
		key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), uncompressed)
		if err != nil {
			return PublicKey{}, fmt.Errorf("COSE key: %w", err)
		}
		pk = PublicKey{Alg: ES256, Key: key}
		canonical[coseCrvOrN], canonical[coseXOrE], canonical[coseY] = crv, x, y
	case kty == ktyOKP && Alg(alg) == EdDSA:
		var crv int
		var x []byte
		if err := intParam(m, coseCrvOrN, &crv); err != nil {
			return PublicKey{}, err
		}
		if crv != crvEd25519 {
			return PublicKey{}, fmt.Errorf("COSE key: curve %d, want Ed25519", crv)
		}
		if err := bytesParam(m, coseXOrE, &x); err != nil {
			return PublicKey{}, err
		}
		pk = PublicKey{Alg: EdDSA, Key: ed25519.PublicKey(x)}
		canonical[coseCrvOrN], canonical[coseXOrE] = crv, x
	case kty == ktyRSA && Alg(alg) == RS256:
		var n, e []byte
		if err := bytesParam(m, coseCrvOrN, &n); err != nil {
			return PublicKey{}, err
		}
		if err := bytesParam(m, coseXOrE, &e); err != nil {
			return PublicKey{}, err
		}
		if len(e) == 0 || len(e) > 4 || len(n) == 0 || n[0] == 0 || e[0] == 0 {
			return PublicKey{}, fmt.Errorf("COSE key: RSA modulus or exponent not in its shortest form")
		}
		pk = PublicKey{Alg: RS256, Key: &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}}
		canonical[coseCrvOrN], canonical[coseXOrE] = n, e
	default:
		return PublicKey{}, fmt.Errorf("COSE key: key type %d with algorithm %d is not allowed", kty, alg)
	}
	again, err := cborCanonical.Marshal(canonical)
	if err != nil || !bytes.Equal(again, raw) {
		return PublicKey{}, fmt.Errorf("COSE key: not in canonical form, or with parameters it shouldn't have")
	}
	if err := CheckKey(pk); err != nil {
		return PublicKey{}, fmt.Errorf("COSE key: %w", err)
	}
	return pk, nil
}

var cborCanonical = func() cbor.EncMode {
	m, err := cbor.CoreDetEncOptions().EncMode()
	if err != nil {
		panic(err)
	}
	return m
}()

func intParam(m map[int]cbor.RawMessage, label int, v *int) error {
	raw, ok := m[label]
	if !ok {
		return fmt.Errorf("COSE key: parameter %d missing", label)
	}
	if err := cborStrict.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("COSE key: parameter %d: %w", label, err)
	}
	return nil
}

func bytesParam(m map[int]cbor.RawMessage, label int, v *[]byte) error {
	raw, ok := m[label]
	if !ok {
		return fmt.Errorf("COSE key: parameter %d missing", label)
	}
	if err := cborStrict.Unmarshal(raw, v); err != nil {
		return fmt.Errorf("COSE key: parameter %d: %w", label, err)
	}
	return nil
}
