package web

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	jsonv2 "encoding/json/v2"
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
	"github.com/lechup/wmanager/server/internal/auth/authtest"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/computers"
	"github.com/lechup/wmanager/server/internal/signapi"
	"github.com/lechup/wmanager/server/internal/statements"
	"github.com/lechup/wmanager/server/internal/store/storetest"
	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
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
	logs  *safeBuffer
}

type safeBuffer struct {
	mu sync.Mutex
	b  strings.Builder
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}
func (b *safeBuffer) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.b.String() }

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
	logs := &safeBuffer{}
	t.Cleanup(func() {
		if t.Failed() {
			t.Log(logs.String())
		}
	})
	panel, err := New(s, a, slog.New(slog.NewTextHandler(logs, nil)))
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewTLSServer(panel.Handler())
	t.Cleanup(srv.Close)
	return &env{t: t, srv: srv, clock: c, owner: owner, panel: panel, logs: logs}
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
		"Content-Security-Policy":   "default-src 'none'",
		"X-Frame-Options":           "DENY",
		"X-Content-Type-Options":    "nosniff",
		"Referrer-Policy":           "no-referrer",
		"Cache-Control":             "no-store",
		"Strict-Transport-Security": "max-age=31536000",
	} {
		if got := resp.Header.Get(h); !strings.Contains(got, want) {
			t.Errorf("%s: %q", h, got)
		}
	}
	if code, body := b.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {"wrong password here"}}); code != http.StatusUnauthorized ||
		!strings.Contains(body, "Wrong e-mail address or password.") {
		t.Fatalf("a wrong password: %d", code)
	}
	// The session cookie's attributes, as sent.
	noFollow := &http.Client{Transport: b.c.Transport, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	form := url.Values{"email": {"owner@example.com"}, "password": {pw}}
	resp, err = noFollow.PostForm(e.srv.URL+"/signin", form)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	sc := resp.Header.Get("Set-Cookie")
	for _, want := range []string{CookieName + "=", "Path=/", "HttpOnly", "Secure", "SameSite=Strict"} {
		if !strings.Contains(sc, want) {
			t.Errorf("Set-Cookie %q lacks %s", sc, want)
		}
	}
	if strings.Contains(sc, "Domain=") {
		t.Errorf("Set-Cookie %q has a Domain", sc)
	}

	secret := b.enroll("owner@example.com")
	if code, body := b.get("/"); code != http.StatusOK || !strings.Contains(body, "belong to any company yet.") {
		t.Fatalf("home: %d", code)
	}
	if code, _ := b.post("/signout", nil); code != http.StatusOK {
		t.Fatalf("sign out: %d", code)
	}
	if code, _ := b.get("/"); code != http.StatusOK || !strings.Contains(b.last, `action="/signin"`) {
		t.Fatal("not sent to the sign-in after signing out")
	}
	// A second sign-in, later, with a code from the app.
	e.clock.add(time.Minute)
	if code, body := b.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}}); code != http.StatusOK ||
		!strings.Contains(body, `action="/signin/code"`) {
		t.Fatalf("the password at a second sign-in: %d", code)
	}
	if code, _ := b.post("/signin/code", url.Values{"code": {"000000"}}); code != http.StatusUnauthorized {
		t.Fatalf("a wrong code: %d", code)
	}
	b.get("/signin/code")
	if code, body := b.post("/signin/code", url.Values{"code": {totpNow(t, secret, e.clock.now())}}); code != http.StatusOK ||
		!strings.Contains(body, "belong to any company yet.") {
		t.Fatalf("the code at a second sign-in: %d", code)
	}
}

func TestWrongFirstCodeKeepsTheSecret(t *testing.T) {
	e := setup(t)
	b := e.browser()
	b.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}})
	first := secretRe.FindStringSubmatch(b.last)[1]
	b.get("/signin/totp") // a reload
	if again := secretRe.FindStringSubmatch(b.last)[1]; again != first {
		t.Fatal("a reload offered another secret")
	}
	if code, body := b.post("/signin/totp", url.Values{"code": {"000000"}}); code != http.StatusUnauthorized ||
		secretRe.FindStringSubmatch(body)[1] != first || strings.Contains(body, "<footer>") {
		t.Fatalf("a wrong first code: %d, or another secret, or language links on the page", code)
	}
	b.confirmTOTP()
	if strings.Contains(b.last, "<footer>") {
		t.Fatal("language links on the page of the recovery codes")
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
	if code, body := owner.post("/admin/invite", url.Values{"email": {"eve@example.com"}, "name": {"<script>alert(1)</script>"}}); code != http.StatusOK ||
		strings.Contains(body, "<script>alert") || !strings.Contains(body, "&lt;script&gt;alert(1)&lt;/script&gt;") {
		t.Fatalf("a name with markup: %d, not escaped", code)
	}
	// Before using the link, the account has no password: signing in fails like a wrong one.
	if code, _ := e.browser().post("/signin", url.Values{"email": {"anna@example.com"}, "password": {pw}}); code != http.StatusUnauthorized {
		t.Fatalf("signing in before the setup: %d", code)
	}
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
		t.Fatalf("the link opened a second time: %d", code)
	}
	if code, _ := e.browser().post("/setup/"+link, url.Values{"password": {pw}, "again": {pw}}); code != http.StatusNotFound {
		t.Fatalf("the link used a second time: %d", code)
	}
	if strings.Contains(e.logs.String(), link) {
		t.Fatal("a setup token in the server's log")
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
		b.get("/admin") // a page with the token, so a case without one leaves it out on purpose
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
		"error.exists", "error.badinput", "error.lockedsetup", "error.notpending", "password.mismatch"} {
		if _, ok := en[k]; !ok {
			t.Errorf("%s, used by the code, has no message", k)
		}
	}
}

// testWriter sends the panel's errors to the test's log.
type testWriter struct{ t *testing.T }

func (w testWriter) Write(p []byte) (int, error) {
	w.t.Log(strings.TrimSpace(string(p)))
	return len(p), nil
}

