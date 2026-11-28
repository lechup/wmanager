package home

import (
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

const company = "0b0c1c39-3f7e-4f8a-9c55-2d1c8a6f0e11"

func lists(t *testing.T, n int) []verify.Signed {
	t.Helper()
	k, err := softkey.New(verify.ES256)
	if err != nil {
		t.Fatal(err)
	}
	admins := []verify.Administrator{{Name: "Anna", Keys: []verify.Key{k.ListKey()}}}
	raw, _ := verify.Marshal(verify.Admins{Format: 1, Type: "admins", SignedAt: time.Now().UTC().Truncate(time.Second),
		Nonce: RandomHex(16), Sequence: 1, Administrators: admins})
	first, err := k.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	out := []verify.Signed{first}
	id := first.Hash()
	for i := 2; i <= n; i++ {
		prev := out[len(out)-1].Hash()
		raw, _ := verify.Marshal(verify.Admins{Format: 1, Type: "admins", SignedAt: time.Now().UTC().Truncate(time.Second),
			Company: hex.EncodeToString(id[:]), Sequence: int64(i), Previous: hex.EncodeToString(prev[:]), Administrators: admins})
		s, err := k.SignStatement(raw, softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, s)
	}
	return out
}

func TestCompanyChainOnlyGrows(t *testing.T) {
	h := &Home{Dir: t.TempDir()}
	s, err := h.Server("https://wm.example.com:8443")
	if err != nil {
		t.Fatal(err)
	}
	all := lists(t, 3)
	ch2, err := verify.VerifyChain(verify.Fingerprint(all[0].Hash()), all[:2])
	if err != nil {
		t.Fatal(err)
	}
	if err := s.SetCompany(company, "Acme", ch2); err != nil {
		t.Fatal(err)
	}
	ch1, _ := verify.VerifyChain(verify.Fingerprint(all[0].Hash()), all[:1])
	if err := s.SetCompany(company, "Acme", ch1); !errors.Is(err, verify.ErrOlderChain) {
		t.Fatalf("a shorter chain: %v", err)
	}
	other := lists(t, 1)
	chO, _ := verify.VerifyChain(verify.Fingerprint(other[0].Hash()), other)
	if err := s.SetCompany(company, "Acme", chO); !errors.Is(err, verify.ErrForkedChain) {
		t.Fatalf("another company's chain: %v", err)
	}
	ch3, _ := verify.VerifyChain(verify.Fingerprint(all[0].Hash()), all)
	if err := s.SetCompany(company, "Acme", ch3); err != nil {
		t.Fatal(err)
	}
	held, ch, err := s.Company(company)
	if err != nil || held == nil || len(ch.Signed) != 3 || held.Fingerprint != verify.Fingerprint(all[0].Hash()) {
		t.Fatalf("held: %+v %v", held, err)
	}

	// The folder and files are its user's only.
	for _, p := range []string{h.Dir + "/servers", h.Dir + "/servers/wm.example.com_8443/companies/" + company + ".json"} {
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is %v", p, fi.Mode().Perm())
		}
	}

	// A file changed by hand doesn't check.
	p := filepath.Join(h.Dir, "servers", "wm.example.com_8443", "companies", company+".json")
	b, _ := os.ReadFile(p)
	os.WriteFile(p, []byte(strings.Replace(string(b), verify.Fingerprint(all[0].Hash()), verify.Fingerprint(other[0].Hash()), 1)), 0o600)
	if _, _, err := s.Company(company); err == nil {
		t.Fatal("a changed file was taken")
	}
	if _, _, err := s.Company("../../etc/passwd"); err == nil {
		t.Fatal("a path for a company id")
	}
}

func TestToken(t *testing.T) {
	h := &Home{Dir: t.TempDir()}
	s, _ := h.Server("https://wm.example.com")
	now := time.Now()
	if err := s.SetToken(Token{Token: "t", Account: "a", Expires: now.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if tok, err := s.Token(now); err != nil || tok == nil || tok.Token != "t" {
		t.Fatalf("token: %+v %v", tok, err)
	}
	if tok, _ := s.Token(now.Add(2 * time.Hour)); tok != nil {
		t.Fatal("an ended token")
	}
	s.ForgetToken()
	if tok, _ := s.Token(now); tok != nil {
		t.Fatal("a forgotten token")
	}
}
