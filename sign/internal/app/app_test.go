package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json/v2"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/servertest"
	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/sign/internal/fido/fidotest"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

// person is one administrator's wmanager-sign: their own folder, security key and clock.
type person struct {
	t       *testing.T
	srv     *servertest.Server
	account string
	home    *home.Home
	dev     *fidotest.Device
	skew    time.Duration
	secrets []string
	out     bytes.Buffer
	// rewrite, when set, changes the server's answers to GET .../chain: a server that lies.
	rewrite func(lists []verify.Signed) []verify.Signed
}

func newPerson(t *testing.T, srv *servertest.Server, account string) *person {
	return &person{t: t, srv: srv, account: account, home: &home.Home{Dir: t.TempDir()}, dev: &fidotest.Device{}}
}

type lying struct {
	p    *person
	next http.RoundTripper
}

func (l lying) RoundTrip(r *http.Request) (*http.Response, error) {
	resp, err := l.next.RoundTrip(r)
	if err != nil || l.p.rewrite == nil || r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/chain") {
		return resp, err
	}
	defer resp.Body.Close()
	var ch struct {
		Lists []verify.Signed `json:"lists"`
	}
	if err := json.UnmarshalRead(resp.Body, &ch); err != nil {
		return nil, err
	}
	ch.Lists = l.p.rewrite(ch.Lists)
	b, _ := json.Marshal(ch)
	resp.Body = io.NopCloser(bytes.NewReader(b))
	resp.ContentLength = int64(len(b))
	resp.Header.Del("Content-Length")
	return resp, nil
}

// run runs a command with the lines typed in; it returns what was shown and the error.
func (p *person) run(input string, args ...string) (string, error) {
	p.t.Helper()
	p.out.Reset()
	a := &App{
		Home: p.home,
		In:   bufio.NewReader(strings.NewReader(input)),
		Out:  &p.out,
		ReadSecret: func(prompt string) (string, error) {
			if len(p.secrets) == 0 {
				return "", errors.New("no secret to type")
			}
			s := p.secrets[0]
			p.secrets = p.secrets[1:]
			return s, nil
		},
		OpenDevice: func() (fido.Device, error) { return p.dev, nil },
		HTTP:       &http.Client{Transport: lying{p, p.srv.Client.Transport}},
		Now:        func() time.Time { return p.srv.Now().Add(p.skew) },
		Lang:       "en",
	}
	err := a.Run(context.Background(), args)
	if testing.Verbose() {
		p.t.Logf("$ wmanager-sign %s\n%s(err: %v)", strings.Join(args, " "), p.out.String(), err)
	}
	return p.out.String(), err
}

func (p *person) must(input string, args ...string) string {
	p.t.Helper()
	out, err := p.run(input, args...)
	if err != nil {
		p.t.Fatalf("%v: %v\n%s", args, err, out)
	}
	return out
}

func (p *person) connect() {
	p.t.Helper()
	p.secrets = append(p.secrets, p.srv.SignCode(p.account))
	p.must("", "connect", p.srv.URL)
}

var fpRe = regexp.MustCompile(`[0-9A-F]{4}(-[0-9A-F]{4}){7}`)

// newKey makes and registers a key; it returns the key's fingerprint as shown.
func (p *person) newKey() string {
	p.t.Helper()
	out := p.must("", "key", "new")
	fp := fpRe.FindString(out)
	if fp == "" {
		p.t.Fatalf("no fingerprint shown: %s", out)
	}
	return fp
}

func (p *person) heldLists(company string) int {
	p.t.Helper()
	s, err := p.home.Server(p.srv.URL)
	if err != nil {
		p.t.Fatal(err)
	}
	h, _, err := s.Company(company)
	if err != nil {
		p.t.Fatal(err)
	}
	if h == nil {
		return 0
	}
	return len(h.Chain)
}

// setup is a company with two administrators, Anna and Bob, connected, each with a key; Anna made the first list
// and Bob took the chain.
type world struct {
	srv       *servertest.Server
	company   string
	anna, bob *person
	annaKey   string
	bobKey    string
	fp        string
}

func setup(t *testing.T) *world {
	srv := servertest.New(t)
	w := &world{srv: srv, company: srv.Company("Acme")}
	w.anna = newPerson(t, srv, srv.Person("anna@example.com", w.company, "admin"))
	w.bob = newPerson(t, srv, srv.Person("bob@example.com", w.company, "admin"))
	w.anna.connect()
	w.bob.connect()
	w.annaKey, w.bobKey = w.anna.newKey(), w.bob.newKey()
	out := w.anna.must("Anna\nyes\n", "company", "init", "Acme")
	w.fp = fpRe.FindString(out[strings.Index(out, "is set up"):])
	if w.fp == "" || !strings.Contains(out, "only one key") {
		t.Fatalf("company init: %s", out)
	}
	if out := w.bob.must(w.fp+"\n", "company", "trust", "Acme"); !strings.Contains(out, "checks against the fingerprint") {
		t.Fatalf("trust: %s", out)
	}
	return w
}

