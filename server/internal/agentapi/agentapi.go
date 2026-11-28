// Package agentapi is the API wmanager-agent talks to (docs/agent.md): enrolling a computer with a token, and its
// long poll for its company's admin lists and newest state. Every request after enrolling is signed with the
// computer's key and checked here; what the computer acts on, it checks itself.
package agentapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json/v2"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/computers"
	"github.com/lechup/wmanager/server/internal/notify"
	"github.com/lechup/wmanager/server/internal/statements"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Prefix is where the API lives.
const Prefix = "/api/agent/v1/"

// Limits.
const (
	MaxBody    = 16 << 10
	RequestAge = 5 * time.Minute
	PollFor    = 50 * time.Second
)

// API is the agent API.
type API struct {
	Store      *store.Store
	Auth       *auth.Service // its clock, and its limit of attempts per address
	Log        *slog.Logger
	Hub        *notify.Hub
	ClientAddr func(*http.Request) string
	PublicURL  func() string
	// PollFor gives how long a poll waits for news (PollFor when nil or 0).
	PollFor func() time.Duration

	mu   sync.Mutex
	seen map[[32]byte]time.Time // signatures taken, for RequestAge each
}

// Handler is the API's routes.
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST "+Prefix+"enroll", a.enroll)
	mux.HandleFunc("GET "+Prefix+"poll", a.signed(a.poll))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if _, pattern := mux.Handler(r); pattern == "" {
			fail(w, http.StatusNotFound, "no such call")
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
		mux.ServeHTTP(w, r)
	})
}

func out(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.MarshalWrite(w, v)
}

func fail(w http.ResponseWriter, status int, msg string) {
	out(w, status, struct {
		Error string `json:"error"`
	}{msg})
}

func (a *API) addr(r *http.Request) string {
	if a.ClientAddr != nil {
		return a.ClientAddr(r)
	}
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	return host
}

func (a *API) failErr(w http.ResponseWriter, r *http.Request, err error) {
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		fail(w, http.StatusRequestEntityTooLarge, "too large")
	case errors.Is(err, auth.ErrTooMany):
		fail(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, computers.ErrToken), errors.Is(err, computers.ErrProof):
		fail(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, computers.ErrKey), errors.Is(err, computers.ErrName):
		fail(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, computers.ErrOtherCompany):
		fail(w, http.StatusConflict, err.Error())
	default:
		a.Log.Error("agent api", "path", r.URL.Path, "err", err)
		fail(w, http.StatusInternalServerError, "internal error")
	}
}

func (a *API) server() string {
	if a.PublicURL == nil {
		return ""
	}
	return strings.TrimSuffix(a.PublicURL(), "/")
}

// enroll takes a computer's key with an enrollment token.
func (a *API) enroll(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Token     string    `json:"token"`
		PublicKey []byte    `json:"public_key"`
		Name      string    `json:"name"`
		Time      time.Time `json:"time"`
		Proof     []byte    `json:"proof"`
	}
	b, err := io.ReadAll(r.Body)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if err := json.Unmarshal(b, &in, json.RejectUnknownMembers(true)); err != nil {
		fail(w, http.StatusBadRequest, "not the JSON this call takes")
		return
	}
	if err := a.Auth.Allow(a.addr(r)); err != nil {
		a.failErr(w, r, err)
		return
	}
	if a.server() == "" {
		fail(w, http.StatusServiceUnavailable, "enrolling needs WMANAGER_PUBLIC_URL")
		return
	}
	c, err := computers.Enroll(r.Context(), a.Store, a.server(), in.Token, in.PublicKey, in.Name, in.Time, a.Auth.Now(), in.Proof)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Computer string `json:"computer"`
		Company  string `json:"company"`
	}{c.ID, c.Company})
}

type signedHandler func(w http.ResponseWriter, r *http.Request, c computers.Computer)

// errSignature is a request whose signature doesn't check: one answer for every reason.
const errSignature = "the request's signature is not a computer's, or not of now"

