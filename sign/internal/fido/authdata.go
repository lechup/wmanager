package fido

import (
	"bytes"
	"encoding/binary"
	"errors"

	"github.com/fxamacker/cbor/v2"
)

var errAuthData = errors.New("the security key's registration data is malformed")

// AttestedKey reads the credential id and the public key, in its exact bytes, from the authenticator data of a
// registration: the relying party's hash, the flags, the counter, the AAGUID, the credential id with its length,
// then the COSE key, a CBOR map, and any extensions after it.
func AttestedKey(authData []byte) (credentialID, cose []byte, err error) {
	const head = 32 + 1 + 4 + 16
	if len(authData) < head+2 || authData[32]&FlagAttested == 0 {
		return nil, nil, errAuthData
	}
	n := int(binary.BigEndian.Uint16(authData[head:]))
	rest := authData[head+2:]
	if n == 0 || n > 1023 || len(rest) < n {
		return nil, nil, errAuthData
	}
	credentialID, rest = bytes.Clone(rest[:n]), rest[n:]
	var key cbor.RawMessage
	if _, err := cbor.UnmarshalFirst(rest, &key); err != nil || len(key) == 0 || key[0]>>5 != 5 { // a map
		return nil, nil, errAuthData
	}
	return credentialID, bytes.Clone(key), nil
}

// Unwrap is the authenticator data libfido2 gives CBOR-encoded, as a byte string (its _raw_ calls, which give it
// bare, are newer than some distributions' libfido2).
func Unwrap(enc []byte) ([]byte, error) {
	var b []byte
	if len(enc) == 0 || enc[0]>>5 != 2 || cbor.Unmarshal(enc, &b) != nil {
		return nil, errAuthData
	}
	return b, nil
}
