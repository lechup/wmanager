package verify_test

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

var now = time.Date(2026, 11, 28, 9, 0, 0, 0, time.UTC)

func nonce() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func marshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := verify.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func sign(t *testing.T, k *softkey.Key, raw []byte) verify.Signed {
	t.Helper()
	s, err := k.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func hexHash(s verify.Signed) string { h := s.Hash(); return hex.EncodeToString(h[:]) }

// company makes a company: its first admin list with one administrator and her key, signed by it.
type company struct {
	t     *testing.T
	anna  *softkey.Key
	lists []verify.Signed
}

func newCompany(t *testing.T) *company {
	t.Helper()
	anna := newKey(t, verify.ES256)
	first := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Nonce: nonce(), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Anna", Keys: []verify.Key{anna.ListKey()}}}}
	return &company{t: t, anna: anna, lists: []verify.Signed{sign(t, anna, marshal(t, first))}}
}

func (c *company) id() string { return hexHash(c.lists[0]) }

func (c *company) fingerprint() string { return verify.Fingerprint(c.lists[0].Hash()) }

// next makes the next admin list with these administrators, signed by k.
func (c *company) next(k *softkey.Key, admins ...verify.Administrator) verify.Signed {
	c.t.Helper()
	a := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Company: c.id(), Sequence: int64(len(c.lists) + 1),
		Previous: hexHash(c.lists[len(c.lists)-1]), Administrators: admins}
	return sign(c.t, k, marshal(c.t, a))
}

func TestChain(t *testing.T) {
	c := newCompany(t)
	ch, err := verify.VerifyChain(strings.ToLower(c.fingerprint()), c.lists)
	if err != nil {
		t.Fatal(err)
	}
	if ch.CompanyID() != c.id() || len(ch.Lists) != 1 {
		t.Fatal("company id")
	}
	// Anna adds Bob, then Bob removes Anna's key (a lost one): each signed by a key of the list before.
	bob := newKey(t, verify.EdDSA)
	l2 := c.next(c.anna, verify.Administrator{Name: "Anna", Keys: []verify.Key{c.anna.ListKey()}},
		verify.Administrator{Name: "Bob", Keys: []verify.Key{bob.ListKey()}})
	c.lists = append(c.lists, l2)
	l3 := c.next(bob, verify.Administrator{Name: "Bob", Keys: []verify.Key{bob.ListKey()}})
	c.lists = append(c.lists, l3)
	ch, err = verify.VerifyChain(c.fingerprint(), c.lists)
	if err != nil {
		t.Fatal(err)
	}
	if len(ch.Current().Administrators) != 1 || ch.Current().Administrators[0].Name != "Bob" {
		t.Fatal("the newest list")
	}
	if _, ok := ch.AdminKeys()[c.anna.ID()]; ok {
		t.Fatal("a removed key may still sign")
	}
}

func TestChainRefusals(t *testing.T) {
	c := newCompany(t)
	stranger := newKey(t, verify.ES256)
	bob := newKey(t, verify.ES256)
	both := []verify.Administrator{{Name: "Anna", Keys: []verify.Key{c.anna.ListKey()}}, {Name: "Bob", Keys: []verify.Key{bob.ListKey()}}}
	other := newCompany(t)

	firstBy := func(k *softkey.Key, a verify.Admins) []verify.Signed {
		return []verify.Signed{sign(t, k, marshal(t, a))}
	}
	firstList := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Nonce: nonce(), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Anna", Keys: []verify.Key{c.anna.ListKey()}}}}

	cases := map[string]struct {
		lists       []verify.Signed
		fingerprint string
	}{
		"another fingerprint": {c.lists, other.fingerprint()},
		"a first list signed by a key not in it": func() struct {
			lists       []verify.Signed
			fingerprint string
		} {
			l := firstBy(stranger, firstList)
			return struct {
				lists       []verify.Signed
				fingerprint string
			}{l, verify.Fingerprint(l[0].Hash())}
		}(),
		"a second list signed by a key it adds": {append(c.lists, c.next(bob, both...)), c.fingerprint()},
		"a second list of another company": {append(c.lists, func() verify.Signed {
			a := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Company: other.id(), Sequence: 2,
				Previous: hexHash(c.lists[0]), Administrators: both}
			return sign(t, c.anna, marshal(t, a))
		}()), c.fingerprint()},
		"a second list that doesn't follow the first": {append(c.lists, func() verify.Signed {
			a := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Company: c.id(), Sequence: 2,
				Previous: hexHash(other.lists[0]), Administrators: both}
			return sign(t, c.anna, marshal(t, a))
		}()), c.fingerprint()},
		"a list skipping a number": {append(c.lists, func() verify.Signed {
			a := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Company: c.id(), Sequence: 3,
				Previous: hexHash(c.lists[0]), Administrators: both}
			return sign(t, c.anna, marshal(t, a))
		}()), c.fingerprint()},
		"no lists": {nil, c.fingerprint()},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := verify.VerifyChain(tc.fingerprint, tc.lists); err == nil {
				t.Fatal("accepted")
			}
		})
	}
}

