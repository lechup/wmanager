package web

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

const pw = "a long enough password"

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.t = c.t.Add(d); c.mu.Unlock() }

type env struct {
	t     *testing.T
	srv   *httptest.Server
	clock *clock
	owner string
	panel *Server
}

func (b *browser) cookie() string {
	u, _ := url.Parse(b.e.srv.URL)
	for _, c := range b.c.Jar.Cookies(u) {
		if c.Name == CookieName {
			return c.Value
		}
	}
	return ""
}

func setup(t *testing.T) *env {
	t.Helper()
	s := storetest.New(t)
	owner, err := accounts.CreateAccount(context.Background(), s, accounts.SystemActor, "owner@example.com", "Owner", pw, true)
	if err != nil {
		t.Fatal(err)
	}
	c := &clock{t: time.Now()}
	a := auth.New(s)
	a.Now = c.now
	a.Log = slog.New(slog.DiscardHandler)
	panel, err := New(s, a, slog.New(slog.NewTextHandler(testWriter{t}, &slog.HandlerOptions{Level: slog.LevelError})))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewTLSServer(panel.Handler())
	t.Cleanup(srv.Close)
	return &env{t: t, srv: srv, clock: c, owner: owner, panel: panel}
}

// browser is one person's browser: its own cookies.
type browser struct {
	e    *env
	c    *http.Client
	last string // the last page's body
}

func (e *env) browser() *browser {
	jar, _ := cookiejar.New(nil)
	// A client of its own: the test server's Client() is one shared client, and its jar would be shared too.
	c := &http.Client{Transport: e.srv.Client().Transport, Jar: jar}
	return &browser{e: e, c: c}
}

func (b *browser) do(req *http.Request) (int, string) {
	b.e.t.Helper()
	resp, err := b.c.Do(req)
	if err != nil {
		b.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	b.last = string(body)
	return resp.StatusCode, b.last
}

func (b *browser) get(path string, header ...string) (int, string) {
	req, _ := http.NewRequest(http.MethodGet, b.e.srv.URL+path, nil)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	return b.do(req)
}

var csrfRe = regexp.MustCompile(`name="csrf" value="([^"]+)"`)

// post sends a form, with the CSRF token of the last page unless the form has one.
func (b *browser) post(path string, form url.Values, header ...string) (int, string) {
	if form == nil {
		form = url.Values{}
	}
	if _, ok := form["csrf"]; !ok {
		if m := csrfRe.FindStringSubmatch(b.last); m != nil {
			form.Set("csrf", m[1])
		}
	}
	req, _ := http.NewRequest(http.MethodPost, b.e.srv.URL+path, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	return b.do(req)
}

func totpNow(t *testing.T, secretGroups string, at time.Time) string {
	t.Helper()
	secret, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ReplaceAll(secretGroups, " ", ""))
	if err != nil {
		t.Fatal(err)
	}
	m := hmac.New(sha1.New, secret)
	binary.Write(m, binary.BigEndian, uint64(at.Unix()/30))
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	return fmt.Sprintf("%06d", (binary.BigEndian.Uint32(sum[off:off+4])&0x7fffffff)%1000000)
}

var secretRe = regexp.MustCompile(`<code class="secret">([A-Z2-7 ]+)</code>`)

// enroll signs in for the first time with the password and sets up TOTP; it returns the secret.
func (b *browser) enroll(email string) string {
	t := b.e.t
	t.Helper()
	if code, _ := b.get("/signin"); code != http.StatusOK {
		t.Fatalf("GET /signin: %d", code)
	}
	if code, body := b.post("/signin", url.Values{"email": {email}, "password": {pw}}); code != http.StatusOK ||
		!strings.Contains(body, `class="qr"`) {
		t.Fatalf("after the password: %d, no QR code", code)
	}
	return b.confirmTOTP()
}

func (b *browser) confirmTOTP() string {
	t := b.e.t
	t.Helper()
	m := secretRe.FindStringSubmatch(b.last)
	if m == nil {
		t.Fatalf("no secret on the page: %s", b.last)
	}
	code, body := b.post("/signin/totp", url.Values{"code": {totpNow(t, m[1], b.e.clock.now())}})
	if code != http.StatusOK || strings.Count(body, "<li><code>") != 10 {
		t.Fatalf("confirming TOTP: %d, %d recovery codes", code, strings.Count(body, "<li><code>"))
	}
	return m[1]
}

var linkRe = regexp.MustCompile(`/setup/([A-Za-z0-9_-]+)</code>`)
var optionRe = regexp.MustCompile(`<option value="([0-9a-f-]{36})">([^<]+)</option>`)

func (b *browser) idOf(label string) string {
	b.e.t.Helper()
	for _, m := range optionRe.FindAllStringSubmatch(b.last, -1) {
		if m[2] == label {
			return m[1]
		}
	}
	b.e.t.Fatalf("no option %q on the page", label)
	return ""
}

func TestHeadersAndSignIn(t *testing.T) {
	e := setup(t)
	b := e.browser()
	resp, err := b.c.Get(e.srv.URL + "/signin")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	for h, want := range map[string]string{
		"Content-Security-Policy": "default-src 'none'",
		"X-Frame-Options":         "DENY",
		"X-Content-Type-Options":  "nosniff",
		"Referrer-Policy":         "no-referrer",
		"Cache-Control":           "no-store",
	} {
		if got := resp.Header.Get(h); !strings.Contains(got, want) {
			t.Errorf("%s: %q", h, got)
		}
	}
	if code, body := b.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {"wrong password here"}}); code != http.StatusUnauthorized ||
		!strings.Contains(body, "Wrong e-mail address or password.") {
		t.Fatalf("a wrong password: %d", code)
	}
	b.enroll("owner@example.com")
	u, _ := url.Parse(e.srv.URL)
	for _, c := range b.c.Jar.Cookies(u) {
		if c.Name == CookieName {
			goto found
		}
	}
	t.Fatal("no session cookie")