func TestExpiredLinkAndNewLink(t *testing.T) {
	e := setup(t)
	owner := e.browser()
	secret := owner.enroll("owner@example.com")
	owner.get("/admin") // the page of the recovery codes has no form, so no token
	_, body := owner.post("/admin/invite", url.Values{"email": {"carl@example.com"}})
	old := linkRe.FindStringSubmatch(body)[1]
	if !strings.Contains(body, "link works until") {
		t.Fatal("the link's expiry isn't shown")
	}
	e.clock.add(auth.SetupLinkValid + time.Hour)
	if code, _ := e.browser().get("/setup/" + old); code != http.StatusNotFound {
		t.Fatalf("an expired link: %d", code)
	}
	// The owner's session ended meanwhile (idle): sign in again, with a code from the app.
	owner.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}})
	if code, _ := owner.post("/signin/code", url.Values{"code": {totpNow(t, secret, e.clock.now())}}); code != http.StatusOK {
		t.Fatalf("signing in again: %d", code)
	}
	owner.get("/admin")
	code, body := owner.post("/admin/link", url.Values{"account": {owner.idOf("carl@example.com")}})
	m := linkRe.FindStringSubmatch(body)
	if code != http.StatusOK || m == nil || m[1] == old {
		t.Fatalf("a new link: %d", code)
	}
	if code, _ := e.browser().get("/setup/" + m[1]); code != http.StatusOK {
		t.Fatalf("the new link: %d", code)
	}
	owner.get("/admin")
	if code, _ := owner.post("/admin/link", url.Values{"account": {owner.idOf("owner@example.com")}}); code != http.StatusConflict {
		t.Fatalf("a new link for an account set up already: %d", code)
	}
}

func TestClientAddrWalksProxies(t *testing.T) {
	s := &Server{TrustedProxies: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("2001:db8::1/128")}}
	cases := []struct {
		peer string
		xff  []string
		want string
	}{
		{"10.1.2.3:1", []string{"203.0.113.9, 198.51.100.7"}, "198.51.100.7"},
		{"10.1.2.3:1", []string{"6.6.6.6", "198.51.100.7"}, "198.51.100.7"}, // a second header line is read too
		{"10.1.2.3:1", []string{"198.51.100.7, 10.9.9.9"}, "198.51.100.7"},  // past a second trusted proxy
		{"10.1.2.3:1", []string{"198.51.100.7, not-an-ip"}, "10.1.2.3"},     // a bad entry stops at the proxy
		{"10.1.2.3:1", nil, "10.1.2.3"},
		{"192.0.2.1:1", []string{"198.51.100.7"}, "192.0.2.1"}, // not a trusted peer: its header is ignored
		{"[2001:db8::1]:1", []string{"2001:db8:5::9"}, "2001:db8:5::9"},
		{"[::ffff:10.1.2.3]:1", []string{"198.51.100.7"}, "198.51.100.7"},
	}
	for _, c := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = c.peer
		for _, v := range c.xff {
			r.Header.Add("X-Forwarded-For", v)
		}
		if got := s.clientAddr(r); got != c.want {
			t.Errorf("%s %q: %s, want %s", c.peer, c.xff, got, c.want)
		}
	}
	if redact("//setup/secret-token") != "//setup/…" || redact("/setup/x") != "/setup/…" {
		t.Error("redact")
	}
}

// postJSON sends a passkey request with the CSRF token of the last page, or a given one.
func (b *browser) postJSON(path, csrfToken string, body []byte) (int, []byte) {
	b.e.t.Helper()
	if csrfToken == "" {
		if m := regexp.MustCompile(`data-csrf="([^"]+)"`).FindStringSubmatch(b.last); m != nil {
			csrfToken = m[1]
		}
	}
	if body == nil {
		body = []byte("{}")
	}
	req, _ := http.NewRequest(http.MethodPost, b.e.srv.URL+path, strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	if csrfToken != "-" {
		req.Header.Set("X-CSRF-Token", csrfToken)
	}
	resp, err := b.c.Do(req)
	if err != nil {
		b.e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func TestPasskeyInThePanel(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL = "https://localhost" // the relying party: browsers refuse an IP address as its id
	b := e.browser()
	secret := b.enroll("owner@example.com")
	pk := authtest.NewPasskey("localhost", "https://localhost")

	code, body := b.get("/account")
	if code != http.StatusOK || !strings.Contains(body, `src="/static/passkey.js"`) || !strings.Contains(body, "Add a passkey") {
		t.Fatalf("account page: %d", code)
	}
	if code, _ := b.postJSON("/account/passkey/begin", "-", nil); code != http.StatusForbidden {
		t.Fatalf("begin without the CSRF header: %d", code)
	}
	code, opts := b.postJSON("/account/passkey/begin", "", nil)
	if code != http.StatusOK {
		t.Fatalf("begin: %d %s", code, opts)
	}
	answer, err := pk.Register(opts)
	if err != nil {
		t.Fatal(err)
	}
	if code, out := b.postJSON("/account/passkey/finish?name=YubiKey", "", answer); code != http.StatusOK ||
		!strings.Contains(string(out), `"redirect":"/account"`) {
		t.Fatalf("finish: %d %s", code, out)
	}
	if _, body := b.get("/account"); !strings.Contains(body, "<td>YubiKey") {
		t.Fatal("the passkey isn't listed")
	}

	// Signing in again: the code page offers the passkey; the passkey makes the session full.
	b.post("/signout", nil)
	e.clock.add(time.Minute)
	if _, body := b.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}}); !strings.Contains(body, "Use a passkey") {
		t.Fatal("the code page doesn't offer the passkey")
	}
	code, opts = b.postJSON("/signin/passkey/begin", "", nil)
	if code != http.StatusOK {
		t.Fatalf("sign-in begin: %d", code)
	}
	wrong, _ := authtest.NewPasskey("localhost", "https://localhost").Assert(opts)
	if code, _ := b.postJSON("/signin/passkey/finish", "", wrong); code != http.StatusBadRequest {
		t.Fatalf("another key: %d", code)
	}
	b.get("/signin/code")
	_, opts = b.postJSON("/signin/passkey/begin", "", nil)
	answer, _ = pk.Assert(opts)
	if code, out := b.postJSON("/signin/passkey/finish", "", answer); code != http.StatusOK || !strings.Contains(string(out), `"redirect":"/"`) {
		t.Fatalf("sign-in finish: %d %s", code, out)
	}
	if code, body := b.get("/"); code != http.StatusOK || !strings.Contains(body, "belong to any company yet.") {
		t.Fatalf("home after the passkey: %d", code)
	}
	_ = secret

	// Removing it.
	b.get("/account")
	id := regexp.MustCompile(`name="id" value="([^"]+)"`).FindStringSubmatch(b.last)
	if id == nil {
		t.Fatal("no remove form")
	}
	if code, _ := b.post("/account/passkey/remove", url.Values{"id": {id[1]}}); code != http.StatusOK {
		t.Fatalf("remove: %d", code)
	}
	if _, body := b.get("/account"); strings.Contains(body, "<td>YubiKey") {
		t.Fatal("the passkey is still listed")
	}
	resp, err := b.c.Get(e.srv.URL + "/static/passkey.js")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Fatalf("passkey.js served as %q", ct)
	}
}

