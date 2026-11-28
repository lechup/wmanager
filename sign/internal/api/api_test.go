package api

import "testing"

func TestNormalize(t *testing.T) {
	for in, want := range map[string]string{
		"wm.example.com":              "https://wm.example.com",
		"https://WM.Example.com/":     "https://wm.example.com",
		"https://wm.example.com:443":  "https://wm.example.com",
		"https://wm.example.com:8443": "https://wm.example.com:8443",
		" https://wm.example.com ":    "https://wm.example.com",
		"https://[::1]:8443":          "https://[::1]:8443",
	} {
		got, err := Normalize(in)
		if err != nil || got != want {
			t.Errorf("Normalize(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"http://wm.example.com", "https://user@wm.example.com", "https://wm.example.com/panel",
		"https://wm.example.com?x", "https://wm.example.com#x", "https://wm.example.com:0", "https://wm.example.com:99999",
		"https://", "ftp://wm.example.com", "https://wm.example.com:08443x"} {
		if got, err := Normalize(in); err == nil {
			t.Errorf("Normalize(%q) = %q, want a refusal", in, got)
		}
	}
}