func TestAdminChain(t *testing.T) {
	w := setup(t)
	if w.anna.dev.Touches != 3 { // the key, its proof, the first list
		t.Errorf("Anna touched her key %d times", w.anna.dev.Touches)
	}

	// Anna adds Bob, typing his key's fingerprint as he reads it out.
	out := w.anna.must("Bob\n"+strings.ToLower(w.bobKey)+"\nyes\n", "admins", "add", "Acme")
	if !strings.Contains(out, "+ Bob: "+w.bobKey) || !strings.Contains(out, "Admin list 2 of Acme is signed") {
		t.Fatalf("admins add: %s", out)
	}
	// Bob sees the new list and what it changed, signed by Anna.
	out = w.bob.must("", "")
	if !strings.Contains(out, "New admin list 2, signed by Anna") || !strings.Contains(out, "+ Bob: "+w.bobKey) ||
		!strings.Contains(out, "Acme (admin): "+w.fp+", admin list 2") {
		t.Fatalf("status: %s", out)
	}
	// Bob, now an administrator, removes Anna; his key signs, though the credential id is only on his computer.
	out = w.bob.must("1\nyes\n", "admins", "remove", "Acme")
	if !strings.Contains(out, "- Anna: "+w.annaKey) || !strings.Contains(out, "Admin list 3 of Acme is signed") {
		t.Fatalf("admins remove: %s", out)
	}
	// Anna's key no longer signs for Acme.
	if out, err := w.anna.run("Carol\n"+w.annaKey+"\nyes\n", "admins", "add", "Acme"); err == nil ||
		!strings.Contains(err.Error(), "not an administrator") && !strings.Contains(err.Error(), "may sign") &&
			!strings.Contains(err.Error(), "in the list already") {
		t.Fatalf("Anna after her removal: %v\n%s", err, out)
	}
	if out := w.anna.must("", "fingerprint", "Acme"); !strings.Contains(out, w.fp) {
		t.Fatalf("fingerprint: %s", out)
	}
	if n := w.anna.heldLists(w.company); n != 3 {
		t.Fatalf("Anna holds %d lists", n)
	}
}

func TestTrustRefusesAnotherFingerprint(t *testing.T) {
	w := setup(t)
	carol := newPerson(t, w.srv, w.srv.Person("carol@example.com", w.company, "person"))
	carol.connect()
	wrong := strings.Replace(w.fp, w.fp[:4], "0000", 1)
	if wrong == w.fp {
		wrong = strings.Replace(w.fp, w.fp[:4], "1111", 1)
	}
	if _, err := carol.run(wrong+"\n", "company", "trust", "Acme"); err == nil || !strings.Contains(err.Error(), "doesn't match the fingerprint") {
		t.Fatalf("a wrong fingerprint: %v", err)
	}
	if carol.heldLists(w.company) != 0 {
		t.Fatal("a chain was kept against a wrong fingerprint")
	}
	if _, err := carol.run("", "admins", "Acme"); err == nil || !strings.Contains(err.Error(), "don't hold the chain") {
		t.Fatalf("a company not taken: %v", err)
	}
}

func TestServerThatLies(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "") // Bob holds two lists

	// A server that shows an older chain (one that still has a key removed since): kept as held, and nothing signed
	// on it.
	w.bob.rewrite = func(l []verify.Signed) []verify.Signed { return l[:1] }
	out := w.bob.must("", "admins", "Acme")
	if !strings.Contains(out, "it is behind") || !strings.Contains(out, "Admin list 2 of Acme") {
		t.Fatalf("an older chain: %s", out)
	}
	if w.bob.heldLists(w.company) != 2 {
		t.Fatal("an older chain replaced the held one")
	}

	// A server that shows another list 2, signed by Anna's key: an alarm, and nothing kept.
	annaKey := w.anna.dev.Key(verify.KeyID(mustCOSE(t, w.anna)))
	w.bob.rewrite = func(l []verify.Signed) []verify.Signed {
		var a verify.Admins
		if err := json.Unmarshal(l[1].Statement, &a); err != nil {
			t.Fatal(err)
		}
		a.Administrators = a.Administrators[:1] // Anna only
		raw, _ := verify.Marshal(a)
		s, err := annaKey.SignStatement(raw, softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		return []verify.Signed{l[0], s}
	}
	if _, err := w.bob.run("", ""); !errors.Is(err, verify.ErrForkedChain) || !strings.Contains(err.Error(), "ALARM") {
		t.Fatalf("a forked chain: %v", err)
	}
	if _, err := w.bob.run("1\nyes\n", "admins", "remove", "Acme"); !errors.Is(err, verify.ErrForkedChain) {
		t.Fatalf("signing on a forked chain: %v", err)
	}
	w.bob.rewrite = nil
	if w.bob.heldLists(w.company) != 2 {
		t.Fatal("a forked chain replaced the held one")
	}

	// A server restored from an older backup gets the lists it lost back from an administrator who holds them.
	w.srv.ForgetLists(w.company, 1)
	out = w.bob.must("", "")
	if !strings.Contains(out, "it is behind") || !strings.Contains(out, "Gave the server the admin lists it lacked (1)") {
		t.Fatalf("pushing to a server behind: %s", out)
	}
	if out := w.anna.must("", ""); !strings.Contains(out, "admin list 2") || strings.Contains(out, "behind") {
		t.Fatalf("after the push: %s", out)
	}
}