func TestPasskeysNeedThePublicURL(t *testing.T) {
	e := setup(t) // PublicURL unset: the relying party would come from a Host header, so there are no passkeys
	b := e.browser()
	b.enroll("owner@example.com")
	if _, body := b.get("/account"); strings.Contains(body, `data-passkey="register"`) || !strings.Contains(body, "WMANAGER_PUBLIC_URL") {
		t.Fatal("the account page offers passkeys without the panel's address")
	}
	tok := csrfRe.FindStringSubmatch(b.last)[1] // from the sign-out form: the page has no passkey button
	if code, out := b.postJSON("/account/passkey/begin", tok, nil); code != http.StatusNotFound || !strings.Contains(string(out), "unavailable") {
		t.Fatalf("begin without the panel's address: %d %s", code, out)
	}
}

func TestPasskeyJSONAfterTheSessionEnds(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL = "https://localhost"
	b := e.browser()
	b.enroll("owner@example.com")
	b.get("/account")
	e.clock.add(auth.SessionIdle + time.Hour)
	if code, out := b.postJSON("/account/passkey/begin", "", nil); code != http.StatusUnauthorized || !strings.Contains(string(out), "signin") {
		t.Fatalf("a JSON request after the session ended: %d %s", code, out)
	}
}

// api calls the sign API with a token (or none).
func (e *env) api(method, path, tok string, body any) (int, []byte) {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, err := jsonv2.Marshal(body)
		if err != nil {
			e.t.Fatal(err)
		}
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+"/api/sign/v1/"+path, rdr)
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	resp, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

var signCodeRe = regexp.MustCompile(`<code class="secret">([A-Z2-9]{5}-[A-Z2-9]{5})</code>`)

// signIn connects wmanager-sign for a browser that is signed in: a code from the account page, exchanged.
func (b *browser) signIn() (tok, account string) {
	t := b.e.t
	t.Helper()
	b.get("/account")
	_, body := b.post("/account/sign-code", nil)
	m := signCodeRe.FindStringSubmatch(body)
	if m == nil {
		t.Fatalf("no code on the account page: %s", body)
	}
	code, out := b.e.api("POST", "login", "", map[string]string{"code": strings.ToLower(m[1])})
	var login struct {
		Token   string `json:"token"`
		Account string `json:"account"`
	}
	if code != http.StatusOK || jsonv2.Unmarshal(out, &login) != nil || login.Token == "" {
		t.Fatalf("login: %d %s", code, out)
	}
	return login.Token, login.Account
}

// registerKey registers a software key for the account, with its proof.
func (e *env) registerKey(tok, account string, k *softkey.Key) (int, []byte) {
	e.t.Helper()
	proof, err := k.SignStatement(verify.MakeKeyProof(e.panel.PublicURL, account, e.clock.now()), softkey.Options{})
	if err != nil {
		e.t.Fatal(err)
	}
	return e.api("POST", "keys", tok, map[string]any{"cose": k.COSEKey(), "proof": proof})
}

// person makes an account, signs it in in a browser of its own, and puts it into the company with the role.
func (e *env) person(owner *browser, email, company, role string) *browser {
	e.t.Helper()
	id, err := accounts.CreateAccount(context.Background(), e.panel.Store, accounts.SystemActor, email, "Person", pw, false)
	if err != nil {
		e.t.Fatal(err)
	}
	if company != "" {
		owner.get("/admin")
		if code, _ := owner.post("/admin/member", url.Values{"company": {company}, "account": {id}, "role": {role}}); code != http.StatusOK {
			e.t.Fatalf("add %s: %d", email, code)
		}
	}
	b := e.browser()
	b.enroll(email)
	return b
}

