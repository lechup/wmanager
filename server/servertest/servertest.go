// Package servertest runs the whole server (the panel and the sign API, on a fresh database of its own) for the
// tests of programs that talk to it, such as wmanager-sign. It needs what storetest needs:
// WMANAGER_TEST_DATABASE_URL. It is never used outside tests.
package servertest

import (
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
	"github.com/lechup/wmanager/server/internal/web"
)

// Password is every test account's password.
const Password = "a long enough password"

// Server is a running server.
type Server struct {
	URL    string       // https://127.0.0.1:port, also the server's WMANAGER_PUBLIC_URL
	Client *http.Client // trusts the server's test certificate
	Store  *store.Store
	Owner  string // the owner's account id

	t       *testing.T
	auth    *auth.Service
	mu      sync.Mutex
	now     time.Time
	secrets map[string][]byte // TOTP secrets by account id
	emails  map[string]string
}

// New starts a server.
func New(t *testing.T) *Server {
	t.Helper()
	s := storetest.New(t)
	ctx := context.Background()
	owner, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, "owner@example.com", "Owner", Password, true)
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{Store: s, Owner: owner, t: t, now: time.Now().UTC(), secrets: map[string][]byte{},
		emails: map[string]string{owner: "owner@example.com"}}
	a := auth.New(s)
	a.Now = srv.Now
	a.Log = slog.New(slog.DiscardHandler)
	srv.auth = a
	panel, err := web.New(s, a, slog.New(slog.DiscardHandler))
	if err != nil {
		t.Fatal(err)
	}
	h := httptest.NewTLSServer(panel.Handler())
	t.Cleanup(h.Close)
	srv.URL, srv.Client = h.URL, h.Client()
	panel.PublicURL = h.URL
	return srv
}

// Now is the server's clock.
func (s *Server) Now() time.Time { s.mu.Lock(); defer s.mu.Unlock(); return s.now }

// Advance moves the server's clock.
func (s *Server) Advance(d time.Duration) { s.mu.Lock(); s.now = s.now.Add(d); s.mu.Unlock() }

// Company makes a company.
func (s *Server) Company(name string) string {
	s.t.Helper()
	id, err := accounts.CreateCompany(context.Background(), s.Store, accounts.Actor{AccountID: s.Owner}, name)
	if err != nil {
		s.t.Fatal(err)
	}
	return id
}

// Person makes an account and puts it into the company with the role ("admin" or "person"; no company for "").
func (s *Server) Person(email, company, role string) string {
	s.t.Helper()
	ctx := context.Background()
	id, err := accounts.CreateAccount(ctx, s.Store, accounts.SystemActor, email, "Person", Password, false)
	if err != nil {
		s.t.Fatal(err)
	}
	s.mu.Lock()
	s.emails[id] = email
	s.mu.Unlock()
	if company != "" {
		s.Join(id, company, role)
	}
	return id
}

// Join puts an account into a company with the role.
func (s *Server) Join(account, company, role string) {
	s.t.Helper()
	if err := accounts.AddMember(context.Background(), s.Store, accounts.Actor{AccountID: s.Owner}, company, account, role); err != nil {
		s.t.Fatal(err)
	}
}

func totp(secret []byte, at time.Time) string {
	m := hmac.New(sha1.New, secret)
	binary.Write(m, binary.BigEndian, uint64(at.Unix()/30))
	sum := m.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	return fmt.Sprintf("%06d", (binary.BigEndian.Uint32(sum[off:off+4])&0x7fffffff)%1000000)
}

// SignCode signs the account in to the panel, with its second factor (set up the first time), and makes a code
// for wmanager-sign, as the page "Account" does.
func (s *Server) SignCode(account string) string {
	s.t.Helper()
	ctx := context.Background()
	s.mu.Lock()
	email, secret := s.emails[account], s.secrets[account]
	s.mu.Unlock()
	if email == "" {
		s.t.Fatalf("servertest: no account %s", account)
	}
	tok, err := s.auth.SignIn(ctx, "192.0.2.1", email, Password)
	if err != nil {
		s.t.Fatal(err)
	}
	s.Advance(30 * time.Second) // a TOTP code counts once
	if secret == nil {
		u, err := s.auth.BeginTOTP(ctx, tok)
		if err != nil {
			s.t.Fatal(err)
		}
		pu, err := url.Parse(u)
		if err != nil {
			s.t.Fatal(err)
		}
		secret, err = base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(strings.ToUpper(pu.Query().Get("secret")))
		if err != nil {
			s.t.Fatal(err)
		}
		if tok, _, err = s.auth.ConfirmTOTP(ctx, "192.0.2.1", tok, totp(secret, s.Now())); err != nil {
			s.t.Fatal(err)
		}
		s.mu.Lock()
		s.secrets[account] = secret
		s.mu.Unlock()
	} else if tok, err = s.auth.SecondFactor(ctx, "192.0.2.1", tok, totp(secret, s.Now())); err != nil {
		s.t.Fatal(err)
	}
	code, _, err := s.auth.CreateSignCode(ctx, tok)
	if err != nil {
		s.t.Fatal(err)
	}
	return code
}

// ForgetLists removes a company's admin lists after the first keep, as restoring an older backup would.
func (s *Server) ForgetLists(company string, keep int64) {
	s.t.Helper()
	c := storetest.Superuser(s.t, s.Store)
	if _, err := c.Exec(context.Background(), `DELETE FROM admin_lists WHERE company_id = $1 AND sequence > $2`, company, keep); err != nil {
		s.t.Fatal(err)
	}
}
