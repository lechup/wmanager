// Package signapi is the API wmanager-sign talks to (stage 2b): signing in with a code from the panel, the server's
// clock (wmanager-sign signs only when its own is within 10 minutes of it), the companies, their chains of admin
// lists, and the signing keys people register. It hands out and takes signed statements; it signs nothing.
package signapi

import (
	"encoding/json/v2"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Prefix is where the API lives.
const Prefix = "/api/sign/v1/"

// MaxBody is the largest request: an admin list's limit and its signature, with room.
const MaxBody = 512 << 10

// API is the sign API.
type API struct {
	Store *store.Store
	Auth  *auth.Service
	Log   *slog.Logger
	// ClientAddr gives the client's address (the panel's, which knows the trusted proxies).
	ClientAddr func(*http.Request) string
}

// Handler is the API's routes.
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST "+Prefix+"login", a.login)
	mux.HandleFunc("GET "+Prefix+"time", a.time)
	mux.HandleFunc("GET "+Prefix+"me", a.authed(a.me))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/chain", a.authed(a.chain))
	mux.HandleFunc("POST "+Prefix+"companies/{company}/chain", a.authed(a.appendList))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/keys", a.authed(a.companyKeys))
	mux.HandleFunc("POST "+Prefix+"keys", a.authed(a.registerKey))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
		w.Header().Set("Cache-Control", "no-store")
		mux.ServeHTTP(w, r)
	})
}

func out(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.MarshalWrite(w, v)
}

type apiError struct {
	Error string `json:"error"`
}

func fail(w http.ResponseWriter, status int, msg string) { out(w, status, apiError{msg}) }

func (a *API) failErr(w http.ResponseWriter, r *http.Request, err error) {
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		fail(w, http.StatusRequestEntityTooLarge, "too large")
	case errors.Is(err, auth.ErrSignCode), errors.Is(err, auth.ErrSignToken):
		fail(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, auth.ErrTooMany):
		fail(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, errBadRequest), errors.Is(err, chains.ErrBadKey):
		fail(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, chains.ErrNotAdmin):
		fail(w, http.StatusForbidden, err.Error())
	case errors.Is(err, chains.ErrKeyTaken):
		fail(w, http.StatusConflict, err.Error())
	case errors.Is(err, verify.ErrStatement), errors.Is(err, verify.ErrSignature), errors.Is(err, verify.ErrForkedChain),
		errors.Is(err, verify.ErrOlderChain):
		fail(w, http.StatusConflict, err.Error())
	default:
		a.Log.Error("sign api", "path", r.URL.Path, "err", err)
		fail(w, http.StatusInternalServerError, "internal error")
	}
}

var errBadRequest = errors.New("not the JSON this call takes")

func readJSON(r *http.Request, v any) error {
	b, err := io.ReadAll(r.Body)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v, json.RejectUnknownMembers(true)); err != nil {
		return errBadRequest
	}
	return nil
}

func (a *API) addr(r *http.Request) string {
	if a.ClientAddr != nil {
		return a.ClientAddr(r)
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func (a *API) login(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Code string `json:"code"`
	}
	if err := readJSON(r, &in); err != nil {
		a.failErr(w, r, err)
		return
	}
	tok, _, expires, err := a.Auth.ExchangeSignCode(r.Context(), a.addr(r), in.Code)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Token   string    `json:"token"`
		Expires time.Time `json:"expires"`
	}{tok, expires})
}

func (a *API) time(w http.ResponseWriter, r *http.Request) {
	out(w, http.StatusOK, struct {
		Now time.Time `json:"now"`
	}{a.Auth.Now().UTC()})
}

type authedHandler func(w http.ResponseWriter, r *http.Request, accountID string)

func (a *API) authed(h authedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || tok == "" {
			fail(w, http.StatusUnauthorized, "no token")
			return
		}
		account, err := a.Auth.LookupSignToken(r.Context(), tok)
		if err != nil {
			a.failErr(w, r, err)
			return
		}
		h(w, r, account)
	}
}

// Company is a company as wmanager-sign lists it.
type Company struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Role        string `json:"role"`
	Fingerprint string `json:"fingerprint,omitzero"`
}

func (a *API) me(w http.ResponseWriter, r *http.Request, account string) {
	cs, err := accounts.CompaniesOf(r.Context(), a.Store, account)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	list := []Company{}
	for _, c := range cs {
		item := Company{ID: c.ID, Name: c.Name, Role: c.Role}
		if sum, err := chains.Summarize(r.Context(), a.Store, account, c.ID); err == nil && sum != nil {
			item.Fingerprint = sum.Fingerprint
		}
		list = append(list, item)
	}
	out(w, http.StatusOK, struct {
		Companies []Company `json:"companies"`
	}{list})
}

func (a *API) chain(w http.ResponseWriter, r *http.Request, account string) {
	lists, err := chains.Load(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if lists == nil {
		lists = []verify.Signed{}
	}
	out(w, http.StatusOK, struct {
		Lists []verify.Signed `json:"lists"`
	}{lists})
}

func (a *API) appendList(w http.ResponseWriter, r *http.Request, account string) {
	var next verify.Signed
	if err := readJSON(r, &next); err != nil {
		a.failErr(w, r, err)
		return
	}
	c, err := chains.Append(r.Context(), a.Store, account, r.PathValue("company"), next)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Fingerprint string `json:"fingerprint"`
		Sequence    int64  `json:"sequence"`
	}{verify.Fingerprint(c.Company), c.Current().Sequence})
}

func (a *API) registerKey(w http.ResponseWriter, r *http.Request, account string) {
	var in struct {
		COSE []byte `json:"cose"`
	}
	if err := readJSON(r, &in); err != nil {
		a.failErr(w, r, err)
		return
	}
	id, err := chains.RegisterKey(r.Context(), a.Store, account, in.COSE)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		ID string `json:"id"`
	}{id})
}

func (a *API) companyKeys(w http.ResponseWriter, r *http.Request, account string) {
	keys, err := chains.CompanyKeys(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if keys == nil {
		keys = []chains.Key{}
	}
	out(w, http.StatusOK, struct {
		Keys []chains.Key `json:"keys"`
	}{keys})
}
