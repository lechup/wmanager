// Package web is the panel (requirement 8): few screens of plain HTML from Go templates, no frontend framework and
// no build step. Its only JavaScript is one small static file for passkeys (static/passkey.js). It signs nothing:
// statements are signed in wmanager-sign.
//
// Every response carries a strict Content Security Policy. Forms that change something are refused when they
// come from another site (Sec-Fetch-Site or Origin) or, inside a session, without the session's CSRF token. The
// session cookie is __Host-, Secure, HttpOnly and SameSite=Strict.
package web

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"errors"
	"fmt"
	"html/template"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/signapi"
	"github.com/lechup/wmanager/server/internal/store"
)

//go:embed templates/*.html static/*
var files embed.FS

// CookieName is the session cookie. The __Host- prefix makes the browser keep it only from https, for this host
// and path /.
const CookieName = "__Host-wmanager"

// Server is the panel.
type Server struct {
	Store          *store.Store
	Auth           *auth.Service
	Log            *slog.Logger
	PublicURL      string         // e.g. https://wm.example.com; "" means the request's host
	TrustedProxies []netip.Prefix // whose X-Forwarded-For is believed

	pages map[string]*template.Template
}

// New returns the panel.
func New(s *store.Store, a *auth.Service, log *slog.Logger) (*Server, error) {
	srv := &Server{Store: s, Auth: a, Log: log, pages: map[string]*template.Template{}}
	names, err := fs.Glob(files, "templates/*.html")
	if err != nil {
		return nil, err
	}
	for _, n := range names {
		page := strings.TrimSuffix(strings.TrimPrefix(n, "templates/"), ".html")
		if page == "layout" {
			continue
		}
		t, err := template.New("layout.html").Funcs(funcs).ParseFS(files, "templates/layout.html", n)
		if err != nil {
			return nil, fmt.Errorf("web: %s: %w", n, err)
		}
		srv.pages[page] = t
	}
	return srv, nil
}

var funcs = template.FuncMap{
	// t is replaced per request with the request's language.
	"t":    func(key string, args ...any) string { return key },
	"time": func(t time.Time) string { return t.UTC().Format("2006-01-02 15:04:05 UTC") },
	"b64":  func(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) },
	"keyfp": func(id string) string {
		if len(id) < 32 {
			return id
		}
		var g []string
		for i := 0; i < 32; i += 4 {
			g = append(g, strings.ToUpper(id[i:i+4]))
		}
		return strings.Join(g, "-")
	},
}

// Handler is the panel's routes, with its protections around them.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	for _, f := range []string{"style.css", "passkey.js"} {
		mux.HandleFunc("GET /static/"+f, func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Cache-Control", "public, max-age=3600")
			http.ServeFileFS(w, r, files, "static/"+f)
		})
	}
	mux.HandleFunc("GET /healthz", s.healthz)

	mux.HandleFunc("GET /signin", s.signinPage)
	mux.HandleFunc("POST /signin", s.signin)
	mux.HandleFunc("GET /signin/code", s.passwordStep(s.codePage))
	mux.HandleFunc("POST /signin/code", s.passwordStep(s.code))
	mux.HandleFunc("GET /signin/totp", s.passwordStep(s.totpPage))
	mux.HandleFunc("POST /signin/totp", s.passwordStep(s.totp))
	mux.HandleFunc("POST /signin/passkey/begin", s.passwordStep(s.passkeySignInBegin))
	mux.HandleFunc("POST /signin/passkey/finish", s.passwordStep(s.passkeySignInFinish))
	mux.HandleFunc("GET /setup/{token}", s.setupPage)
	mux.HandleFunc("POST /setup/{token}", s.setup)
	mux.HandleFunc("POST /signout", s.full(s.signout))

	mux.HandleFunc("GET /{$}", s.full(s.home))
	mux.HandleFunc("GET /account", s.full(s.account))
	mux.HandleFunc("POST /account/passkey/begin", s.full(s.passkeyAddBegin))
	mux.HandleFunc("POST /account/passkey/finish", s.full(s.passkeyAddFinish))
	mux.HandleFunc("POST /account/passkey/remove", s.full(s.passkeyRemove))
	mux.HandleFunc("POST /account/sign-code", s.full(s.signCode))
	mux.HandleFunc("POST /account/sign-revoke", s.full(s.signRevoke))
	mux.HandleFunc("GET /c/{company}", s.full(s.company))
	mux.HandleFunc("GET /c/{company}/audit.json", s.full(s.auditExport))
	mux.HandleFunc("GET /c/{company}/audit.csv", s.full(s.auditExport))

	mux.HandleFunc("GET /admin", s.owner(s.admin))
	mux.HandleFunc("POST /admin/company", s.owner(s.newCompany))
	mux.HandleFunc("POST /admin/invite", s.owner(s.invite))
	mux.HandleFunc("POST /admin/link", s.owner(s.newLink))
	mux.HandleFunc("POST /admin/member", s.owner(s.member))
	mux.HandleFunc("POST /admin/unlock", s.owner(s.unlock))

	cop := http.NewCrossOriginProtection()
	top := http.NewServeMux()
	top.Handle("/", cop.Handler(limitBody(mux)))
	api := &signapi.API{Store: s.Store, Auth: s.Auth, Log: s.Log, ClientAddr: s.clientAddr}
	top.Handle(signapi.Prefix, api.Handler())
	return s.logged(headers(top))
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	if err := s.Store.Pool.Ping(r.Context()); err != nil {
		http.Error(w, "database unreachable", http.StatusServiceUnavailable)
		return
	}
	fmt.Fprintln(w, "ok")
}