found:
	if code, body := b.get("/"); code != http.StatusOK || !strings.Contains(body, "belong to any company yet.") {
		t.Fatalf("home: %d", code)
	}
	// A second sign-in, later, with a code from the app.
	if code, _ := b.post("/signout", nil); code != http.StatusOK {
		t.Fatalf("sign out: %d", code)
	}
	if code, _ := b.get("/"); code != http.StatusOK || !strings.Contains(b.last, `action="/signin"`) {
		t.Fatal("not sent to the sign-in after signing out")
	}
}

func TestInviteAndCompanies(t *testing.T) {
	e := setup(t)
	owner := e.browser()
	owner.enroll("owner@example.com")

	if code, _ := owner.get("/admin"); code != http.StatusOK {
		t.Fatalf("admin: %d", code)
	}
	if code, _ := owner.post("/admin/company", url.Values{"name": {"Acme"}}); code != http.StatusOK {
		t.Fatalf("new company: %d", code)
	}
	invite := func(email string) string {
		code, body := owner.post("/admin/invite", url.Values{"email": {email}, "name": {"Anna"}})
		m := linkRe.FindStringSubmatch(body)
		if code != http.StatusOK || m == nil {
			t.Fatalf("invite %s: %d, no link", email, code)
		}
		return m[1]
	}
	link := invite("anna@example.com")
	outsiderLink := invite("bob@example.com")
	owner.get("/admin")
	acme, anna := owner.idOf("Acme"), owner.idOf("anna@example.com")
	if code, _ := owner.post("/admin/member", url.Values{"company": {acme}, "account": {anna}, "role": {"admin"}}); code != http.StatusOK {
		t.Fatalf("add member: %d", code)
	}
	if code, _ := owner.post("/admin/member", url.Values{"company": {"not-an-id"}, "account": {anna}, "role": {"admin"}}); code != http.StatusBadRequest {
		t.Fatalf("a bad company id: %d", code)
	}

	// Anna opens her link, sets her password and second factor.
	a := e.browser()
	if code, body := a.get("/setup/" + link); code != http.StatusOK || !strings.Contains(body, "anna@example.com") {
		t.Fatalf("setup page: %d", code)
	}
	if code, body := a.post("/setup/"+link, url.Values{"password": {pw}, "again": {pw + "x"}}); code != http.StatusBadRequest ||
		!strings.Contains(body, "The two passwords differ.") {
		t.Fatalf("different passwords: %d", code)
	}
	if code, _ := a.post("/setup/"+link, url.Values{"password": {"short"}, "again": {"short"}}); code != http.StatusBadRequest {
		t.Fatalf("a short password: %d", code)
	}
	if code, body := a.post("/setup/"+link, url.Values{"password": {pw}, "again": {pw}}); code != http.StatusOK || !strings.Contains(body, `class="qr"`) {
		t.Fatalf("setting the password: %d", code)
	}
	a.confirmTOTP()
	if code, _ := e.browser().get("/setup/" + link); code != http.StatusNotFound {
		t.Fatalf("the link used a second time: %d", code)
	}
	if code, body := a.get("/"); code != http.StatusOK || !strings.Contains(body, "/c/"+acme) {
		t.Fatalf("Anna's home: %d\n%s", code, body)
	}
	if code, body := a.get("/c/" + acme); code != http.StatusOK || !strings.Contains(body, "The chain is whole: 2 entries") ||
		!strings.Contains(body, "anna@example.com") {
		t.Fatalf("Anna's company: %d", code)
	}
	resp, err := a.c.Get(e.srv.URL + "/c/" + acme + "/audit.json")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(resp.Header.Get("Content-Disposition"), "attachment") || strings.Count(string(body), "\n") != 2 {
		t.Fatalf("export: %q, %d lines", resp.Header.Get("Content-Disposition"), strings.Count(string(body), "\n"))
	}
	if code, _ := a.get("/admin"); code != http.StatusNotFound {
		t.Fatalf("the owner's page for an administrator of a company: %d", code)
	}

	// Bob is in no company: Acme doesn't exist for him; nor for the owner of the server, who isn't in it.
	bob := e.browser()
	bob.get("/setup/" + outsiderLink)
	bob.post("/setup/"+outsiderLink, url.Values{"password": {pw}, "again": {pw}})
	bob.confirmTOTP()
	for name, br := range map[string]*browser{"an outsider": bob, "the owner": owner} {
		for _, p := range []string{"/c/" + acme, "/c/" + acme + "/audit.csv"} {
			if code, _ := br.get(p); code != http.StatusNotFound {
				t.Errorf("%s: %s: %d", name, p, code)
			}
		}
	}
}

