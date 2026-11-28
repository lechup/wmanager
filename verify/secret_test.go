package verify

import "testing"

func TestSecretHash(t *testing.T) {
	company := "7f3a91c204bde85f2c6b90ae5d173b48" + "7f3a91c204bde85f2c6b90ae5d173b48"
	salt := make([]byte, SecretSaltSize)
	h := SecretHash(company, "wifi-office", salt, []byte("password"))
	if !hex64.MatchString(h) {
		t.Fatalf("not a hash: %s", h)
	}
	for name, other := range map[string]string{
		"another company": SecretHash(company[:62]+"00", "wifi-office", salt, []byte("password")),
		"another name":    SecretHash(company, "wifi-home", salt, []byte("password")),
		"another salt":    SecretHash(company, "wifi-office", append(make([]byte, 15), 1), []byte("password")),
		"another value":   SecretHash(company, "wifi-office", salt, []byte("Password")),
		// the parts can't run into each other
		"moved between name and salt": SecretHash(company, "wifi-offic", append([]byte("e"), salt[1:]...), []byte("password")),
	} {
		if other == h {
			t.Errorf("%s: the same hash", name)
		}
	}
	if SecretHash(company, "wifi-office", salt, []byte("password")) != h {
		t.Fatal("not the same twice")
	}
}