// signed checks a request's signature: an enrolled computer's key, over this request, within RequestAge, once.
func (a *API) signed(h signedHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id, at, sig, ok := parseAuthorization(r.Header.Get("Authorization"))
		if !ok {
			fail(w, http.StatusUnauthorized, errSignature)
			return
		}
		t, err := time.Parse(time.RFC3339Nano, at)
		now := a.Auth.Now()
		if err != nil || t.Sub(now).Abs() > RequestAge {
			fail(w, http.StatusUnauthorized, errSignature)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			a.failErr(w, r, err)
			return
		}
		c, err := computers.Lookup(r.Context(), a.Store, id)
		if errors.Is(err, computers.ErrNoComputer) {
			fail(w, http.StatusUnauthorized, errSignature)
			return
		}
		if err != nil {
			a.failErr(w, r, err)
			return
		}
		d := computers.RequestDigest(r.Method, r.URL.RequestURI(), at, body)
		if !ecdsa.VerifyASN1(c.Key, d[:], sig) || !a.once(sig, now) {
			fail(w, http.StatusUnauthorized, errSignature)
			return
		}
		if err := computers.Contact(r.Context(), a.Store, c.ID, a.addr(r), now); err != nil {
			a.Log.Error("agent api: last contact", "err", err)
		}
		h(w, r, c)
	}
}

// once takes a signature the first time it is seen within RequestAge: a request can't be sent again.
func (a *API) once(sig []byte, now time.Time) bool {
	h := sha256.Sum256(sig)
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.seen == nil {
		a.seen = map[[32]byte]time.Time{}
	}
	if len(a.seen) > 1000 {
		for k, t := range a.seen {
			if now.Sub(t) > 2*RequestAge {
				delete(a.seen, k)
			}
		}
	}
	if _, ok := a.seen[h]; ok {
		return false
	}
	a.seen[h] = now
	return true
}

// parseAuthorization reads "WM-Agent id=..., time=..., sig=...".
func parseAuthorization(h string) (id, at string, sig []byte, ok bool) {
	rest, found := strings.CutPrefix(h, "WM-Agent ")
	if !found {
		return "", "", nil, false
	}
	var sigText string
	for _, part := range strings.Split(rest, ",") {
		k, v, found := strings.Cut(strings.TrimSpace(part), "=")
		if !found {
			return "", "", nil, false
		}
		switch k {
		case "id":
			id = v
		case "time":
			at = v
		case "sig":
			sigText = v
		default:
			return "", "", nil, false
		}
	}
	sig, err := base64.StdEncoding.DecodeString(sigText)
	if err != nil || len(id) != 64 || at == "" || len(sig) == 0 || len(sig) > 80 {
		return "", "", nil, false
	}
	return id, at, sig, true
}

// news is what a poll answers: the admin lists after those held, and a newer state.
type news struct {
	Lists []verify.Signed `json:"lists"`
	State *verify.Signed  `json:"state"`
	Time  time.Time       `json:"time"`
}

func (a *API) news(ctx context.Context, company string, lists int, serial int64) (news, bool, error) {
	n := news{Lists: []verify.Signed{}}
	stored, err := chains.Stored(ctx, a.Store, company)
	if err != nil {
		return n, false, err
	}
	if lists < len(stored) {
		n.Lists = stored[lists:]
	}
	st, s, err := statements.NewestOf(ctx, a.Store, company)
	if err != nil {
		return n, false, err
	}
	if st != nil && s > serial {
		n.State = st
	}
	return n, len(n.Lists) > 0 || n.State != nil, nil
}

// poll answers at once with news for the computer's company, or after PollFor with nothing new.
func (a *API) poll(w http.ResponseWriter, r *http.Request, c computers.Computer) {
	q := r.URL.Query()
	lists, err1 := strconv.Atoi(q.Get("lists"))
	serial, err2 := strconv.ParseInt(q.Get("serial"), 10, 64)
	if err1 != nil || err2 != nil || lists < 0 || serial < 0 {
		fail(w, http.StatusBadRequest, "lists and serial are numbers")
		return
	}
	wake, cancel := a.Hub.Subscribe(c.Company)
	defer cancel()
	wait := PollFor
	if a.PollFor != nil && a.PollFor() > 0 {
		wait = a.PollFor()
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	for {
		n, any, err := a.news(r.Context(), c.Company, lists, serial)
		if err != nil {
			a.failErr(w, r, err)
			return
		}
		if any {
			n.Time = a.Auth.Now().UTC()
			out(w, http.StatusOK, n)
			return
		}
		select {
		case <-wake:
		case <-timer.C:
			n.Time = a.Auth.Now().UTC()
			out(w, http.StatusOK, n)
			return
		case <-r.Context().Done():
			return
		}
	}
}