func firstList(t *testing.T, k *softkey.Key, at time.Time) verify.Signed {
	t.Helper()
	l := verify.Admins{Format: 1, Type: "admins", SignedAt: at, Nonce: strings.Repeat("ab", 16), Sequence: 1,
		Administrators: []verify.Administrator{{Name: "Owner", Keys: []verify.Key{k.ListKey()}}}}
	raw, _ := verify.Marshal(l)
	s, err := k.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func nextList(t *testing.T, prev verify.Signed, seq int64, by *softkey.Key, at time.Time, admins ...*softkey.Key) verify.Signed {
	t.Helper()
	h := prev.Hash()
	var ks []verify.Key
	for _, a := range admins {
		ks = append(ks, a.ListKey())
	}
	var company string
	if seq == 2 {
		company = hex.EncodeToString(h[:])
	} else {
		var p verify.Admins
		if err := jsonv2.Unmarshal(prev.Statement, &p); err != nil {
			t.Fatal(err)
		}
		company = p.Company
	}
	l := verify.Admins{Format: 1, Type: "admins", SignedAt: at, Company: company, Sequence: seq,
		Previous: hex.EncodeToString(h[:]), Administrators: []verify.Administrator{{Name: "Owner", Keys: ks}}}
	raw, _ := verify.Marshal(l)
	s, err := by.SignStatement(raw, softkey.Options{})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSignAPI(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL = "https://wm.example.com"
	owner := e.browser()
	owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	acme, me := owner.idOf("Acme"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})

	tok, account := owner.signIn()
	if account != me {
		t.Fatalf("login names account %s, not %s", account, me)
	}
	if code, out := e.api("GET", "me", tok, nil); code != http.StatusOK || !strings.Contains(string(out), `"name":"Acme"`) ||
		strings.Contains(string(out), "fingerprint") || !strings.Contains(string(out), me) {
		t.Fatalf("me: %d %s", code, out)
	}

	// A key registered, the first admin list signed with it, then a second.
	anna, _ := softkey.New(verify.ES256)
	if code, out := e.registerKey(tok, account, anna); code != http.StatusOK || !strings.Contains(string(out), anna.ID()) {
		t.Fatalf("register a key: %d %s", code, out)
	}
	if code, _ := e.registerKey(tok, account, anna); code != http.StatusOK {
		t.Fatalf("the same key again: %d", code)
	}
	if code, out := e.api("GET", "companies/"+acme+"/keys", tok, nil); code != http.StatusOK || strings.Count(string(out), anna.ID()) != 1 {
		t.Fatalf("the company's keys: %d %s", code, out)
	}
	now := e.clock.now().UTC()
	s1 := firstList(t, anna, now)
	code, out := e.api("POST", "companies/"+acme+"/chain", tok, s1)
	if code != http.StatusOK || !strings.Contains(string(out), verify.Fingerprint(s1.Hash())) {
		t.Fatalf("the first list: %d %s", code, out)
	}
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, s1); code != http.StatusConflict {
		t.Fatalf("the first list again: %d", code)
	}
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, firstList(t, anna, now.Add(time.Second))); code != http.StatusConflict {
		t.Fatalf("a second first list: %d", code)
	}
	stranger, _ := softkey.New(verify.ES256)
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, nextList(t, s1, 2, stranger, now, anna)); code != http.StatusConflict {
		t.Fatalf("a list signed by a stranger: %d", code)
	}
	s2 := nextList(t, s1, 2, anna, now, anna)
	if code, out := e.api("POST", "companies/"+acme+"/chain", tok, s2); code != http.StatusOK || !strings.Contains(string(out), `"sequence":2`) {
		t.Fatalf("the second list: %d %s", code, out)
	}
	var chain struct {
		Lists []verify.Signed `json:"lists"`
	}
	code, out = e.api("GET", "companies/"+acme+"/chain", tok, nil)
	if code != http.StatusOK || jsonv2.Unmarshal(out, &chain) != nil || len(chain.Lists) != 2 {
		t.Fatalf("the chain: %d %s", code, out)
	}
	if _, err := verify.VerifyChain(verify.Fingerprint(s1.Hash()), chain.Lists); err != nil {
		t.Fatalf("the chain as handed out: %v", err)
	}
	if code, out := e.api("GET", "me", tok, nil); code != http.StatusOK || !strings.Contains(string(out), verify.Fingerprint(s1.Hash())) {
		t.Fatalf("me after the first list: %d %s", code, out)
	}
	_, body := owner.get("/c/" + acme)
	if !strings.Contains(body, verify.Fingerprint(s1.Hash())) || !strings.Contains(body, "Admin list number 2") ||
		!strings.Contains(body, "admins.signed") {
		t.Fatal("the company page doesn't show the chain and its audit entries")
	}
	if code, _ := e.api("GET", "time", "", nil); code != http.StatusOK {
		t.Fatalf("time: %d", code)
	}

	// The same chain under a second company is refused.
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Other"}})
	other := owner.idOf("Other")
	owner.post("/admin/member", url.Values{"company": {other}, "account": {me}, "role": {"admin"}})
	if code, _ := e.api("POST", "companies/"+other+"/chain", tok, s1); code != http.StatusConflict {
		t.Fatalf("Acme's first list for another company: %d", code)
	}

	// A list changed by hand in the database shows on the company page.
	db := storetest.Superuser(t, e.panel.Store)
	bad := s2
	bad.Signature = append([]byte{}, s2.Signature...)
	bad.Signature[len(bad.Signature)-1] ^= 1
	raw, _ := jsonv2.Marshal(bad)
	if _, err := db.Exec(context.Background(), `UPDATE admin_lists SET signed = $1 WHERE sequence = 2`, raw); err != nil {
		t.Fatal(err)
	}
	if _, body := owner.get("/c/" + acme); !strings.Contains(body, "The stored admin lists don&#39;t check") {
		t.Fatal("a broken stored chain doesn't show")
	}
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, nextList(t, s2, 3, anna, now, anna)); code != http.StatusConflict {
		t.Fatalf("a list over a broken stored chain: %d", code)
	}

	// Disconnected from the panel: the token stops working, and so does a code still waiting.
	owner.get("/account")
	_, body = owner.post("/account/sign-code", nil)
	waiting := signCodeRe.FindStringSubmatch(body)
	owner.post("/account/sign-revoke", nil)
	if code, _ := e.api("GET", "me", tok, nil); code != http.StatusUnauthorized {
		t.Fatalf("a token after disconnecting: %d", code)
	}
	if code, _ := e.api("POST", "login", "", map[string]string{"code": waiting[1]}); code != http.StatusUnauthorized {
		t.Fatalf("a code made before disconnecting: %d", code)
	}
}

