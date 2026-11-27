package verify_test

import "encoding/base64"

func b64(h [32]byte) string { return base64.RawURLEncoding.EncodeToString(h[:]) }