// headers sets the protections every response carries.
func headers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; "+
			"img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), interest-cohort=()")
		h.Set("Cache-Control", "no-store")
		// The panel is https only (its cookie is Secure): no first visit over plain http to strip.
		h.Set("Strict-Transport-Security", "max-age=31536000")
		next.ServeHTTP(w, r)
	})
}

func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, 64<<10)
		next.ServeHTTP(w, r)
	})
}

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) { w.status = code; w.ResponseWriter.WriteHeader(code) }

// logged logs each request, without the token of a setup link in its path.
func (s *Server) logged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(sw, r)
		s.Log.Info("request", "method", r.Method, "path", redact(r.URL.Path), "status", sw.status,
			"ms", time.Since(start).Milliseconds(), "address", s.clientAddr(r))
	})
}

// redact hides the token of a setup link in a path, wherever it is in it.
func redact(path string) string {
	if i := strings.Index(path, "/setup/"); i >= 0 {
		return path[:i] + "/setup/…"
	}
	return path
}

func (s *Server) trusted(a netip.Addr) bool {
	for _, p := range s.TrustedProxies {
		if p.Contains(a) {
			return true
		}
	}
	return false
}

// clientAddr is the address of the browser. It is the connection's, unless that is a trusted proxy: then
// X-Forwarded-For (all its lines) is read from the right, past every trusted proxy, to the first address that
// isn't one. An entry that isn't an address ends the walk at the proxy that wrote it.
func (s *Server) clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	peer, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	addr := peer.Unmap()
	if !s.trusted(addr) {
		return addr.String()
	}
	var hops []string
	for _, line := range r.Header.Values("X-Forwarded-For") {
		hops = append(hops, strings.Split(line, ",")...)
	}
	for i := len(hops) - 1; i >= 0; i-- {
		hop, err := netip.ParseAddr(strings.TrimSpace(hops[i]))
		if err != nil {
			break
		}
		addr = hop.Unmap()
		if !s.trusted(addr) {
			break
		}
	}
	return addr.String()
}

// --- sessions