func TestSignAPIRefusals(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL = "https://wm.example.com"
	owner := e.browser()
	secret := owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	acme, me := owner.idOf("Acme"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})
	tok, account := owner.signIn()
	anna, _ := softkey.New(verify.ES256)
	e.registerKey(tok, account, anna)
	s1 := firstList(t, anna, e.clock.now().UTC())
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, s1); code != http.StatusOK {
		t.Fatalf("the first list: %d", code)
	}

	// A person (not an administrator) and an outsider.
	person := e.person(owner, "person@example.com", acme, "person")
	ptok, paccount := person.signIn()
	outsider := e.person(owner, "outsider@example.com", "", "")
	otok, _ := outsider.signIn()
	s2 := nextList(t, s1, 2, anna, e.clock.now().UTC(), anna)
	for _, c := range []struct {
		name, method, path, tok string
		body                    any
		want                    int
	}{
		{"a person appends", "POST", "companies/" + acme + "/chain", ptok, s2, http.StatusForbidden},
		{"a person lists the keys", "GET", "companies/" + acme + "/keys", ptok, nil, http.StatusForbidden},
		{"an outsider reads the chain", "GET", "companies/" + acme + "/chain", otok, nil, http.StatusForbidden},
		{"an outsider appends", "POST", "companies/" + acme + "/chain", otok, s2, http.StatusForbidden},
		{"an outsider lists the keys", "GET", "companies/" + acme + "/keys", otok, nil, http.StatusForbidden},
		{"a company that doesn't exist", "GET", "companies/00000000-0000-0000-0000-000000000000/chain", tok, nil, http.StatusForbidden},
		{"an id that isn't one", "GET", "companies/not-an-id/chain", tok, nil, http.StatusNotFound},
		{"a call that doesn't exist", "GET", "nothing", tok, nil, http.StatusNotFound},
		{"no token", "GET", "me", "", nil, http.StatusUnauthorized},
		{"a wrong token", "GET", "me", "nope", nil, http.StatusUnauthorized},
		{"an unknown member", "POST", "keys", tok, map[string]string{"other": "x"}, http.StatusBadRequest},
		{"a key without a proof", "POST", "keys", tok, map[string][]byte{"cose": anna.COSEKey()}, http.StatusBadRequest},
	} {
		code, out := e.api(c.method, c.path, c.tok, c.body)
		if code != c.want || !strings.HasPrefix(string(out), `{"error":`) {
			t.Errorf("%s: %d %s, want %d and JSON", c.name, code, out, c.want)
		}
	}
	if code, _ := e.api("GET", "companies/"+acme+"/chain", ptok, nil); code != http.StatusOK {
		t.Errorf("a person reads the chain: %d", code)
	}

	// Keys: a proof for another server, for another account, a key someone else registered, the cap.
	elsewhere, _ := anna.SignStatement(verify.MakeKeyProof("https://other.example.com", account, e.clock.now()), softkey.Options{})
	if code, _ := e.api("POST", "keys", tok, map[string]any{"cose": anna.COSEKey(), "proof": elsewhere}); code != http.StatusBadRequest {
		t.Errorf("a proof made for another server: %d", code)
	}
	url0 := e.panel.PublicURL
	e.panel.PublicURL = ""
	if code, _ := e.registerKey(tok, account, anna); code != http.StatusServiceUnavailable {
		t.Errorf("a key without WMANAGER_PUBLIC_URL: %d", code)
	}
	e.panel.PublicURL = url0
	proof, _ := anna.SignStatement(verify.MakeKeyProof(e.panel.PublicURL, account, e.clock.now()), softkey.Options{})
	if code, _ := e.api("POST", "keys", ptok, map[string]any{"cose": anna.COSEKey(), "proof": proof}); code != http.StatusBadRequest {
		t.Errorf("the owner's proof sent by a person: %d", code)
	}
	if code, _ := e.registerKey(ptok, paccount, anna); code != http.StatusConflict {
		t.Errorf("a key registered by another account: %d", code)
	}
	for i := 1; i < chains.MaxKeys; i++ {
		k, _ := softkey.New(verify.EdDSA)
		if code, _ := e.registerKey(tok, account, k); code != http.StatusOK {
			t.Fatalf("key %d: %d", i+1, code)
		}
	}
	k, _ := softkey.New(verify.EdDSA)
	if code, _ := e.registerKey(tok, account, k); code != http.StatusConflict {
		t.Errorf("a key over the cap: %d", code)
	}

	// A code needs a fresh second factor, works for 5 minutes, and gives a token for 12 hours.
	e.clock.add(auth.FreshFor + time.Minute)
	owner.get("/account")
	if _, body := owner.post("/account/sign-code", nil); signCodeRe.MatchString(body) || !strings.Contains(body, "sign in again") {
		t.Error("a code for a session whose second factor is old")
	}
	late := e.browser()
	late.get("/signin")
	late.post("/signin", url.Values{"email": {"owner@example.com"}, "password": {pw}})
	if code, _ := late.post("/signin/code", url.Values{"code": {totpNow(t, secret, e.clock.now())}}); code != http.StatusOK {
		t.Fatalf("signing in again: %d", code)
	}
	late.get("/account")
	_, body := late.post("/account/sign-code", nil)
	m := signCodeRe.FindStringSubmatch(body)
	if m == nil {
		t.Fatal("no code after signing in again")
	}
	e.clock.add(auth.SignCodeLife + time.Second)
	if code, _ := e.api("POST", "login", "", map[string]string{"code": m[1]}); code != http.StatusUnauthorized {
		t.Errorf("an expired code: %d", code)
	}
	e.clock.add(auth.SignTokenLife - auth.SignCodeLife - auth.FreshFor)
	if code, _ := e.api("GET", "me", tok, nil); code != http.StatusUnauthorized {
		t.Errorf("an expired token: %d", code)
	}

	// A disabled account: its token stops working (it worked just before).
	e.clock.add(-time.Hour) // back within the person's token
	if code, _ := e.api("GET", "me", ptok, nil); code != http.StatusOK {
		t.Fatalf("the person's token before disabling: %d", code)
	}
	db := storetest.Superuser(t, e.panel.Store)
	if _, err := db.Exec(context.Background(), `UPDATE accounts SET disabled = true WHERE email = 'person@example.com'`); err != nil {
		t.Fatal(err)
	}
	if code, _ := e.api("GET", "me", ptok, nil); code != http.StatusUnauthorized {
		t.Errorf("a disabled account's token: %d", code)
	}

	// Guessing: the limit per address answers 429.
	var last int
	for range auth.PerAddress + 1 {
		last, _ = e.api("POST", "login", "", map[string]string{"code": "AAAAA-AAAAA"})
	}
	if last != http.StatusTooManyRequests {
		t.Errorf("guessing codes: %d", last)
	}
}

