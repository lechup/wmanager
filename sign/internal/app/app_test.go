package app

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
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
	"github.com/lechup/wmanager/sign/internal/api"
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
	// A server that lies: rewrite changes its answers to GET .../chain (the path given), rewriteMe its list of
	// companies, and alias lists a company under another id (alias[0] for alias[1]).
	rewrite   func(lists []verify.Signed) []verify.Signed
	rewriteMe func(me *api.Me)
	alias     [2]string
	// lose loses the server's answers to POSTs, after the server has them; drop loses the POSTs themselves.
	lose, drop bool
}

func newPerson(t *testing.T, srv *servertest.Server, account string) *person {
	return &person{t: t, srv: srv, account: account, home: &home.Home{Dir: t.TempDir()}, dev: &fidotest.Device{}}
}

type lying struct {
	p    *person
	next http.RoundTripper
}

func (l lying) RoundTrip(r *http.Request) (*http.Response, error) {
	if l.p.alias[0] != "" && strings.Contains(r.URL.Path, l.p.alias[0]) {
		r = r.Clone(r.Context())
		r.URL.Path = strings.Replace(r.URL.Path, l.p.alias[0], l.p.alias[1], 1)
	}
	if l.p.drop && r.Method == http.MethodPost {
		return nil, errors.New("no route to host (the test's)")
	}
	resp, err := l.next.RoundTrip(r)
	if err == nil && l.p.lose && r.Method == http.MethodPost {
		resp.Body.Close()
		return nil, errors.New("connection reset (the test's)")
	}
	if err != nil || r.Method != http.MethodGet {
		return resp, err
	}
	var out any
	switch {
	case l.p.rewrite != nil && strings.HasSuffix(r.URL.Path, "/chain"):
		var ch struct {
			Lists []verify.Signed `json:"lists"`
		}
		if err := json.UnmarshalRead(resp.Body, &ch); err != nil {
			return nil, err
		}
		ch.Lists = l.p.rewrite(ch.Lists)
		out = ch
	case strings.HasSuffix(r.URL.Path, "/me") && (l.p.rewriteMe != nil || l.p.alias[0] != ""):
		var me api.Me
		if err := json.UnmarshalRead(resp.Body, &me); err != nil {
			return nil, err
		}
		for i := range me.Companies {
			if me.Companies[i].ID == l.p.alias[1] {
				me.Companies[i].ID = l.p.alias[0]
			}
		}
		if l.p.rewriteMe != nil {
			l.p.rewriteMe(&me)
		}
		out = me
	default:
		return resp, nil
	}
	resp.Body.Close()
	b, _ := json.Marshal(out)
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
	h, _, err := p.home.ByServer(p.srv.URL, company)
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

// A server that lists a company again under a new id, with an older chain (one that still has a key removed
// since), meets the chain held: it is found by the company's own id, and the older chain isn't taken.
func TestServerRelabelsACompany(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	w.bob.must("1\nyes\n", "admins", "remove", "Acme") // list 3: Anna removed
	fresh := "11111111-2222-4333-8444-555555555555"
	w.bob.alias = [2]string{fresh, w.company}
	w.bob.rewrite = func(l []verify.Signed) []verify.Signed { return l[:2] }
	if _, err := w.bob.run("", "admins", "Acme"); err == nil || !strings.Contains(err.Error(), "doesn't list Acme") {
		t.Fatalf("a held company the server lists no more: %v", err)
	}
	out := w.bob.must(w.fp+"\n", "company", "trust", fresh)
	if !strings.Contains(out, "it is behind") || !strings.Contains(out, "under another id") || !strings.Contains(out, "hold the chain of Acme already") {
		t.Fatalf("trust of a relabelled company: %s", out)
	}
	out = w.bob.must("", "admins", "Acme")
	if !strings.Contains(out, "Admin list 3 of Acme") || strings.Contains(out, "  Anna:") {
		t.Fatalf("the older chain came back: %s", out)
	}

	// Another chain under the id the server gave the company before is an alarm.
	w.bob.alias, w.bob.rewrite = [2]string{}, nil
	w.bob.must("", "") // back under its real id
	k, _ := softkey.New(verify.ES256)
	fake := firstListOf(t, k)
	w.bob.rewrite = func(l []verify.Signed) []verify.Signed { return []verify.Signed{fake} }
	if _, err := w.bob.run("", ""); !errors.Is(err, verify.ErrForkedChain) || !strings.Contains(err.Error(), "another chain") {
		t.Fatalf("another chain for the company: %v", err)
	}
}

func firstListOf(t *testing.T, k *softkey.Key) verify.Signed {
	t.Helper()
	raw, _ := verify.Marshal(verify.Admins{Format: 1, Type: "admins", SignedAt: time.Now().UTC().Truncate(time.Second),
		Nonce: strings.Repeat("ef", 16), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Mallory", Keys: []verify.Key{k.ListKey()}}}})
	s, err := k.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// The security key signs on a computer where none of its keys were made: every key on it signs, and the one in the
// list is found by its signature. A security key with none of the list's keys signs nothing.
func TestAnotherComputer(t *testing.T) {
	w := setup(t)
	laptop := newPerson(t, w.srv, w.anna.account)
	laptop.dev = w.anna.dev
	laptop.connect()
	laptop.must(w.fp+"\n", "company", "trust", "Acme")
	if out := laptop.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme"); !strings.Contains(out, "Admin list 2 of Acme is signed") ||
		!strings.Contains(out, "None of the keys made here") {
		t.Fatalf("signing from another computer: %s", out)
	}
	if _, err := laptop.run("", "company", "init", "Acme"); err == nil || !strings.Contains(err.Error(), "admin list already") {
		t.Fatalf("init of a company with a list: %v", err)
	}
	w.anna.dev.Forget()
	if _, err := w.anna.run("1\nyes\n", "admins", "remove", "Acme"); err == nil || !strings.Contains(err.Error(), "holds no key") {
		t.Fatalf("a security key reset: %v", err)
	}
}

func TestMoreRefusals(t *testing.T) {
	w := setup(t)
	// A newer list the server shows that doesn't check is not taken.
	stranger, _ := softkey.New(verify.ES256)
	w.bob.rewrite = func(l []verify.Signed) []verify.Signed {
		h := l[0].Hash()
		raw, _ := verify.Marshal(verify.Admins{Format: 1, Type: "admins", SignedAt: time.Now().UTC().Truncate(time.Second),
			Company: hex.EncodeToString(h[:]), Sequence: 2, Previous: hex.EncodeToString(h[:]),
			Administrators: []verify.Administrator{{Name: "Mallory", Keys: []verify.Key{stranger.ListKey()}}}})
		s, _ := stranger.SignStatement(raw, softkey.Options{})
		return append(l, s)
	}
	if out, err := w.bob.run("", "admins", "Acme"); err == nil || !strings.Contains(err.Error(), "don't check") {
		t.Fatalf("a list that doesn't check: %v\n%s", err, out)
	}
	w.bob.rewrite = nil
	if n := w.bob.heldLists(w.company); n != 1 {
		t.Fatalf("%d lists held", n)
	}

	// What the server says is shown visibly: a company's name with an escape sequence.
	other := w.srv.Company("Other")
	w.srv.Join(w.bob.account, other, "admin")
	w.bob.rewriteMe = func(m *api.Me) {
		for i := range m.Companies {
			if m.Companies[i].ID == other {
				m.Companies[i].Name = "Oth\x1b[2Jer\u202e"
			}
		}
	}
	if out := w.bob.must("", ""); !strings.Contains(out, "Oth<U+001B>[2Jer<U+202E>") || strings.ContainsRune(out, 0x1b) {
		t.Fatalf("a name with an escape: %q", out)
	}
	w.bob.rewriteMe = nil

	// The last key of an administrator, and the last administrator, can't be removed.
	if _, err := w.anna.run("1\nyes\n", "admins", "remove-key", "Acme"); err == nil || !strings.Contains(err.Error(), "only key of Anna") {
		t.Fatalf("the last key: %v", err)
	}
	if _, err := w.anna.run("1\nyes\n", "admins", "remove", "Acme"); err == nil || !strings.Contains(err.Error(), "only administrator") {
		t.Fatalf("the last administrator: %v", err)
	}
	// An empty PIN.
	w.anna.dev.PIN = "1234"
	w.anna.secrets = []string{""}
	if _, err := w.anna.run("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme"); err == nil || !strings.Contains(err.Error(), "No PIN") {
		t.Fatalf("an empty PIN: %v", err)
	}
}

// The first list's answer lost on the way: the fingerprint is shown and kept all the same.
func TestFirstListAnswerLost(t *testing.T) {
	srv := servertest.New(t)
	company := srv.Company("Acme")
	anna := newPerson(t, srv, srv.Person("anna@example.com", company, "admin"))
	anna.connect()
	anna.newKey()
	anna.lose = true
	out := anna.must("Anna\nyes\n", "company", "init", "Acme")
	fp := fpRe.FindString(out[strings.Index(out, "is set up"):])
	if fp == "" || !strings.Contains(out, "answer didn't come") {
		t.Fatalf("init with the answer lost: %s", out)
	}
	anna.lose = false
	if out := anna.must("", "fingerprint", "Acme"); !strings.Contains(out, fp) {
		t.Fatalf("after: %s", out)
	}

	// The list that never reached the server reaches it the next time.
	beta := srv.Company("Beta")
	srv.Join(anna.account, beta, "admin")
	anna.drop = true
	anna.must("Anna\nyes\n", "company", "init", "Beta")
	anna.drop = false
	if out := anna.must("", ""); !strings.Contains(out, "it is behind") || !strings.Contains(out, "lists it lacked (1)") {
		t.Fatalf("after the list was lost: %s", out)
	}
	if out := anna.must("", ""); strings.Contains(out, "behind") || !strings.Contains(out, "Beta (admin)") {
		t.Fatalf("the server has it: %s", out)
	}
}