func (s *Server) setCookie(w http.ResponseWriter, token string, maxAge time.Duration) {
	http.SetCookie(w, &http.Cookie{Name: CookieName, Value: token, Path: "/", MaxAge: int(maxAge.Seconds()),
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

func (s *Server) clearCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: CookieName, Value: "", Path: "/", MaxAge: -1,
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

func token(r *http.Request) string {
	c, err := r.Cookie(CookieName)
	if err != nil {
		return ""
	}
	return c.Value
}

// csrf is the session's CSRF token: derived from the session token, which a page from another site can't read.
func csrf(sessionToken string) string {
	h := sha256.Sum256([]byte("wmanager csrf\x00" + sessionToken))
	return base64.RawURLEncoding.EncodeToString(h[:])
}

// csrfOK checks a form's token, or, for the passkeys' JSON requests, the X-CSRF-Token header.
func csrfOK(r *http.Request) bool {
	t := token(r)
	got := r.Header.Get("X-CSRF-Token")
	if got == "" && !strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		got = r.PostFormValue("csrf")
	}
	return t != "" && subtle.ConstantTimeCompare([]byte(got), []byte(csrf(t))) == 1
}

type handler func(w http.ResponseWriter, r *http.Request, ses auth.Session)

// full needs a session with the second factor given; a form also needs its CSRF token.
func (s *Server) full(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ses, err := s.Auth.Lookup(r.Context(), token(r))
		if err != nil || !ses.Full {
			if isJSON(r) {
				jsonOut(w, http.StatusUnauthorized, []byte(`{"error":"signin"}`))
				return
			}
			if r.Method == http.MethodGet {
				http.Redirect(w, r, "/signin", http.StatusSeeOther)
				return
			}
			s.fail(w, r, http.StatusForbidden, "error.forbidden")
			return
		}
		if r.Method == http.MethodPost && !csrfOK(r) {
			if isJSON(r) {
				jsonOut(w, http.StatusForbidden, []byte(`{"error":"forbidden"}`))
				return
			}
			s.fail(w, r, http.StatusForbidden, "error.forbidden")
			return
		}
		h(w, r, ses)
	}
}

// isJSON tells a request of passkey.js, which wants JSON answers, also when the session has ended.
func isJSON(r *http.Request) bool {
	return strings.HasPrefix(r.Header.Get("Content-Type"), "application/json")
}

func (s *Server) owner(h handler) http.HandlerFunc {
	return s.full(func(w http.ResponseWriter, r *http.Request, ses auth.Session) {
		if !ses.IsOwner {
			s.fail(w, r, http.StatusNotFound, "error.notfound")
			return
		}
		h(w, r, ses)
	})
}

// passwordStep needs a session at the password step.
func (s *Server) passwordStep(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ses, err := s.Auth.Lookup(r.Context(), token(r))
		if err != nil {
			if isJSON(r) {
				jsonOut(w, http.StatusUnauthorized, []byte(`{"error":"signin"}`))
				return
			}
			http.Redirect(w, r, "/signin", http.StatusSeeOther)
			return
		}
		if ses.Full {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		if r.Method == http.MethodPost && !csrfOK(r) {
			if isJSON(r) {
				jsonOut(w, http.StatusForbidden, []byte(`{"error":"forbidden"}`))
				return
			}
			s.fail(w, r, http.StatusForbidden, "error.forbidden")
			return
		}
		h(w, r, ses)
	}
}

// --- rendering

// Page is what every template gets.
type Page struct {
	Lang    string
	Langs   []string
	Path    string
	NoLang  bool // no links to change the language: the page is an answer to a form, or shows a secret once
	CSRF    string
	Session *auth.Session
	Error   string
	Data    any
}

func (s *Server) render(w http.ResponseWriter, r *http.Request, status int, name string, ses *auth.Session, p Page) {
	t, ok := s.pages[name]
	if !ok {
		http.Error(w, "no such page", http.StatusInternalServerError)
		return
	}
	lang := s.language(w, r)
	p.Lang, p.Langs, p.Path, p.Session = lang, languages, r.URL.Path, ses
	if r.Method != http.MethodGet {
		p.NoLang = true
	}
	if tok := token(r); tok != "" {
		p.CSRF = csrf(tok)
	}
	t, err := t.Clone()
	if err == nil {
		t = t.Funcs(template.FuncMap{"t": func(key string, args ...any) string { return translate(lang, key, args...) }})
	}
	var buf bytes.Buffer
	if err == nil {
		err = t.ExecuteTemplate(&buf, "layout.html", p)
	}
	if err != nil {
		s.Log.Error("template", "page", name, "err", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	w.Write(buf.Bytes())
}

func (s *Server) fail(w http.ResponseWriter, r *http.Request, status int, key string) {
	s.render(w, r, status, "error", nil, Page{Error: key})
}

func (s *Server) internal(w http.ResponseWriter, r *http.Request, err error) {
	s.Log.Error("internal error", "path", redact(r.URL.Path), "err", err)
	s.fail(w, r, http.StatusInternalServerError, "error.internal")
}

// authError is the message for an error of sign-in.
func authError(err error) (int, string) {
	switch {
	case errors.Is(err, auth.ErrSignIn):
		return http.StatusUnauthorized, "error.signin"
	case errors.Is(err, auth.ErrCode):
		return http.StatusUnauthorized, "error.code"
	case errors.Is(err, auth.ErrLocked):
		return http.StatusForbidden, "error.locked"
	case errors.Is(err, auth.ErrTooMany):
		return http.StatusTooManyRequests, "error.toomany"
	case errors.Is(err, auth.ErrNoSetup):
		return http.StatusNotFound, "error.setup"
	case errors.Is(err, auth.ErrWeakPassword):
		return http.StatusBadRequest, "error.weak"
	case errors.Is(err, auth.ErrNoSession), errors.Is(err, auth.ErrWrongStage):
		return http.StatusUnauthorized, "error.session"
	}
	return http.StatusInternalServerError, ""
}

// --- sign-in

func (s *Server) signinPage(w http.ResponseWriter, r *http.Request) {
	s.render(w, r, http.StatusOK, "signin", nil, Page{})
}

func (s *Server) signin(w http.ResponseWriter, r *http.Request) {
	tok, err := s.Auth.SignIn(r.Context(), s.clientAddr(r), r.PostFormValue("email"), r.PostFormValue("password"))
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.render(w, r, status, "signin", nil, Page{Error: key})
		return
	}
	s.setCookie(w, tok, auth.PasswordStage)
	ses, err := s.Auth.Lookup(r.Context(), tok)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	next := "/signin/code"
	if !ses.HasTOTP {
		next = "/signin/totp"
	}
	http.Redirect(w, r, next, http.StatusSeeOther)
}

func (s *Server) codePage(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	if !ses.HasTOTP {
		http.Redirect(w, r, "/signin/totp", http.StatusSeeOther)
		return
	}
	s.renderCode(w, r, http.StatusOK, "")
}

// renderCode shows the page of the second factor, with the passkey button when the account has a passkey (and
// the panel knows its own address, which passkeys need).
func (s *Server) renderCode(w http.ResponseWriter, r *http.Request, status int, errKey string) {
	has := false
	if rp, err := s.rp(); err == nil {
		if has, err = s.Auth.HasPasskeys(r.Context(), rp, token(r)); err != nil {
			s.internal(w, r, err)
			return
		}
	}
	s.render(w, r, status, "code", nil, Page{Error: errKey, Data: has})
}

func (s *Server) code(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	full, err := s.Auth.SecondFactor(r.Context(), s.clientAddr(r), token(r), r.PostFormValue("code"))
	if errors.Is(err, auth.ErrNeedsTOTP) {
		http.Redirect(w, r, "/signin/totp", http.StatusSeeOther)
		return
	}
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.renderCode(w, r, status, key)
		return
	}
	s.setCookie(w, full, auth.SessionMax)
	http.Redirect(w, r, "/", http.StatusSeeOther)
}

// TOTPPage is the data of the page that sets up TOTP.
type TOTPPage struct {
	QR     template.HTML
	Secret string
}

func (s *Server) totpPage(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	if ses.HasTOTP {
		http.Redirect(w, r, "/signin/code", http.StatusSeeOther)
		return
	}
	s.showTOTP(w, r, http.StatusOK, "")
}

// showTOTP shows the secret this session is offered (the same one again after a wrong code).
func (s *Server) showTOTP(w http.ResponseWriter, r *http.Request, status int, errKey string) {
	otpauth, err := s.Auth.BeginTOTP(r.Context(), token(r))
	switch {
	case errors.Is(err, auth.ErrHasTOTP):
		http.Redirect(w, r, "/signin/code", http.StatusSeeOther)
		return
	case errors.Is(err, auth.ErrLocked):
		s.fail(w, r, http.StatusForbidden, "error.lockedsetup")
		return
	case err != nil:
		st, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.fail(w, r, st, key)
		return
	}
	qr, secret, err := totpQR(otpauth)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	// The secret is on the page: no links that would load it again.
	s.render(w, r, status, "totp", nil, Page{Error: errKey, NoLang: true, Data: TOTPPage{QR: qr, Secret: secret}})
}

func (s *Server) totp(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	full, codes, err := s.Auth.ConfirmTOTP(r.Context(), s.clientAddr(r), token(r), r.PostFormValue("code"))
	switch {
	case errors.Is(err, auth.ErrHasTOTP):
		http.Redirect(w, r, "/signin/code", http.StatusSeeOther)
		return
	case errors.Is(err, auth.ErrNoSuchSecret):
		http.Redirect(w, r, "/signin/totp", http.StatusSeeOther)
		return
	case errors.Is(err, auth.ErrCode):
		s.showTOTP(w, r, http.StatusUnauthorized, "error.code")
		return
	case errors.Is(err, auth.ErrLocked):
		// No recovery codes exist yet while the second factor is set up.
		s.fail(w, r, http.StatusForbidden, "error.lockedsetup")
		return
	case err != nil:
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.fail(w, r, status, key)
		return
	}
	s.setCookie(w, full, auth.SessionMax)
	// Shown once, straight in this response; never stored or sent again.
	s.render(w, r, http.StatusOK, "recovery", nil, Page{Data: codes})
}

func (s *Server) setupPage(w http.ResponseWriter, r *http.Request) {
	email, err := s.Auth.SetupEmail(r.Context(), r.PathValue("token"))
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.fail(w, r, status, key)
		return
	}
	s.render(w, r, http.StatusOK, "setup", nil, Page{Data: email})
}

