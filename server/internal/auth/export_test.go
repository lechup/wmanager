package auth

// For the tests in package auth_test, which make accounts with package accounts (that imports auth).
var (
	TOTPCode  = totpCode
	TOTPStep  = int64(totpStep)
	DecodeB32 = b32.DecodeString
)
