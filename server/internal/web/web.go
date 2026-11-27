// Package web is the panel (requirement 8): few screens of plain HTML from Go templates, no frontend framework and
// no build step, and no JavaScript in this stage. It signs nothing: statements are signed in wmanager-sign.
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
}

// Handler is the panel's routes, with its protections around them.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(files, "static")
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServerFS(static)))
	mux.HandleFunc("GET /healthz", s.healthz)

	mux.HandleFunc("GET /signin", s.signinPage)
	mux.HandleFunc("POST /signin", s.signin)
	mux.HandleFunc("GET /signin/code", s.passwordStep(s.codePage))
	mux.HandleFunc("POST /signin/code", s.passwordStep(s.code))
	mux.HandleFunc("GET /signin/totp", s.passwordStep(s.totpPage))
	mux.HandleFunc("POST /signin/totp", s.passwordStep(s.totp))
	mux.HandleFunc("GET /setup/{token}", s.setupPage)
	mux.HandleFunc("POST /setup/{token}", s.setup)
	mux.HandleFunc("POST /signout", s.full(s.signout))

	mux.HandleFunc("GET /{$}", s.full(s.home))
	mux.HandleFunc("GET /c/{company}", s.full(s.company))
	mux.HandleFunc("GET /c/{company}/audit.json", s.full(s.auditExport))
	mux.HandleFunc("GET /c/{company}/audit.csv", s.full(s.auditExport))

	mux.HandleFunc("GET /admin", s.owner(s.admin))
	mux.HandleFunc("POST /admin/company", s.owner(s.newCompany))
	mux.HandleFunc("POST /admin/invite", s.owner(s.invite))
	mux.HandleFunc("POST /admin/member", s.owner(s.member))
	mux.HandleFunc("POST /admin/unlock", s.owner(s.unlock))

	cop := http.NewCrossOriginProtection()
	return s.logged(headers(cop.Handler(limitBody(mux))))
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
		h.Set("Content-Security-Policy", "default-src 'none'; style-src 'self'; img-src 'self'; form-action 'self'; "+
			"frame-ancestors 'none'; base-uri 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Opener-Policy", "same-origin")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		h.Set("Permissions-Policy", "camera=(), microphone=(), geolocation=(), interest-cohort=()")
		h.Set("Cache-Control", "no-store")
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
		path := r.URL.Path
		if strings.HasPrefix(path, "/setup/") {
			path = "/setup/…"
		}
		s.Log.Info("request", "method", r.Method, "path", path, "status", sw.status,
			"ms", time.Since(start).Milliseconds(), "address", s.clientAddr(r))
	})
}

// clientAddr is the address of the browser: the connection's, or, behind a trusted proxy, the last address in
// X-Forwarded-For (the one the proxy added).
func (s *Server) clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	for _, p := range s.TrustedProxies {
		if p.Contains(addr.Unmap()) {
			parts := strings.Split(r.Header.Get("X-Forwarded-For"), ",")
			if last := strings.TrimSpace(parts[len(parts)-1]); last != "" {
				return last
			}
		}
	}
	return addr.Unmap().String()
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

func csrfOK(r *http.Request) bool {
	t := token(r)
	return t != "" && subtle.ConstantTimeCompare([]byte(r.PostFormValue("csrf")), []byte(csrf(t))) == 1
}

type handler func(w http.ResponseWriter, r *http.Request, ses auth.Session)

// full needs a session with the second factor given; a form also needs its CSRF token.
func (s *Server) full(h handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ses, err := s.Auth.Lookup(r.Context(), token(r))
		if err != nil || !ses.Full {
			if r.Method == http.MethodGet {
				http.Redirect(w, r, "/signin", http.StatusSeeOther)
				return
			}
			s.fail(w, r, http.StatusForbidden, "error.forbidden")
			return
		}
		if r.Method == http.MethodPost && !csrfOK(r) {
			s.fail(w, r, http.StatusForbidden, "error.forbidden")
			return
		}
		h(w, r, ses)
	}
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
			http.Redirect(w, r, "/signin", http.StatusSeeOther)
			return
		}
		if ses.Full {
			http.Redirect(w, r, "/", http.StatusSeeOther)
			return
		}
		if r.Method == http.MethodPost && !csrfOK(r) {
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
	CSRF    string
	Session *auth.Session
	Error   string
	Notice  string
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
	s.Log.Error("internal error", "path", r.URL.Path, "err", err)
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
	s.render(w, r, http.StatusOK, "code", nil, Page{})
}

func (s *Server) code(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	full, err := s.Auth.SecondFactor(r.Context(), s.clientAddr(r), token(r), r.PostFormValue("code"))
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.render(w, r, status, "code", nil, Page{Error: key})
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
	otpauth, err := s.Auth.BeginTOTP(r.Context(), token(r))
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		s.fail(w, r, status, key)
		return
	}
	qr, secret, err := totpQR(otpauth)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	s.render(w, r, http.StatusOK, "totp", nil, Page{Data: TOTPPage{QR: qr, Secret: secret}})
}

func (s *Server) totp(w http.ResponseWriter, r *http.Request, ses auth.Session) {
	full, codes, err := s.Auth.ConfirmTOTP(r.Context(), s.clientAddr(r), token(r), r.PostFormValue("code"))
	if err != nil {
		status, key := authError(err)
		if key == "" {
			s.internal(w, r, err)
			return
		}
		// A new secret is offered on the next visit; this one stays pending until then.
		s.render(w, r, status, "error", nil, Page{Error: key, Notice: "totp.again"})
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
	Company accounts.Company
	Members []accounts.Member
	Entries []audit.Record // newest first, at most 100
	Total   int
	Head    string
	Broken  string
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
	head, err := audit.Verify(r.Context(), s.Store, who, audit.CompanyChain(c.ID), nil)
	switch {
	case errors.Is(err, audit.ErrBroken):
		p.Broken = err.Error()
	case err != nil:
		s.internal(w, r, err)
		return
	default:
		p.Head = fmt.Sprintf("%d:%x", head.Seq, head.Hash)
	}
	recs, err := audit.Read(r.Context(), s.Store, who, audit.CompanyChain(c.ID))
	if err != nil && !errors.Is(err, audit.ErrBroken) {
		s.internal(w, r, err)
		return
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
	recs, err := audit.Read(r.Context(), s.Store, store.Who{Account: ses.AccountID}, audit.CompanyChain(c.ID))
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
		recs, err = audit.Read(r.Context(), s.Store, store.Who{Account: ses.AccountID}, audit.ServerChain)
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
		strings.TrimSpace(r.PostFormValue("name")))
	if err != nil {
		s.afterAdmin(w, r, ses, err)
		return
	}
	base := s.PublicURL
	if base == "" {
		base = "https://" + r.Host
	}
	// Shown once, in this response; only the token's hash is kept.
	s.adminPage(w, r, ses, http.StatusOK, Page{Data: AdminPage{Link: base + "/setup/" + tok,
		LinkFor: auth.NormalizeEmail(email)}})
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