func (s *Server) setup(w http.ResponseWriter, r *http.Request) {
	tok := r.PathValue("token")
	email, err := s.Auth.SetupEmail(r.Context(), tok)
	if err == nil && r.PostFormValue("password") != r.PostFormValue("again") {
		s.render(w, r, http.StatusBadRequest, "setup", nil, Page{Data: email, Error: "password.mismatch"})
		return
	}
	var session string
	if err == nil {
		session, err = s.Auth.CompleteSetup(r.Context(), s.clientAddr(r), tok, r.PostFormValue("password"))
	}
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		if errors.Is(err, auth.ErrWeakPassword) {
			s.render(w, r, status, "setup", nil, Page{Data: email, Error: key})
			return
		}
		s.fail(w, r, status, key)
		return
	}
	s.setCookie(w, session, auth.PasswordStage)
	http.Redirect(w, r, "/signin/totp", http.StatusSeeOther)
}

func (s *Server) signout(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	if err := s.Auth.SignOut(r.Context(), token(r)); err != nil {
		s.internal(w, r, err)
		return
	}
	s.clearCookie(w)
	http.Redirect(w, r, "/signin", http.StatusSeeOther)
}

// --- the companies

func (s *Server) home(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	cs, err := accounts.CompaniesOf(r.Context(), s.Store, ses.AccountID)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "home", &ses, Page{Data: cs})
}