func TestStatesAPI(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL = "https://wm.example.com"
	owner := e.browser()
	owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	acme, me := owner.idOf("Acme"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})
	tok, account := owner.signIn()
	anna, _ := softkey.New(verify.ES256)
	e.registerKey(tok, account, anna)
	s1 := firstList(t, anna, e.clock.now().UTC())
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, s1); code != http.StatusOK {
		t.Fatalf("the first list: %d", code)
	}
	ctx := context.Background()
	script := []byte("Write-Output 'hello'\n")
	h, err := statements.PutFile(ctx, e.panel.Store, account, acme, script)
	if err != nil {
		t.Fatal(err)
	}
	draft, err := statements.SaveDraft(ctx, e.panel.Store, account, acme, "state", []byte(`{"files": {}}`))
	if err != nil {
		t.Fatal(err)
	}

	if code, out := e.api("GET", "companies/"+acme+"/drafts", tok, nil); code != http.StatusOK || !strings.Contains(string(out), draft) ||
		strings.Contains(string(out), `"body"`) {
		t.Fatalf("drafts: %d %s", code, out)
	}
	if code, out := e.api("GET", "companies/"+acme+"/drafts/"+draft, tok, nil); code != http.StatusOK || !strings.Contains(string(out), `"body"`) {
		t.Fatalf("a draft: %d %s", code, out)
	}
	if code, _ := e.api("GET", "companies/"+acme+"/drafts/x", tok, nil); code != http.StatusNotFound {
		t.Fatalf("a draft id that isn't one: %d", code)
	}
	var f struct {
		Content []byte `json:"content"`
	}
	code, out := e.api("GET", "companies/"+acme+"/files/"+hex.EncodeToString(h[:]), tok, nil)
	if code != http.StatusOK || jsonv2.Unmarshal(out, &f) != nil || string(f.Content) != string(script) {
		t.Fatalf("a file: %d %s", code, out)
	}
	for _, p := range []string{"files/" + strings.Repeat("0", 64), "files/xyz", "files/" + strings.ToUpper(hex.EncodeToString(h[:]))} {
		if code, _ := e.api("GET", "companies/"+acme+"/"+p, tok, nil); code != http.StatusNotFound {
			t.Errorf("GET %s: %d", p, code)
		}
	}
	if code, out := e.api("GET", "companies/"+acme+"/state", tok, nil); code != http.StatusOK || !strings.Contains(string(out), `"state":null`) {
		t.Fatalf("no state yet: %d %s", code, out)
	}

	company := hex.EncodeToString(func() []byte { x := s1.Hash(); return x[:] }())
	state := func(serial int64, server string) verify.Signed {
		raw, _ := verify.Marshal(verify.State{Format: 1, Type: "state", SignedAt: e.clock.now().UTC().Truncate(time.Second),
			Company: company, Serial: serial, Server: server, Release: strings.Repeat("ab", 32), Computers: []verify.Computer{},
			Files:   map[string]string{"groups/office/hello.ps1": hex.EncodeToString(h[:])},
			Version: verify.Version{Name: "v1.0.0", Files: map[string]string{}}, Secrets: map[string]string{}})
		s, err := anna.SignStatement(raw, softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	if code, _ := e.api("POST", "companies/"+acme+"/states", tok, map[string]any{"signed": state(1, "https://other.example.com")}); code != http.StatusConflict {
		t.Fatalf("a state for another server: %d", code)
	}
	if code, _ := e.api("POST", "companies/"+acme+"/states", tok, map[string]any{"signed": state(1, "https://wm.example.com"), "draft": "x"}); code != http.StatusNotFound {
		t.Fatalf("a draft id that isn't one: %d", code)
	}
	if code, out := e.api("POST", "companies/"+acme+"/states", tok, map[string]any{"signed": state(1, "https://wm.example.com"), "draft": draft}); code != http.StatusOK || !strings.Contains(string(out), `"serial":1`) {
		t.Fatalf("a state: %d %s", code, out)
	}
	if code, _ := e.api("POST", "companies/"+acme+"/states", tok, map[string]any{"signed": state(1, "https://wm.example.com")}); code != http.StatusConflict {
		t.Fatalf("the same serial again: %d", code)
	}
	var got struct {
		State *verify.Signed `json:"state"`
	}
	code, out = e.api("GET", "companies/"+acme+"/state", tok, nil)
	if code != http.StatusOK || jsonv2.Unmarshal(out, &got) != nil || got.State == nil {
		t.Fatalf("the state: %d %s", code, out)
	}
	ch, _ := verify.VerifyChain(verify.Fingerprint(s1.Hash()), []verify.Signed{s1})
	if _, err := ch.VerifyState(*got.State, 0); err != nil {
		t.Fatalf("the state as handed out: %v", err)
	}
	if code, out := e.api("GET", "companies/"+acme+"/drafts", tok, nil); code != http.StatusOK || strings.Contains(string(out), draft) {
		t.Fatalf("the draft after signing: %d %s", code, out)
	}

	// A person and an outsider.
	person := e.person(owner, "person@example.com", acme, "person")
	ptok, _ := person.signIn()
	outsider := e.person(owner, "outsider@example.com", "", "")
	otok, _ := outsider.signIn()
	for _, c := range []struct {
		name, method, path, tok string
		body                    any
		want                    int
	}{
		{"a person's drafts", "GET", "drafts", ptok, nil, http.StatusForbidden},
		{"a person's state", "POST", "states", ptok, map[string]any{"signed": state(2, "https://wm.example.com")}, http.StatusForbidden},
		{"an outsider's file", "GET", "files/" + hex.EncodeToString(h[:]), otok, nil, http.StatusForbidden},
		{"an outsider's state", "GET", "state", otok, nil, http.StatusForbidden},
	} {
		if code, _ := e.api(c.method, "companies/"+acme+"/"+c.path, c.tok, c.body); code != c.want {
			t.Errorf("%s: %d, want %d", c.name, code, c.want)
		}
	}
	if code, _ := e.api("GET", "companies/"+acme+"/state", ptok, nil); code != http.StatusOK {
		t.Fatalf("a person reads the state: %d", code)
	}

	// The audit entries, as stored, for wmanager-sign to link.
	var au struct {
		Entries [][]byte `json:"entries"`
	}
	code, out = e.api("GET", "companies/"+acme+"/audit?after=0", ptok, nil)
	if code != http.StatusOK || jsonv2.Unmarshal(out, &au) != nil || len(au.Entries) < 2 || !strings.Contains(string(au.Entries[0]), `"seq":1`) {
		t.Fatalf("the audit entries: %d %s", code, out)
	}
	if code, out := e.api("GET", "companies/"+acme+"/audit?after=1", ptok, nil); code != http.StatusOK || strings.Contains(string(out), `"seq":1,`) {
		t.Fatalf("the entries after 1: %d %s", code, out)
	}
	for _, q := range []string{"", "?after=-1", "?after=x"} {
		if code, _ := e.api("GET", "companies/"+acme+"/audit"+q, ptok, nil); code != http.StatusBadRequest {
			t.Errorf("audit%s: %d", q, code)
		}
	}
	if code, _ := e.api("GET", "companies/"+acme+"/audit?after=0", otok, nil); code != http.StatusForbidden {
		t.Fatalf("an outsider's audit: %d", code)
	}
}

// An upload of add-file takes longer than the server's read and write timeouts, as a large file over the internet
// does: it goes through while it keeps coming.
func TestSlowUpload(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL, e.panel.FilesDir = "https://wm.example.com", t.TempDir()
	owner := e.browser()
	owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	acme, me := owner.idOf("Acme"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})
	tok, _ := owner.signIn()

	srv := httptest.NewUnstartedServer(e.panel.Handler())
	srv.Config.ReadTimeout, srv.Config.WriteTimeout = 300*time.Millisecond, 600*time.Millisecond
	srv.StartTLS()
	defer srv.Close()
	chunk := bytes.Repeat([]byte{0x4d, 0x5a, 0, 1}, signapi.UploadPace/4)
	const chunks = 5
	whole := sha256.New()
	for range chunks {
		whole.Write(chunk)
	}
	h := hex.EncodeToString(whole.Sum(nil))
	put := func(body io.Reader, size int64) (int, string) {
		req, _ := http.NewRequest(http.MethodPut, srv.URL+"/api/sign/v1/companies/"+acme+"/files/"+h, body)
		req.ContentLength = size
		req.Header.Set("Authorization", "Bearer "+tok)
		resp, err := srv.Client().Do(req)
		if err != nil {
			return 0, err.Error()
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		return resp.StatusCode, string(b)
	}
	pr, pw := io.Pipe()
	go func() {
		for range chunks {
			time.Sleep(250 * time.Millisecond)
			pw.Write(chunk)
		}
		pw.Close()
	}()
	if code, out := put(pr, int64(chunks*len(chunk))); code != http.StatusOK {
		t.Fatalf("a slow upload: %d %s", code, out)
	}
	// The API's other answers: a wrong hash, no folder (the limits are StoreFile's own test).
	if code, _ := put(bytes.NewReader(chunk), int64(len(chunk))); code != http.StatusBadRequest {
		t.Errorf("a wrong hash: %d", code)
	}
	e.panel.FilesDir = ""
	if code, _ := put(bytes.NewReader(chunk), int64(len(chunk))); code != http.StatusServiceUnavailable {
		t.Errorf("no folder: %d", code)
	}
}

// fakeAgent is a computer with a software key, as the agent's protocol has it (docs/agent.md).
type fakeAgent struct {
	e   *env
	key *ecdsa.PrivateKey
	id  string
}

func newAgent(t *testing.T, e *env) *fakeAgent {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, _ := x509.MarshalPKIXPublicKey(&k.PublicKey)
	return &fakeAgent{e: e, key: k, id: computers.ID(spki)}
}

func (a *fakeAgent) enroll(token, name string, at time.Time) (int, []byte) {
	spki, _ := x509.MarshalPKIXPublicKey(&a.key.PublicKey)
	th := computers.TokenHash(token)
	d := computers.EnrollDigest(a.e.panel.PublicURL, hex.EncodeToString(th[:]), a.id, name, at)
	proof, _ := ecdsa.SignASN1(rand.Reader, a.key, d[:])
	return a.e.agentCall(http.MethodPost, "enroll", "", map[string]any{"token": token, "public_key": spki, "name": name,
		"time": at, "proof": proof})
}

func (a *fakeAgent) authorization(method, path string, at time.Time, body []byte) string {
	ts := at.UTC().Format(time.RFC3339Nano)
	d := computers.RequestDigest(method, path, ts, body)
	sig, _ := ecdsa.SignASN1(rand.Reader, a.key, d[:])
	return "WM-Agent id=" + a.id + ", time=" + ts + ", sig=" + base64.StdEncoding.EncodeToString(sig)
}

func (e *env) agentCall(method, path, authz string, body any) (int, []byte) {
	e.t.Helper()
	var rdr io.Reader
	if body != nil {
		b, _ := jsonv2.Marshal(body)
		rdr = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, e.srv.URL+"/api/agent/v1/"+path, rdr)
	if authz != "" {
		req.Header.Set("Authorization", authz)
	}
	resp, err := e.srv.Client().Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, out
}

func (a *fakeAgent) poll(lists int, serial int64) (int, []byte) {
	path := fmt.Sprintf("/api/agent/v1/poll?lists=%d&serial=%d", lists, serial)
	return a.e.agentCall(http.MethodGet, strings.TrimPrefix(path, "/api/agent/v1/"), a.authorization(http.MethodGet, path, a.e.clock.now(), nil), nil)
}

func TestAgentAPI(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL, e.panel.PollFor = "https://wm.example.com", time.Second
	owner := e.browser()
	owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	owner.post("/admin/company", url.Values{"name": {"Other"}})
	acme, other, me := owner.idOf("Acme"), owner.idOf("Other"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})
	owner.post("/admin/member", url.Values{"company": {other}, "account": {me}, "role": {"admin"}})
	tok, account := owner.signIn()
	ctx := context.Background()
	token, err := computers.CreateToken(ctx, e.panel.Store, account, acme, computers.DefaultTokenLife, 2, e.clock.now())
	if err != nil {
		t.Fatal(err)
	}

	pc := newAgent(t, e)
	now := e.clock.now()
	for name, c := range map[string]struct {
		token, name string
		at          time.Time
		want        int
	}{
		"a wrong token":     {"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE", "PC", now, http.StatusUnauthorized},
		"an old proof":      {token, "PC", now.Add(-time.Hour), http.StatusUnauthorized},
		"a name with a tab": {token, "P\tC", now, http.StatusBadRequest},
	} {
		if code, out := pc.enroll(c.token, c.name, c.at); code != c.want {
			t.Errorf("%s: %d %s", name, code, out)
		}
	}
	code, out := pc.enroll(strings.ToLower(token), "OFFICE-03", now)
	if code != http.StatusOK || !strings.Contains(string(out), pc.id) || !strings.Contains(string(out), acme) {
		t.Fatalf("enroll: %d %s", code, out)
	}
	if code, _ := pc.enroll(token, "OFFICE-03", now); code != http.StatusOK {
		t.Fatalf("the same computer again: %d", code)
	}
	// The token is for two computers; the second uses it up.
	if code, _ := newAgent(t, e).enroll(token, "OFFICE-07", now); code != http.StatusOK {
		t.Fatal("a second computer")
	}
	if code, _ := newAgent(t, e).enroll(token, "OFFICE-09", now); code != http.StatusUnauthorized {
		t.Fatalf("a token used up: %d", code)
	}
	// The same key with another company's token.
	token2, _ := computers.CreateToken(ctx, e.panel.Store, account, other, computers.DefaultTokenLife, 1, now)
	if code, _ := pc.enroll(token2, "OFFICE-03", now); code != http.StatusConflict {
		t.Fatalf("a computer of another company: %d", code)
	}

	// The poll: nothing yet, after its wait.
	code, out = pc.poll(0, 0)
	if code != http.StatusOK || !strings.Contains(string(out), `"lists":[]`) || !strings.Contains(string(out), `"state":null`) {
		t.Fatalf("an empty poll: %d %s", code, out)
	}
	// A poll waiting is woken by the first admin list.
	anna, _ := softkey.New(verify.ES256)
	e.registerKey(tok, account, anna)
	s1 := firstList(t, anna, now)
	done := make(chan string)
	go func() {
		_, out := pc.poll(0, 0)
		done <- string(out)
	}()
	time.Sleep(100 * time.Millisecond)
	if code, _ := e.api("POST", "companies/"+acme+"/chain", tok, s1); code != http.StatusOK {
		t.Fatal("the first list")
	}
	select {
	case got := <-done:
		if !strings.Contains(got, `"lists":[{`) {
			t.Fatalf("the woken poll: %s", got)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the poll wasn't woken")
	}
	if code, out := pc.poll(1, 0); code != http.StatusOK || !strings.Contains(string(out), `"lists":[]`) {
		t.Fatalf("a poll with the list held: %d %s", code, out)
	}

	// Refusals of a signed request: a replay, a time too far, another computer's key, an unknown computer.
	path := "/api/agent/v1/poll?lists=1&serial=0"
	authz := pc.authorization(http.MethodGet, path, e.clock.now(), nil)
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=1&serial=0", authz, nil); code != http.StatusOK {
		t.Fatal("a signed poll")
	}
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=1&serial=0", authz, nil); code != http.StatusUnauthorized {
		t.Fatal("a replayed poll")
	}
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=1&serial=0", pc.authorization(http.MethodGet, path, e.clock.now().Add(-10*time.Minute), nil), nil); code != http.StatusUnauthorized {
		t.Fatal("a poll of 10 minutes ago")
	}
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=0&serial=0", authz, nil); code != http.StatusUnauthorized {
		t.Fatal("a signature over another query")
	}
	stranger := newAgent(t, e)
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=1&serial=0", stranger.authorization(http.MethodGet, path, e.clock.now(), nil), nil); code != http.StatusUnauthorized {
		t.Fatal("an unknown computer")
	}
	forged := strings.Replace(stranger.authorization(http.MethodGet, path, e.clock.now(), nil), stranger.id, pc.id, 1)
	if code, _ := e.agentCall(http.MethodGet, "poll?lists=1&serial=0", forged, nil); code != http.StatusUnauthorized {
		t.Fatal("another key under the computer's id")
	}
	// The last contact is kept.
	cs, err := computers.List(ctx, e.panel.Store, account, acme)
	if err != nil || len(cs) != 2 {
		t.Fatalf("List: %v %v", cs, err)
	}
	for _, c := range cs {
		if c.ID == pc.id && c.LastContact.IsZero() {
			t.Fatal("no last contact")
		}
	}
}

