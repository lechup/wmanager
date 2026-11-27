package auth

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

// Argon2id parameters: 64 MiB, 2 passes, 2 lanes, about a tenth of a second on a small server.
const (
	argonMemory  = 64 * 1024
	argonTime    = 2
	argonThreads = 2
	argonKeyLen  = 32
	argonSaltLen = 16
)

// Password limits. A long passphrase is welcome; the upper limit only keeps hashing bounded.
const (
	MinPasswordChars = 12
	MaxPasswordBytes = 1024
)

// ErrWeakPassword is returned for a password that is too short or too long.
var ErrWeakPassword = fmt.Errorf("auth: a password needs at least %d characters and at most %d bytes",
	MinPasswordChars, MaxPasswordBytes)

// CheckNewPassword checks a password before it is set.
func CheckNewPassword(pw string) error {
	if utf8.RuneCountInString(pw) < MinPasswordChars || len(pw) > MaxPasswordBytes || !utf8.ValidString(pw) {
		return ErrWeakPassword
	}
	return nil
}

// hashing limits how many Argon2id hashes run at once: each takes 64 MiB, and a flood of sign-ins mustn't take
// the server's memory.
var hashing = make(chan struct{}, 4)

func argon(ctx context.Context, pw, salt []byte, time, memory uint32, threads uint8) ([]byte, error) {
	select {
	case hashing <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-hashing }()
	return argon2.IDKey(pw, salt, time, memory, threads, argonKeyLen), nil
}

// HashPassword returns the password's Argon2id hash in the PHC string form.
func HashPassword(ctx context.Context, pw string) (string, error) {
	if err := CheckNewPassword(pw); err != nil {
		return "", err
	}
	salt := make([]byte, argonSaltLen)
	rand.Read(salt)
	key, err := argon(ctx, []byte(pw), salt, argonTime, argonMemory, argonThreads)
	if err != nil {
		return "", err
	}
	b64 := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, argonMemory, argonTime, argonThreads,
		b64.EncodeToString(salt), b64.EncodeToString(key)), nil
}

var errBadHash = errors.New("auth: a password hash in an unknown form")

// checkPassword compares a password with its stored hash, in constant time.
func checkPassword(ctx context.Context, encoded, pw string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != fmt.Sprintf("v=%d", argon2.Version) {
		return false, errBadHash
	}
	var memory, time uint32
	var threads uint8
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &memory, &time, &threads); err != nil {
		return false, errBadHash
	}
	if memory > 1<<20 || time > 16 || threads == 0 {
		return false, errBadHash
	}
	b64 := base64.RawStdEncoding
	salt, err1 := b64.DecodeString(parts[4])
	want, err2 := b64.DecodeString(parts[5])
	if err1 != nil || err2 != nil || len(want) != argonKeyLen {
		return false, errBadHash
	}
	if len(pw) > MaxPasswordBytes {
		return false, nil
	}
	got, err := argon(ctx, []byte(pw), salt, time, memory, threads)
	if err != nil {
		return false, err
	}
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// dummyHash is checked against when there is no such account, so that the time taken doesn't tell whether an
// e-mail address has an account.
var dummyHash = func() string {
	h, err := HashPassword(context.Background(), "no such account, a dummy password")
	if err != nil {
		panic(err)
	}
	return h
}()