// CompanyPage is the data of a company's page.
type CompanyPage struct {
	Chain       *chains.Summary
	ChainBroken string
	Company     accounts.Company
	Members     []accounts.Member
	Entries     []audit.Record // newest first, at most 100
	Total       int
	Head        string
	Broken      string
}

// companyOf finds the company among the account's own: another company's id is "not found", the same as one
// that doesn't exist.
func (s *Server) companyOf(r *http.Request, ses auth.Session) (accounts.Company, bool, error) {
	cs, err := accounts.CompaniesOf(r.Context(), s.Store, ses.AccountID)
	if err != nil {
		return accounts.Company{}, false, err
	}
	for _, c := range cs {
		if c.ID == r.PathValue("company") {
			return c, true, nil
		}
	}
	return accounts.Company{}, false, nil
}

func (s *Server) company(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	c, ok, err := s.companyOf(r, ses)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !ok {
		s.fail(w, r, http.StatusNotFound, "error.notfound")
		return
	}
	members, err := accounts.Members(r.Context(), s.Store, ses.AccountID, c.ID)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	who := store.Who{Account: ses.AccountID}
	p := CompanyPage{Company: c, Members: members}
	p.Chain, err = chains.Summarize(r.Context(), s.Store, ses.AccountID, c.ID)
	switch {
	case errors.Is(err, chains.ErrBroken):
		p.ChainBroken = err.Error()
	case err != nil:
		s.internal(w, r, err)
		return
	}
	head, recs, err := audit.Check(r.Context(), s.Store, who, audit.CompanyChain(c.ID), nil)
	switch {
	case errors.Is(err, audit.ErrBroken):
		p.Broken = err.Error()
		// Show what is stored, unchecked, so the break can be seen.
		if recs, err = audit.ReadUnchecked(r.Context(), s.Store, who, audit.CompanyChain(c.ID)); err != nil {
			s.internal(w, r, err)
			return
		}
	case err != nil:
		s.internal(w, r, err)
		return
	default:
		p.Head = fmt.Sprintf("%d:%x", head.Seq, head.Hash)
	}
	p.Total = len(recs)
	for i := len(recs) - 1; i >= 0 && len(p.Entries) < 100; i-- {
		p.Entries = append(p.Entries, recs[i])
	}
	s.render(w, r, http.StatusOK, "company", &ses, Page{Data: p})
}