func TestFormsNeedTheirToken(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.enroll("owner@example.com")
	b.get("/admin")
	for name, c := range map[string]struct {
		form   url.Values
		header []string
	}{
		"no token":          {url.Values{"name": {"X"}, "csrf": {""}}, nil},
		"a wrong token":     {url.Values{"name": {"X"}, "csrf": {"AAAA"}}, nil},
		"from another site": {url.Values{"name": {"X"}}, []string{"Sec-Fetch-Site", "cross-site"}},
		"another origin":    {url.Values{"name": {"X"}}, []string{"Origin", "https://evil.example"}},
	} {
		if code, _ := b.post("/admin/company", c.form, c.header...); code != http.StatusForbidden {
			t.Errorf("%s: %d", name, code)
		}
	}
	if code, body := b.get("/admin"); code != http.StatusOK || strings.Contains(body, ">X <") {
		t.Fatal("a company was made by a refused form")
	}
	// The sign-in form from another site is refused too.
	if code, _ := e.browser().post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}},
		"Sec-Fetch-Site", "cross-site"); code != http.StatusForbidden {
		t.Errorf("sign-in from another site: %d", code)
	}
}

func TestNotSignedIn(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	for _, p := range []string{"/", "/admin", "/c/00000000-0000-0000-0000-000000000000", "/signin/code", "/signin/totp"} {
		if code, _ := b.get(p); code != http.StatusSeeOther {
			t.Errorf("%s: %d, want a redirect to /signin", p, code)
		}
	}
	if code, _ := b.post("/admin/company", url.Values{"name": {"X"}}); code != http.StatusForbidden {
		t.Errorf("a form without a session: %d", code)
	}
	if code, _ := b.get("/setup/nope"); code != http.StatusNotFound {
		t.Errorf("an unknown setup link: %d", code)
	}
}

