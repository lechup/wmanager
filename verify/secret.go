package verify

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
)

// SecretSaltSize is the size of a secret's salt: 128 random bits, made in wmanager-sign for each value.
const SecretSaltSize = 16

// SecretHash is what a state holds of a secret's value: the SHA-256 of the company's id, the secret's name, the salt
// and the value, each with its length first, so no two of them can run into each other. The salt is kept with the
// value (on the server and the computers), not in the state, so the hashes every computer gets don't help to guess
// a weak value.
func SecretHash(company, name string, salt, value []byte) string {
	h := sha256.New()
	h.Write([]byte("wmanager secret v1\x00"))
	for _, part := range [][]byte{[]byte(company), []byte(name), salt, value} {
		h.Write(binary.BigEndian.AppendUint32(nil, uint32(len(part))))
		h.Write(part)
	}
	return hex.EncodeToString(h.Sum(nil))
}