func (s *Server) auditExport(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	c, ok, err := s.companyOf(r, ses)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !ok {
		s.fail(w, r, http.StatusNotFound, "error.notfound")
		return
	}
	// The entries as stored, with their stored hashes: a broken chain is exported too, which is when it is needed.
	recs, err := audit.ReadUnchecked(r.Context(), s.Store, store.Who{Account: ses.AccountID}, audit.CompanyChain(c.ID))
	if err != nil {
		s.internal(w, r, err)
		return
	}
	var buf bytes.Buffer
	name := "audit-" + c.ID
	if strings.HasSuffix(r.URL.Path, ".csv") {
		err, name = audit.ExportCSV(&buf, recs), name+".csv"
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
	} else {
		err, name = audit.ExportJSON(&buf, recs), name+".jsonl"
		w.Header().Set("Content-Type", "application/jsonl; charset=utf-8")
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	w.Header().Set("Content-Disposition", `attachment; filename="`+name+`"`)
	w.Write(buf.Bytes())
}

// --- the owner of the server

// AdminPage is the data of the owner's page.
type AdminPage struct {
	Companies []accounts.Company
	Accounts  []accounts.AccountInfo
	Entries   []audit.Record // of the server's chain, newest first, at most 50
	Link      string         // a setup link just made, shown once
	LinkFor   string
	Roles     []string
}

func (s *Server) adminPage(w http.ResponseWriter, r *http.Request, ses auth.Session, status int, p Page) {
	by := accounts.Actor{AccountID: ses.AccountID}
	data, _ := p.Data.(AdminPage)
	var err error
	if data.Companies, err = accounts.AllCompanies(r.Context(), s.Store, by); err == nil {
		data.Accounts, err = accounts.List(r.Context(), s.Store, by)
	}
	var recs []audit.Record
	if err == nil {
		recs, err = audit.ReadUnchecked(r.Context(), s.Store, store.Who{Account: ses.AccountID}, audit.ServerChain)
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	for i := len(recs) - 1; i >= 0 && len(data.Entries) < 50; i-- {
		data.Entries = append(data.Entries, recs[i])
	}
	data.Roles = []string{accounts.RoleAdmin, accounts.RolePerson}
	p.Data = data
	s.render(w, r, status, "admin", &ses, p)
}

func (s *Server) admin(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	s.adminPage(w, r, ses, http.StatusOK, Page{})
}

// accountsError is the message for an error of the accounts package.
func accountsError(err error) (int, string) {
	switch {
	case errors.Is(err, accounts.ErrExists):
		return http.StatusConflict, "error.exists"
	case errors.Is(err, accounts.ErrBadEmail), errors.Is(err, accounts.ErrBadName), errors.Is(err, accounts.ErrBadRole),
		errors.Is(err, accounts.ErrNoAccount), errors.Is(err, accounts.ErrNoCompany):
		return http.StatusBadRequest, "error.badinput"
	case errors.Is(err, accounts.ErrNotOwner):
		return http.StatusForbidden, "error.forbidden"
	case errors.Is(err, accounts.ErrNotPending):
		return http.StatusConflict, "error.notpending"
	}
	return http.StatusInternalServerError, ""
}

func (s *Server) afterAdmin(w http.ResponseWriter, r *http.Request, ses auth.Session, err error) {
	if err != nil {
		status, key := accountsError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.adminPage(w, r, ses, status, Page{Error: key})
		return
	}
	http.Redirect(w, r, "/admin", http.StatusSeeOther)
}

func (s *Server) newCompany(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	_, err := accounts.CreateCompany(r.Context(), s.Store, accounts.Actor{AccountID: ses.AccountID},
		strings.TrimSpace(r.PostFormValue("name")))
	s.afterAdmin(w, r, ses, err)
}

func (s *Server) invite(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	email := r.PostFormValue("email")
	_, tok, err := accounts.Invite(r.Context(), s.Store, accounts.Actor{AccountID: ses.AccountID}, email,
		strings.TrimSpace(r.PostFormValue("name")), s.Auth.Now())
	if err != nil {
		s.afterAdmin(w, r, ses, err)
		return
	}
	s.showLink(w, r, ses, auth.NormalizeEmail(email), tok)
}

// showLink shows a setup link once, in this response; only the token's hash is kept. A lost one is replaced
// with "New link".
func (s *Server) showLink(w http.ResponseWriter, r *http.Request, ses auth.Session, email, tok string) {
	base := s.PublicURL
	if base == "" {
		base = "https://" + r.Host
	}
	s.adminPage(w, r, ses, http.StatusOK, Page{Data: AdminPage{Link: base + "/setup/" + tok, LinkFor: email}})
}

func (s *Server) newLink(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	email, tok, err := accounts.NewLink(r.Context(), s.Store, accounts.Actor{AccountID: ses.AccountID},
		r.PostFormValue("account"), s.Auth.Now())
	if err != nil {
		s.afterAdmin(w, r, ses, err)
		return
	}
	s.showLink(w, r, ses, email, tok)
}

func (s *Server) member(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	err := accounts.AddMember(r.Context(), s.Store, accounts.Actor{AccountID: ses.AccountID},
		r.PostFormValue("company"), r.PostFormValue("account"), r.PostFormValue("role"))
	s.afterAdmin(w, r, ses, err)
}

func (s *Server) unlock(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	err := accounts.Unlock(r.Context(), s.Store, accounts.Actor{AccountID: ses.AccountID}, r.PostFormValue("email"))
	s.afterAdmin(w, r, ses, err)
}

// --- passkeys

var errNoPublicURL = errors.New("web: passkeys need WMANAGER_PUBLIC_URL")

// rp is the relying party of passkeys: from the panel's configured address only. Without one, there are no
// passkeys: a request's Host header must never choose the relying party.
func (s *Server) rp() (auth.RP, error) {
	if s.PublicURL == "" {
		return auth.RP{}, errNoPublicURL
	}
	return auth.RPFor(s.PublicURL)
}

func jsonOut(w http.ResponseWriter, status int, body []byte) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	w.Write(body)
}

// jsonFail answers a passkey request that didn't work, with no detail for the page (its text is the page's own).
func (s *Server) jsonFail(w http.ResponseWriter, r *http.Request, err error) {
	status, code := http.StatusBadRequest, "failed"
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		status = http.StatusRequestEntityTooLarge
	case errors.Is(err, errNoPublicURL):
		status, code = http.StatusNotFound, "unavailable"
	case errors.Is(err, auth.ErrStale):
		status, code = http.StatusForbidden, "stale"
	case errors.Is(err, auth.ErrLocked):
		status = http.StatusForbidden
	case errors.Is(err, auth.ErrTooMany):
		status = http.StatusTooManyRequests
	case errors.Is(err, auth.ErrNoSession), errors.Is(err, auth.ErrWrongStage):
		status, code = http.StatusUnauthorized, "signin"
	case errors.Is(err, auth.ErrPasskey), errors.Is(err, auth.ErrNoCeremony), errors.Is(err, auth.ErrNoPasskeys),
		errors.Is(err, auth.ErrBadName), errors.Is(err, auth.ErrCode):
	default:
		s.Log.Error("passkey", "path", r.URL.Path, "err", err)
		status = http.StatusInternalServerError
	}
	jsonOut(w, status, []byte(`{"error":"`+code+`"}`))
}