func TestLanguages(t *testing.T) {
	e := setup(t)
	b := e.browser()
	if _, body := b.get("/signin?lang=pl"); !strings.Contains(body, "Logowanie") || !strings.Contains(body, `lang="pl"`) {
		t.Fatal("?lang=pl")
	}
	if _, body := b.get("/signin"); !strings.Contains(body, "Logowanie") {
		t.Fatal("the language isn't kept")
	}
	if _, body := e.browser().get("/signin", "Accept-Language", "de-AT,de;q=0.9,en;q=0.5"); !strings.Contains(body, "Anmelden") {
		t.Fatal("Accept-Language de")
	}
	if _, body := e.browser().get("/signin", "Accept-Language", "ja"); !strings.Contains(body, "Sign in") {
		t.Fatal("an unknown language falls back to English")
	}
}

var placeholder = regexp.MustCompile(`%[sdv]`)
var templateKey = regexp.MustCompile(`\{\{t "([a-z.]+)"`)

// Every language has every message, with the same placeholders, and every message a template uses exists.
func TestCatalogs(t *testing.T) {
	en := catalogs["en"]
	for _, l := range languages {
		m := catalogs[l]
		for k, v := range en {
			got, ok := m[k]
			if !ok || strings.TrimSpace(got) == "" {
				t.Errorf("%s: %s missing", l, k)
				continue
			}
			if a, b := placeholder.FindAllString(v, -1), placeholder.FindAllString(got, -1); strings.Join(a, "") != strings.Join(b, "") {
				t.Errorf("%s: %s has placeholders %v, English %v", l, k, b, a)
			}
		}
		for k := range m {
			if _, ok := en[k]; !ok {
				t.Errorf("%s: %s is not in English", l, k)
			}
		}
	}
	names, _ := fs.Glob(files, "templates/*.html")
	for _, n := range names {
		b, _ := fs.ReadFile(files, n)
		for _, m := range templateKey.FindAllStringSubmatch(string(b), -1) {
			if _, ok := en[m[1]]; !ok {
				t.Errorf("%s uses %s, which has no message", n, m[1])
			}
		}
	}
	for _, k := range []string{"role.admin", "role.person", "error.signin", "error.code", "error.locked", "error.toomany",
		"error.setup", "error.weak", "error.session", "error.notfound", "error.forbidden", "error.internal",
		"error.exists", "error.badinput", "password.mismatch", "totp.again"} {
		if _, ok := en[k]; !ok {
			t.Errorf("%s, used by the code, has no message", k)
		}
	}
}

func TestClientAddr(t *testing.T) {
	s := &Server{TrustedProxies: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}}
	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.RemoteAddr = "10.1.2.3:4444"
	r.Header.Set("X-Forwarded-For", "203.0.113.9, 198.51.100.7")
	if got := s.clientAddr(r); got != "198.51.100.7" {
		t.Errorf("behind a trusted proxy: %s", got)
	}
	r.RemoteAddr = "192.0.2.1:4444"
	if got := s.clientAddr(r); got != "192.0.2.1" {
		t.Errorf("an untrusted peer's X-Forwarded-For was believed: %s", got)
	}
}

// testWriter sends the panel's errors to the test's log.
type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) {
	w.t.Log(strings.TrimSpace(string(p)))
	return len(p), nil
}