var tokenRe = regexp.MustCompile(`<code class="secret">([A-Z2-9]{5}(-[A-Z2-9]{5}){4})</code>`)

func TestEnrollmentTokensPanel(t *testing.T) {
	e := setup(t)
	e.panel.PublicURL, e.panel.PollFor = "https://wm.example.com", time.Second
	owner := e.browser()
	owner.enroll("owner@example.com")
	owner.get("/admin")
	owner.post("/admin/company", url.Values{"name": {"Acme"}})
	acme, me := owner.idOf("Acme"), owner.idOf("owner@example.com")
	owner.post("/admin/member", url.Values{"company": {acme}, "account": {me}, "role": {"admin"}})

	owner.get("/c/" + acme)
	if !strings.Contains(owner.last, "No computer is enrolled yet") || !strings.Contains(owner.last, "No token is waiting") {
		t.Fatal("the company page without computers or tokens")
	}
	_, body := owner.post("/c/"+acme+"/token", url.Values{"days": {"40"}, "uses": {"1"}})
	if !strings.Contains(body, "valid for 1 to 30 days") {
		t.Fatal("a token valid too long")
	}
	_, body = owner.post("/c/"+acme+"/token", url.Values{"days": {"7"}, "uses": {"3"}})
	m := tokenRe.FindStringSubmatch(body)
	if m == nil || strings.Contains(body, `hreflang`) {
		t.Fatalf("the new token isn't shown once: %s", body)
	}
	// A computer enrolls with it and shows on the page.
	pc := newAgent(t, e)
	if code, out := pc.enroll(m[1], "OFFICE-03", e.clock.now()); code != http.StatusOK {
		t.Fatalf("enroll with the panel's token: %d %s", code, out)
	}
	owner.get("/c/" + acme)
	if !strings.Contains(owner.last, "OFFICE-03") || !strings.Contains(owner.last, pc.id[:8]) || !strings.Contains(owner.last, ">2<") {
		t.Fatalf("the computer and the token's uses left: %s", owner.last)
	}
	// A person sees the computers, not the tokens.
	person := e.person(owner, "person@example.com", acme, "person")
	person.get("/c/" + acme)
	if !strings.Contains(person.last, "OFFICE-03") || strings.Contains(person.last, "Enrollment tokens") {
		t.Fatal("a person's view of the company")
	}
	if code, _ := person.post("/c/"+acme+"/token", url.Values{"days": {"7"}, "uses": {"1"}}); code != http.StatusForbidden {
		t.Fatalf("a person makes a token: %d", code)
	}
	// The token ended: it enrolls nothing more.
	owner.get("/c/" + acme)
	id := regexp.MustCompile(`name="token" value="([0-9a-f-]{36})"`).FindStringSubmatch(owner.last)
	if id == nil {
		t.Fatal("no token to end")
	}
	owner.post("/c/"+acme+"/token-end", url.Values{"token": {id[1]}})
	if !strings.Contains(owner.last, "No token is waiting") {
		t.Fatal("the token isn't ended")
	}
	if code, _ := newAgent(t, e).enroll(m[1], "OFFICE-07", e.clock.now()); code != http.StatusUnauthorized {
		t.Fatalf("an ended token: %d", code)
	}
}
