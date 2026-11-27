package verify

import (
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
// the algorithm it was registered for. Only P-256 with ES256, Ed25519 with EdDSA and RSA (2048 bits or more) with
// RS256 are accepted.
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
		pk, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), uncompressed)
		if err != nil {
			return PublicKey{}, fmt.Errorf("COSE key: %w", err)
		}
		return PublicKey{Alg: ES256, Key: pk}, nil
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
		if len(x) != ed25519.PublicKeySize {
			return PublicKey{}, fmt.Errorf("COSE key: Ed25519 key of %d bytes", len(x))
		}
		return PublicKey{Alg: EdDSA, Key: ed25519.PublicKey(x)}, nil
	case kty == ktyRSA && Alg(alg) == RS256:
		var n, e []byte
		if err := bytesParam(m, coseCrvOrN, &n); err != nil {
			return PublicKey{}, err
		}
		if err := bytesParam(m, coseXOrE, &e); err != nil {
			return PublicKey{}, err
		}
		if len(e) == 0 || len(e) > 4 {
			return PublicKey{}, fmt.Errorf("COSE key: RSA exponent of %d bytes", len(e))
		}
		pk := &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
		if pk.N.BitLen() < 2048 {
			return PublicKey{}, fmt.Errorf("COSE key: RSA key of %d bits, want 2048 or more", pk.N.BitLen())
		}
		return PublicKey{Alg: RS256, Key: pk}, nil
	}
	return PublicKey{}, fmt.Errorf("COSE key: key type %d with algorithm %d is not allowed", kty, alg)
}

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