func readJSON(r *http.Request) ([]byte, error) {
	var b bytes.Buffer
	_, err := b.ReadFrom(r.Body)
	return b.Bytes(), err
}

func (s *Server) passkeySignInBegin(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	rp, err := s.rp()
	if err == nil {
		var opts []byte
		if opts, err = s.Auth.BeginPasskeySignIn(r.Context(), rp, token(r)); err == nil {
			jsonOut(w, http.StatusOK, opts)
			return
		}
	}
	s.jsonFail(w, r, err)
}

func (s *Server) passkeySignInFinish(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	body, err := readJSON(r)
	rp, err2 := s.rp()
	if err == nil {
		err = err2
	}
	var full string
	if err == nil {
		full, err = s.Auth.FinishPasskeySignIn(r.Context(), rp, s.clientAddr(r), token(r), body)
	}
	if err != nil {
		s.jsonFail(w, r, err)
		return
	}
	s.setCookie(w, full, auth.SessionMax)
	jsonOut(w, http.StatusOK, []byte(`{"redirect":"/"}`))
}

// AccountPage is the data of the account's page.
type AccountPage struct {
	Passkeys    []auth.Passkey
	CanAdd      bool   // the panel knows its own address (WMANAGER_PUBLIC_URL), which passkeys need
	SignCode    string // a code for wmanager-sign, shown once
	SignExpires time.Time
	SignStale   bool // a code needs the second factor given within auth.FreshFor
}