// Check 1: exactly the members of the type, each once, in its exact case, of a known format.
func TestStrictForm(t *testing.T) {
	c := newCompany(t)
	good := string(c.lists[0].Statement)
	cases := map[string]string{
		"an unknown member":           strings.Replace(good, `"format":1`, `"format":1,"extra":true`, 1),
		"a member twice":              strings.Replace(good, `"format":1`, `"format":1,"format":1`, 1),
		"a member in other case":      strings.Replace(good, `"sequence":1`, `"Sequence":1`, 1),
		"another format":              strings.Replace(good, `"format":1`, `"format":2`, 1),
		"another type":                strings.Replace(good, `"type":"admins"`, `"type":"state"`, 1),
		"no signed_at":                strings.Replace(good, `"signed_at":"2026-11-28T09:00:00Z"`, `"signed_at":"0001-01-01T00:00:00Z"`, 1),
		"a company in the first list": strings.Replace(good, `"format":1`, `"company":"`+strings.Repeat("a", 64)+`","format":1`, 1),
		"trailing data":               good + "{}",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if raw == good {
				t.Fatal("the case didn't change the statement")
			}
			if _, err := verify.ParseAdmins([]byte(raw)); !errors.Is(err, verify.ErrStatement) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	// A key whose id isn't the hash of its public key.
	k := c.anna.ListKey()
	k.ID = strings.Repeat("0", 64)
	a := verify.Admins{Format: 1, Type: "admins", SignedAt: now, Nonce: nonce(), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Anna", Keys: []verify.Key{k}}}}
	if _, err := verify.ParseAdmins(marshal(t, a)); err == nil {
		t.Fatal("a key id that isn't its hash")
	}
	// A name with a right-to-left override, which a screen would show reordered.
	a.Administrators = []verify.Administrator{{Name: "Ann‮a", Keys: []verify.Key{c.anna.ListKey()}}}
	if _, err := verify.ParseAdmins(marshal(t, a)); err == nil {
		t.Fatal("a name with U+202E")
	}
}

func state(t *testing.T, c *company, serial int64) verify.State {
	t.Helper()
	return verify.State{Format: 1, Type: "state", SignedAt: now, Company: c.id(), Serial: serial,
		Server: "https://wm.example.com", Release: strings.Repeat("ab", 32),
		Computers: []verify.Computer{{ID: strings.Repeat("cd", 32), Name: "OFFICE-03", Groups: []string{"office"}}},
		Files:     map[string]string{"groups/office/choco-reqs.txt": strings.Repeat("ef", 32)},
		Version:   verify.Version{Name: "v1.0.0", Files: map[string]string{"Provision.ps1": strings.Repeat("01", 32)}},
		Secrets:   map[string]string{"wifi-office": strings.Repeat("23", 32)},
	}
}

func TestState(t *testing.T) {
	c := newCompany(t)
	ch, err := verify.VerifyChain(c.fingerprint(), c.lists)
	if err != nil {
		t.Fatal(err)
	}
	s := sign(t, c.anna, marshal(t, state(t, c, 42)))
	if st, err := ch.VerifyState(s, 41); err != nil || st.Serial != 42 {
		t.Fatalf("a good state: %v", err)
	}
	if _, err := ch.VerifyState(s, 42); !errors.Is(err, verify.ErrStatement) {
		t.Fatalf("a state not newer than the last: %v", err)
	}
	other := newCompany(t)
	// The same administrator's key signs for two companies: a statement of one is refused by the other.
	st := state(t, other, 50)
	if _, err := ch.VerifyState(sign(t, c.anna, marshal(t, st)), 0); !errors.Is(err, verify.ErrStatement) {
		t.Fatalf("a state of another company: %v", err)
	}
	if _, err := ch.VerifyState(sign(t, newKey(t, verify.ES256), marshal(t, state(t, c, 43))), 0); !errors.Is(err, verify.ErrSignature) {
		t.Fatalf("a state signed by a stranger: %v", err)
	}
	// A state with a changed byte after signing.
	changed := sign(t, c.anna, marshal(t, state(t, c, 44)))
	changed.Statement = []byte(strings.Replace(string(changed.Statement), "OFFICE-03", "OFFICE-04", 1))
	if _, err := ch.VerifyState(changed, 0); !errors.Is(err, verify.ErrSignature) {
		t.Fatalf("a changed state: %v", err)
	}
	for name, mod := range map[string]func(*verify.State){
		"an http server":        func(s *verify.State) { s.Server = "http://wm.example.com" },
		"a server with a path":  func(s *verify.State) { s.Server = "https://wm.example.com/x" },
		"a path out with ..":    func(s *verify.State) { s.Files = map[string]string{"groups/../x": strings.Repeat("ef", 32)} },
		"an absolute path":      func(s *verify.State) { s.Files = map[string]string{"/etc/x": strings.Repeat("ef", 32)} },
		"a hash in upper case":  func(s *verify.State) { s.Release = strings.Repeat("AB", 32) },
		"a computer twice":      func(s *verify.State) { s.Computers = append(s.Computers, s.Computers[0]) },
		"a name with a newline": func(s *verify.State) { s.Computers[0].Name = "OFFICE\n03" },
		"a bad group":           func(s *verify.State) { s.Computers[0].Groups = []string{"../x"} },
		"serial 0":              func(s *verify.State) { s.Serial = 0 },
		"a secret's bad hash":   func(s *verify.State) { s.Secrets = map[string]string{"x": "00"} },
	} {
		t.Run(name, func(t *testing.T) {
			s := state(t, c, 45)
			mod(&s)
			if _, err := verify.ParseState(marshal(t, s)); !errors.Is(err, verify.ErrStatement) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	// An admin list given where a state is expected.
	if _, err := ch.VerifyState(c.lists[0], 0); !errors.Is(err, verify.ErrStatement) {
		t.Fatalf("an admin list as a state: %v", err)
	}
}

func TestJobStopSession(t *testing.T) {
	c := newCompany(t)
	ch, _ := verify.VerifyChain(c.fingerprint(), c.lists)
	job := func() verify.Job {
		return verify.Job{Format: 1, Type: "job", SignedAt: now, Company: c.id(), ID: nonce(),
			Computers: []string{strings.Repeat("cd", 32)}, Script: strings.Repeat("ef", 32), RunAs: "system",
			StartAfter: now, Expires: now.Add(24 * time.Hour), Limit: 600}
	}
	if _, err := ch.VerifyJob(sign(t, c.anna, marshal(t, job())), ch.AdminKeys()); err != nil {
		t.Fatalf("a good job: %v", err)
	}
	for name, mod := range map[string]func(*verify.Job){
		"valid for 8 days":     func(j *verify.Job) { j.Expires = now.Add(8 * 24 * time.Hour) },
		"expired before start": func(j *verify.Job) { j.StartAfter = now.Add(2 * time.Hour); j.Expires = now.Add(time.Hour) },
		"run as admin":         func(j *verify.Job) { j.RunAs = "admin" },
		"a computer twice":     func(j *verify.Job) { j.Computers = append(j.Computers, j.Computers[0]) },
		"no computers":         func(j *verify.Job) { j.Computers = nil },
		"a short id":           func(j *verify.Job) { j.ID = "abcd" },
		"no limit":             func(j *verify.Job) { j.Limit = 0 },
	} {
		t.Run("job/"+name, func(t *testing.T) {
			j := job()
			mod(&j)
			if _, err := verify.ParseJob(marshal(t, j)); !errors.Is(err, verify.ErrStatement) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	stop := verify.Stop{Format: 1, Type: "stop", SignedAt: now, Company: c.id(), Job: nonce(),
		Computers: []string{strings.Repeat("cd", 32)}}
	if _, err := ch.VerifyStop(sign(t, c.anna, marshal(t, stop)), ch.AdminKeys()); err != nil {
		t.Fatalf("a good stop: %v", err)
	}
	session := func() verify.Session {
		return verify.Session{Format: 1, Type: "session", SignedAt: now, Company: c.id(), ID: nonce(),
			Computer: strings.Repeat("cd", 32), Person: "Anna", ViewerKey: []byte{1, 2, 3},
			May: []string{"screen", "keyboard"}, OpenBy: now.Add(5 * time.Minute), MaxLength: 3600}
	}
	if _, err := ch.VerifySession(sign(t, c.anna, marshal(t, session())), ch.AdminKeys()); err != nil {
		t.Fatalf("a good session: %v", err)
	}
	for name, mod := range map[string]func(*verify.Session){
		"open by in an hour": func(s *verify.Session) { s.OpenBy = now.Add(time.Hour) },
		"may everything":     func(s *verify.Session) { s.May = []string{"root"} },
		"a day long":         func(s *verify.Session) { s.MaxLength = 86400 },
	} {
		t.Run("session/"+name, func(t *testing.T) {
			s := session()
			mod(&s)
			if _, err := verify.ParseSession(marshal(t, s)); !errors.Is(err, verify.ErrStatement) {
				t.Fatalf("accepted: %v", err)
			}
		})
	}
	// A job signed by a key the caller doesn't allow (e.g. a person without the right).
	if _, err := ch.VerifyJob(sign(t, c.anna, marshal(t, job())), map[string]verify.PublicKey{}); !errors.Is(err, verify.ErrSignature) {
		t.Fatalf("a job by a key not allowed: %v", err)
	}
}

func TestFingerprint(t *testing.T) {
	var h [32]byte
	copy(h[:], []byte{0x7f, 0x3a, 0x91, 0xc2})
	fp := verify.Fingerprint(h)
	if !strings.HasPrefix(fp, "7F3A-91C2-0000") || len(fp) != 39 {
		t.Fatalf("fingerprint %s", fp)
	}
	if !verify.MatchesFingerprint(h, strings.ToLower(strings.ReplaceAll(fp, "-", " "))) {
		t.Fatal("typed with spaces in lower case")
	}
	if verify.MatchesFingerprint(h, fp[:30]) {
		t.Fatal("a shortened fingerprint matches")
	}
}
