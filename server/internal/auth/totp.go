package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// TOTP as authenticator apps know it (RFC 6238): HMAC-SHA1, 6 digits, 30-second steps. A code is accepted for the
// step before and after the current one, and only once: a step at or below the last one used is refused, so a code
// seen over someone's shoulder can't be used again.
const (
	totpStep   = 30
	totpDigits = 6
	totpSkew   = 1
)

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// newTOTPSecret makes a 160-bit secret, the size RFC 4226 recommends for HMAC-SHA1.
func newTOTPSecret() []byte {
	s := make([]byte, 20)
	rand.Read(s)
	return s
}

// TOTPURL is the otpauth:// address an authenticator app reads from a QR code.
func TOTPURL(secret []byte, email string) string {
	v := url.Values{}
	v.Set("secret", b32.EncodeToString(secret))
	v.Set("issuer", "wmanager")
	v.Set("algorithm", "SHA1")
	v.Set("digits", fmt.Sprint(totpDigits))
	v.Set("period", fmt.Sprint(totpStep))
	return "otpauth://totp/" + url.PathEscape("wmanager:"+email) + "?" + v.Encode()
}

func totpCode(secret []byte, step int64) string {
	m := hmac.New(sha1.New, secret)
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], uint64(step))
	m.Write(b[:])
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	n := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%0*d", totpDigits, n%1000000)
}

// checkTOTP returns the step a code belongs to, if it is valid now and newer than lastStep.
func checkTOTP(secret []byte, code string, now time.Time, lastStep int64) (int64, bool) {
	code = strings.ReplaceAll(strings.TrimSpace(code), " ", "")
	if len(code) != totpDigits {
		return 0, false
	}
	cur := now.Unix() / totpStep
	for step := cur - totpSkew; step <= cur+totpSkew; step++ {
		if step <= lastStep {
			continue
		}
		if hmac.Equal([]byte(totpCode(secret, step)), []byte(code)) {
			return step, true
		}
	}
	return 0, false
}

// Recovery codes: ten, each 80 random bits written as 16 base32 characters in groups of four. They are kept as
// SHA-256 hashes: with that much randomness a slow hash adds nothing.
const recoveryCodes = 10

func newRecoveryCodes() (codes []string, hashes [][]byte) {
	for range recoveryCodes {
		raw := make([]byte, 10)
		rand.Read(raw)
		s := b32.EncodeToString(raw)
		codes = append(codes, s[0:4]+"-"+s[4:8]+"-"+s[8:12]+"-"+s[12:16])
		hashes = append(hashes, recoveryHash(s))
	}
	return codes, hashes
}

func recoveryHash(code string) []byte {
	norm := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code)))
	h := sha256.Sum256([]byte("wmanager recovery code\x00" + norm))
	return h[:]
}

func looksLikeRecoveryCode(code string) bool {
	norm := strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(code))
	return len(norm) == 16
}
