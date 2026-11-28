package home

import (
	"bytes"
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

const server, company = "https://wm.example.com:8443", "0b0c1c39-3f7e-4f8a-9c55-2d1c8a6f0e11"

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
	acme := func() *Company { return &Company{Name: "Acme", Servers: map[string]string{server: company}} }
	all := lists(t, 3)
	id := all[0].Hash()
	ch2, err := verify.VerifyChain(verify.Fingerprint(id), all[:2])
	if err != nil {
		t.Fatal(err)
	}
	if err := h.SetCompany(acme(), ch2); err != nil {
		t.Fatal(err)
	}
	ch1, _ := verify.VerifyChain(verify.Fingerprint(id), all[:1])
	if err := h.SetCompany(acme(), ch1); !errors.Is(err, verify.ErrOlderChain) {
		t.Fatalf("a shorter chain: %v", err)
	}
	ch3, _ := verify.VerifyChain(verify.Fingerprint(id), all)
	if err := h.SetCompany(acme(), ch3); err != nil {
		t.Fatal(err)
	}
	held, ch, err := h.Company(hex.EncodeToString(id[:]))
	if err != nil || held == nil || len(ch.Signed) != 3 || held.Fingerprint != verify.Fingerprint(id) || held.Name != "Acme" {
		t.Fatalf("held: %+v %v", held, err)
	}
	if c, _, err := h.ByServer(server, company); err != nil || c == nil || c.Name != "Acme" {
		t.Fatalf("ByServer: %+v %v", c, err)
	}
	if c, _, err := h.ByServer("https://other.example.com", company); err != nil || c != nil {
		t.Fatalf("ByServer of another server: %+v %v", c, err)
	}
	// Another company is filed apart, whatever a server calls it.
	other := lists(t, 1)
	chO, _ := verify.VerifyChain(verify.Fingerprint(other[0].Hash()), other)
	if err := h.SetCompany(acme(), chO); err != nil {
		t.Fatal(err)
	}
	if cs, _, err := h.Companies(); err != nil || len(cs) != 2 {
		t.Fatalf("Companies: %d %v", len(cs), err)
	}

	// The folder and files are its user's only.
	for _, p := range []string{h.Dir + "/companies", h.Dir + "/companies/" + hex.EncodeToString(id[:]) + ".json"} {
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm()&0o077 != 0 {
			t.Errorf("%s is %v", p, fi.Mode().Perm())
		}
	}

	// A file changed by hand doesn't check, nor one moved to another company's name.
	p := filepath.Join(h.Dir, "companies", hex.EncodeToString(id[:])+".json")
	b, _ := os.ReadFile(p)
	os.WriteFile(p, []byte(strings.Replace(string(b), verify.Fingerprint(id), verify.Fingerprint(other[0].Hash()), 1)), 0o600)
	if _, _, err := h.Company(hex.EncodeToString(id[:])); err == nil {
		t.Fatal("a changed file was taken")
	}
	os.WriteFile(p, b, 0o600)
	oid := other[0].Hash()
	os.Rename(filepath.Join(h.Dir, "companies", hex.EncodeToString(oid[:])+".json"), filepath.Join(h.Dir, "companies", strings.Repeat("0", 64)+".json"))
	if _, _, err := h.Company(strings.Repeat("0", 64)); err == nil {
		t.Fatal("a chain under another company's id was taken")
	}
	if _, _, err := h.Company("../../etc/passwd"); err == nil {
		t.Fatal("a path for a company id")
	}
}

func TestServerFolders(t *testing.T) {
	h := &Home{Dir: "/d"}
	for in, want := range map[string]string{
		"https://wm.example.com":      "/d/servers/wm.example.com",
		"https://wm.example.com:8443": "/d/servers/wm.example.com_8443",
		"https://[::1]:8443":          "/d/servers/ipv6_--1_8443",
		"https://[::1:8443]":          "/d/servers/ipv6_--1-8443",
	} {
		s, err := h.Server(in)
		if err != nil || s.dir != want {
			t.Errorf("Server(%q): %v %v, want %s", in, s, err, want)
		}
	}
	for _, in := range []string{"https://..", "https://.", "https://a_b", "http://wm.example.com", "https://wm.example.com/x", "https://WM"} {
		if _, err := h.Server(in); err == nil {
			t.Errorf("Server(%q) accepted", in)
		}
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

func signedState(t *testing.T, k *softkey.Key, company string, serial int64, name string) *verify.Signed {
	t.Helper()
	raw, _ := verify.Marshal(verify.State{Format: 1, Type: "state", SignedAt: time.Now().UTC().Truncate(time.Second),
		Company: company, Serial: serial, Server: "https://wm.example.com", Release: strings.Repeat("ab", 32),
		Computers: []verify.Computer{}, Files: map[string]string{"a": strings.Repeat("cd", 32)},
		Version: verify.Version{Name: name, Files: map[string]string{}}, Secrets: map[string]string{}})
	s, err := k.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return &s
}

// The states held only move forward; one with the same serial doesn't replace the one held.
func TestStatesOnlyMoveForward(t *testing.T) {
	h := &Home{Dir: t.TempDir()}
	all := lists(t, 1)
	ch, _ := verify.VerifyChain(verify.Fingerprint(all[0].Hash()), all)
	k, _ := softkey.New(verify.ES256)
	id := ch.CompanyID()
	s1, s2, s2b := signedState(t, k, id, 1, "v1"), signedState(t, k, id, 2, "v2"), signedState(t, k, id, 2, "v2b")
	get := func() *Company {
		c, _, err := h.Company(id)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c := &Company{Name: "Acme", State: s2, Mine: s2}
	if err := h.SetCompany(c, ch); err != nil {
		t.Fatal(err)
	}
	for _, next := range []*Company{{State: s1}, {State: s2b}, {Mine: s1}, {Mine: s2b}, {}} {
		if err := h.SetCompany(next, ch); err != nil {
			t.Fatal(err)
		}
		if got := get(); !bytes.Equal(got.State.Statement, s2.Statement) || !bytes.Equal(got.Mine.Statement, s2.Statement) || got.Name != "Acme" {
			t.Fatalf("after %+v: state %d, mine %d, name %q", next, Serial(got.State), Serial(got.Mine), got.Name)
		}
	}
	// The same state, refused: the flag is kept; a state dropped is forgotten.
	held := get()
	held.MineRefused = true
	h.SetCompany(held, ch)
	if !get().MineRefused {
		t.Fatal("the refusal wasn't kept")
	}
	held = get()
	held.DropMine()
	h.SetCompany(held, ch)
	if got := get(); got.Mine != nil || got.MineRefused || got.State == nil {
		t.Fatalf("after DropMine: %+v", got)
	}
}