func TestRefusals(t *testing.T) {
	w := setup(t)

	// A clock more than 10 minutes off the server's: nothing signed.
	w.anna.skew = 11 * time.Minute
	if _, err := w.anna.run("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme"); err == nil || !strings.Contains(err.Error(), "off the server's") {
		t.Fatalf("a wrong clock: %v", err)
	}
	w.anna.skew = 0

	// A fingerprint that matches no registered key (a server that put its own key in Bob's place looks like this).
	other := strings.Replace(w.bobKey, w.bobKey[:4], "0000", 1)
	if other == w.bobKey {
		other = strings.Replace(w.bobKey, w.bobKey[:4], "1111", 1)
	}
	if _, err := w.anna.run("Bob\n"+other+"\nyes\n", "admins", "add", "Acme"); err == nil || !strings.Contains(err.Error(), "No key with that fingerprint") {
		t.Fatalf("a fingerprint of no key: %v", err)
	}
	// A name with a bidirectional override is refused before anything is shown as signable.
	if _, err := w.anna.run("Bob‮\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme"); err == nil || !strings.Contains(err.Error(), "isn't valid") {
		t.Fatalf("a name with an override: %v", err)
	}
	// Not typing yes signs nothing.
	if out := w.anna.must("Bob\n"+w.bobKey+"\nno\n", "admins", "add", "Acme"); !strings.Contains(out, "Nothing was signed") {
		t.Fatalf("no: %s", out)
	}
	if n := w.anna.heldLists(w.company); n != 1 {
		t.Fatalf("%d lists after the refusals", n)
	}

	// A synced passkey is refused at registration.
	carol := newPerson(t, w.srv, w.srv.Person("carol@example.com", w.company, "person"))
	carol.connect()
	carol.dev.SyncedCredentials = true
	if _, err := carol.run("", "key", "new"); err == nil || !strings.Contains(err.Error(), "synced passkey") {
		t.Fatalf("a synced passkey: %v", err)
	}
	// A member can't make or change the list.
	carol.dev.SyncedCredentials = false
	carol.newKey()
	carol.must(w.fp+"\n", "company", "trust", "Acme")
	if _, err := carol.run("1\nyes\n", "admins", "remove", "Acme"); err == nil || !strings.Contains(err.Error(), "not an administrator") {
		t.Fatalf("a member: %v", err)
	}
	other2 := w.srv.Company("Other")
	w.srv.Join(carol.account, other2, "person")
	if _, err := carol.run("Carol\nyes\n", "company", "init", "Other"); err == nil || !strings.Contains(err.Error(), "not an administrator") {
		t.Fatalf("a member's init: %v", err)
	}

	// A wrong PIN.
	w.anna.dev.PIN = "1234"
	w.anna.secrets = []string{"9999"}
	if _, err := w.anna.run("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme"); !errors.Is(err, fido.ErrPIN) {
		t.Fatalf("a wrong PIN: %v", err)
	}
	w.anna.secrets = []string{"1234"}
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")

	// A token that has ended asks for a new code.
	w.srv.Advance(13 * time.Hour)
	if _, err := w.anna.run("", ""); err == nil || !strings.Contains(err.Error(), "has ended") {
		t.Fatalf("an ended token: %v", err)
	}
}

func TestOneRunAtATime(t *testing.T) {
	srv := servertest.New(t)
	p := newPerson(t, srv, srv.Owner)
	if err := p.home.Init(); err != nil {
		t.Fatal(err)
	}
	unlock, err := p.home.Lock()
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		if _, err := p.run("", ""); err == nil || !strings.Contains(err.Error(), "Another wmanager-sign") {
			t.Errorf("a second run: %v", err)
		}
	}()
	wg.Wait()
}

func mustCOSE(t *testing.T, p *person) []byte {
	t.Helper()
	s, err := p.home.Server(p.srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	ks, err := s.Keys()
	if err != nil || len(ks) == 0 {
		t.Fatalf("no key made: %v", err)
	}
	return ks[0].COSE
}
