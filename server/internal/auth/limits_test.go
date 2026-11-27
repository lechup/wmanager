package auth

import "testing"

func TestAddressKey(t *testing.T) {
	for in, want := range map[string]string{
		"198.51.100.7":               "198.51.100.7",
		"198.51.100.7:4433":          "198.51.100.7",
		"[2001:db8:1:2:3:4:5:6]:443": "2001:db8:1:2::/64",
		"2001:db8:1:2:ffff::1":       "2001:db8:1:2::/64",
		"::ffff:198.51.100.7":        "198.51.100.7",
		"not an address":             "not an address",
	} {
		if got := addressKey(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}
