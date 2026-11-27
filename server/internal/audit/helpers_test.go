package audit_test

import "crypto/sha256"

func sha(prev, entry []byte) []byte {
	h := sha256.New()
	h.Write(prev)
	h.Write(entry)
	return h.Sum(nil)
}