func (s *Server) account(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	s.accountPage(w, r, ses, AccountPage{})
}

func (s *Server) accountPage(w http.ResponseWriter, r *http.Request, ses auth.Session, data AccountPage) {
	keys, err := s.Auth.Passkeys(r.Context(), token(r))
	if err != nil {
		s.internal(w, r, err)
		return
	}
	_, rpErr := s.rp()
	data.Passkeys, data.CanAdd = keys, rpErr == nil
	s.render(w, r, http.StatusOK, "account", &ses, Page{Data: data})
}

// signCode shows a code for wmanager-sign once, in this response.
func (s *Server) signCode(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	code, expires, err := s.Auth.CreateSignCode(r.Context(), token(r))
	if errors.Is(err, auth.ErrStale) {
		s.accountPage(w, r, ses, AccountPage{SignStale: true})
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	s.accountPage(w, r, ses, AccountPage{SignCode: code, SignExpires: expires})
}

func (s *Server) signRevoke(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	if err := s.Auth.RevokeSignTokens(r.Context(), token(r)); err != nil {
		s.internal(w, r, err)
		return
	}
	http.Redirect(w, r, "/account", http.StatusSeeOther)
}

func (s *Server) passkeyAddBegin(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	rp, err := s.rp()
	if err == nil {
		var opts []byte
		if opts, err = s.Auth.BeginPasskeyRegistration(r.Context(), rp, token(r)); err == nil {
			jsonOut(w, http.StatusOK, opts)
			return
		}
	}
	s.jsonFail(w, r, err)
}

func (s *Server) passkeyAddFinish(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	body, err := readJSON(r)
	rp, err2 := s.rp()
	if err == nil {
		err = err2
	}
	if err == nil {
		err = s.Auth.FinishPasskeyRegistration(r.Context(), rp, token(r), r.URL.Query().Get("name"), body)
	}
	if err != nil {
		s.jsonFail(w, r, err)
		return
	}
	jsonOut(w, http.StatusOK, []byte(`{"redirect":"/account"}`))
}

func (s *Server) passkeyRemove(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	id, err := base64.RawURLEncoding.DecodeString(r.PostFormValue("id"))
	if err != nil {
		http.Redirect(w, r, "/account", http.StatusSeeOther) // not one of its ids
		return
	}
	err = s.Auth.RemovePasskey(r.Context(), token(r), id)
	if err != nil && !errors.Is(err, auth.ErrNoSuchKey) {
		s.internal(w, r, err)
		return
	}
	http.Redirect(w, r, "/account", http.StatusSeeOther)
}
