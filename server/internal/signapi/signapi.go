// Package signapi is the API wmanager-sign talks to (stage 2b): signing in with a code from the panel, the server's
// clock (wmanager-sign signs only when its own is within 10 minutes of it), the companies, their chains of admin
// lists, and the signing keys people register. It hands out and takes signed statements; it signs nothing.
package signapi

import (
	"context"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/chains"
	"github.com/lechup/wmanager/server/internal/statements"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/verify"
)

// Prefix is where the API lives.
const Prefix = "/api/sign/v1/"

// MaxBody is the largest request: an admin list's limit and its signature, with room. A state may be larger:
// MaxStateBody, its limit in base64 with the secrets given with it.
const (
	MaxBody      = 512 << 10
	MaxStateBody = 16 << 20
	MaxJobBody   = 2 << 20 // a job or a stop: 1 MiB at most, in base64
)

// API is the sign API.
type API struct {
	Store *store.Store
	Auth  *auth.Service
	Log   *slog.Logger
	// ClientAddr gives the client's address (the panel's, which knows the trusted proxies).
	ClientAddr func(*http.Request) string
	// PublicURL gives the server's address (WMANAGER_PUBLIC_URL), which key proofs name; "" refuses them.
	PublicURL func() string
	// FilesDir gives the folder of the files added with add-file (WMANAGER_FILES_DIR); "" refuses them.
	FilesDir func() string
	// Notify, when set, is told of each company that has a new admin list, state, job or stop: it wakes the
	// company's computers' long polls.
	Notify func(company string)
}

func (a *API) notify(company string) {
	if a.Notify != nil {
		a.Notify(company)
	}
}

var errNoPublicURL = errors.New("registering keys and taking states needs WMANAGER_PUBLIC_URL")

const (
	statesRoute = "POST " + Prefix + "companies/{company}/states"
	jobsRoute   = "POST " + Prefix + "companies/{company}/jobs"
	stopsRoute  = "POST " + Prefix + "companies/{company}/stops"
	storeRoute  = "PUT " + Prefix + "companies/{company}/files/{hash}"
)

// Handler is the API's routes, every answer JSON.
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST "+Prefix+"login", a.login)
	mux.HandleFunc("GET "+Prefix+"time", a.time)
	mux.HandleFunc("GET "+Prefix+"me", a.authed(a.me))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/chain", a.authed(a.company(a.chain)))
	mux.HandleFunc("POST "+Prefix+"companies/{company}/chain", a.authed(a.company(a.appendList)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/keys", a.authed(a.company(a.companyKeys)))
	mux.HandleFunc("POST "+Prefix+"keys", a.authed(a.registerKey))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/drafts", a.authed(a.company(a.drafts)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/drafts/{draft}", a.authed(a.company(a.draft)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/files/{hash}", a.authed(a.company(a.file)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/state", a.authed(a.company(a.state)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/secrets", a.authed(a.company(a.secretHashes)))
	mux.HandleFunc(statesRoute, a.authed(a.company(a.submitState)))
	mux.HandleFunc(storeRoute, a.authed(a.company(a.storeFile)))
	mux.HandleFunc(jobsRoute, a.authed(a.company(a.submitJob)))
	mux.HandleFunc(stopsRoute, a.authed(a.company(a.submitStop)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/jobs", a.authed(a.company(a.jobs)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/jobs/{job}", a.authed(a.company(a.job)))
	mux.HandleFunc("GET "+Prefix+"companies/{company}/audit", a.authed(a.company(a.auditAfter)))
	cop := http.NewCrossOriginProtection()
	cop.SetDenyHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fail(w, http.StatusForbidden, "cross-origin request")
	}))
	return cop.Handler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		_, pattern := mux.Handler(r)
		if pattern == "" {
			fail(w, http.StatusNotFound, "no such call")
			return
		}
		limit := int64(MaxBody)
		switch pattern {
		case statesRoute:
			limit = MaxStateBody
		case jobsRoute, stopsRoute:
			limit = MaxJobBody
		case storeRoute:
			limit = statements.MaxStored
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		mux.ServeHTTP(w, r)
	}))
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

var errBadRequest = errors.New("not the JSON this call takes")

func (a *API) failErr(w http.ResponseWriter, r *http.Request, err error) {
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		fail(w, http.StatusRequestEntityTooLarge, "too large")
	case errors.Is(err, errBadRequest):
		fail(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, errNoPublicURL):
		fail(w, http.StatusServiceUnavailable, err.Error())
	case errors.Is(err, verify.ErrKeyProof):
		fail(w, http.StatusBadRequest, "not a signing key with a proof for this account")
	case errors.Is(err, auth.ErrSignCode), errors.Is(err, auth.ErrSignToken):
		fail(w, http.StatusUnauthorized, err.Error())
	case errors.Is(err, auth.ErrTooMany):
		fail(w, http.StatusTooManyRequests, err.Error())
	case errors.Is(err, chains.ErrNotAdmin), errors.Is(err, chains.ErrNotMember):
		fail(w, http.StatusForbidden, err.Error())
	case errors.Is(err, chains.ErrKeyTaken), errors.Is(err, chains.ErrTooManyKeys), errors.Is(err, chains.ErrTaken):
		fail(w, http.StatusConflict, err.Error())
	case errors.Is(err, statements.ErrNoStore), errors.Is(err, statements.ErrBusy):
		fail(w, http.StatusServiceUnavailable, err.Error())
	case errors.Is(err, statements.ErrQuota):
		fail(w, http.StatusInsufficientStorage, err.Error())
	case errors.Is(err, statements.ErrBadDraft), errors.Is(err, statements.ErrBadSecret), errors.Is(err, statements.ErrFileHash):
		fail(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, statements.ErrNoFile), errors.Is(err, statements.ErrNoDraft), errors.Is(err, statements.ErrNoJob):
		fail(w, http.StatusNotFound, err.Error())
	case errors.Is(err, statements.ErrTooLarge):
		fail(w, http.StatusRequestEntityTooLarge, err.Error())
	case errors.Is(err, statements.ErrNoChain), errors.Is(err, statements.ErrMissing), errors.Is(err, statements.ErrNewer),
		errors.Is(err, statements.ErrWrongPlace), errors.Is(err, statements.ErrTooMany), errors.Is(err, statements.ErrJobTaken),
		errors.Is(err, statements.ErrSame):
		fail(w, http.StatusConflict, err.Error())
	case errors.Is(err, chains.ErrBroken):
		a.Log.Error("sign api: a stored chain doesn't check", "path", r.URL.Path, "err", err)
		fail(w, http.StatusConflict, err.Error())
	case errors.Is(err, verify.ErrStatement), errors.Is(err, verify.ErrSignature), errors.Is(err, verify.ErrForkedChain),
		errors.Is(err, verify.ErrOlderChain):
		fail(w, http.StatusConflict, err.Error())
	default:
		a.Log.Error("sign api", "path", r.URL.Path, "err", err)
		fail(w, http.StatusInternalServerError, "internal error")
	}
}

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
	tok, account, expires, err := a.Auth.ExchangeSignCode(r.Context(), a.addr(r), in.Code)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Token   string    `json:"token"`
		Account string    `json:"account"`
		Expires time.Time `json:"expires"`
	}{tok, account, expires})
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

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// company refuses a company id that isn't one, as the panel does.
func (a *API) company(h authedHandler) authedHandler {
	return func(w http.ResponseWriter, r *http.Request, account string) {
		if !uuidRe.MatchString(r.PathValue("company")) {
			fail(w, http.StatusNotFound, "no such company")
			return
		}
		h(w, r, account)
	}
}

// Company is a company as wmanager-sign lists it. Its fingerprint is the server's word only: wmanager-sign checks
// the chain against the fingerprint it keeps.
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
		fp, err := chains.Fingerprint(r.Context(), a.Store, account, c.ID)
		if err != nil {
			a.failErr(w, r, err)
			return
		}
		list = append(list, Company{ID: c.ID, Name: c.Name, Role: c.Role, Fingerprint: fp})
	}
	out(w, http.StatusOK, struct {
		Account   string    `json:"account"`
		Companies []Company `json:"companies"`
	}{account, list})
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
	a.notify(r.PathValue("company"))
	out(w, http.StatusOK, struct {
		Fingerprint string `json:"fingerprint"`
		Sequence    int64  `json:"sequence"`
	}{verify.Fingerprint(c.Company), c.Current().Sequence})
}

// registerKey takes a new signing key with its proof (verify.MakeKeyProof for this server and account, at the
// server's time, signed by the key).
func (a *API) registerKey(w http.ResponseWriter, r *http.Request, account string) {
	var in struct {
		COSE  []byte        `json:"cose"`
		Proof verify.Signed `json:"proof"`
	}
	if err := readJSON(r, &in); err != nil {
		a.failErr(w, r, err)
		return
	}
	server := ""
	if a.PublicURL != nil {
		server = strings.TrimSuffix(a.PublicURL(), "/")
	}
	if server == "" {
		a.failErr(w, r, errNoPublicURL)
		return
	}
	id, err := chains.RegisterKey(r.Context(), a.Store, server, account, in.COSE, in.Proof, a.Auth.Now())
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

func (a *API) drafts(w http.ResponseWriter, r *http.Request, account string) {
	ds, err := statements.Drafts(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if ds == nil {
		ds = []statements.Draft{}
	}
	out(w, http.StatusOK, struct {
		Drafts []statements.Draft `json:"drafts"`
	}{ds})
}

// draft is one waiting draft, whole.
func (a *API) draft(w http.ResponseWriter, r *http.Request, account string) {
	if !uuidRe.MatchString(r.PathValue("draft")) {
		a.failErr(w, r, statements.ErrNoDraft)
		return
	}
	d, err := statements.DraftBody(r.Context(), a.Store, account, r.PathValue("company"), r.PathValue("draft"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, d)
}

var hashRe = regexp.MustCompile(`^[0-9a-f]{64}$`)

// file is a file of the company by its hash; wmanager-sign hashes what it gets again.
func (a *API) file(w http.ResponseWriter, r *http.Request, account string) {
	if !hashRe.MatchString(r.PathValue("hash")) {
		fail(w, http.StatusNotFound, "no such file")
		return
	}
	var h [32]byte
	hex.Decode(h[:], []byte(r.PathValue("hash")))
	content, err := statements.File(r.Context(), a.Store, account, r.PathValue("company"), h)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Content []byte `json:"content"`
	}{content})
}

// state is the company's newest signed state, and the highest serial its computers report (none before stage 3).
func (a *API) state(w http.ResponseWriter, r *http.Request, account string) {
	st, err := statements.NewestState(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		State    *verify.Signed `json:"state"`
		Reported int64          `json:"reported"`
	}{st, 0})
}

// submitState takes a signed state, with the draft it was signed from and the secrets' values typed for it.
func (a *API) submitState(w http.ResponseWriter, r *http.Request, account string) {
	var in struct {
		Signed  verify.Signed       `json:"signed"`
		Draft   string              `json:"draft"`
		Secrets []statements.Secret `json:"secrets"`
	}
	if err := readJSON(r, &in); err != nil {
		a.failErr(w, r, err)
		return
	}
	if in.Draft != "" && !uuidRe.MatchString(in.Draft) {
		a.failErr(w, r, statements.ErrNoDraft)
		return
	}
	server := ""
	if a.PublicURL != nil {
		server = strings.TrimSuffix(a.PublicURL(), "/")
	}
	if server == "" {
		a.failErr(w, r, errNoPublicURL)
		return
	}
	serial, err := statements.SubmitState(r.Context(), a.Store, server, account, r.PathValue("company"), in.Signed, in.Draft, in.Secrets)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	a.notify(r.PathValue("company"))
	out(w, http.StatusOK, struct {
		Serial int64 `json:"serial"`
	}{serial})
}

// signedIn is what POST jobs and stops take: the statement, and the draft it was signed from.
type signedIn struct {
	Signed verify.Signed `json:"signed"`
	Draft  string        `json:"draft"`
}

func (a *API) submitOne(w http.ResponseWriter, r *http.Request, account string,
	submit func(ctx context.Context, s *store.Store, accountID, companyID string, signed verify.Signed, draftID string) error) {
	var in signedIn
	if err := readJSON(r, &in); err != nil {
		a.failErr(w, r, err)
		return
	}
	if in.Draft != "" && !uuidRe.MatchString(in.Draft) {
		a.failErr(w, r, statements.ErrNoDraft)
		return
	}
	if err := submit(r.Context(), a.Store, account, r.PathValue("company"), in.Signed, in.Draft); err != nil {
		a.failErr(w, r, err)
		return
	}
	a.notify(r.PathValue("company"))
	out(w, http.StatusOK, struct{}{})
}

func (a *API) submitJob(w http.ResponseWriter, r *http.Request, account string) {
	a.submitOne(w, r, account, statements.SubmitJob)
}

func (a *API) submitStop(w http.ResponseWriter, r *http.Request, account string) {
	a.submitOne(w, r, account, statements.SubmitStop)
}

// jobs is the company's newest signed jobs.
func (a *API) jobs(w http.ResponseWriter, r *http.Request, account string) {
	js, err := statements.Jobs(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if js == nil {
		js = []verify.Signed{}
	}
	out(w, http.StatusOK, struct {
		Jobs []verify.Signed `json:"jobs"`
	}{js})
}

// secretHashes is which secrets' values the server has: their names and hashes, never the values.
func (a *API) secretHashes(w http.ResponseWriter, r *http.Request, account string) {
	hs, err := statements.SecretHashes(r.Context(), a.Store, account, r.PathValue("company"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if hs == nil {
		hs = []statements.SecretHash{}
	}
	out(w, http.StatusOK, struct {
		Secrets []statements.SecretHash `json:"secrets"`
	}{hs})
}

// auditAfter is the company's audit entries after ?after=, as stored, for wmanager-sign to link from the head it
// saw last: it checks them, not the server.
func (a *API) auditAfter(w http.ResponseWriter, r *http.Request, account string) {
	after, err := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)
	if err != nil || after < 0 {
		fail(w, http.StatusBadRequest, "after is the number of an entry")
		return
	}
	company := r.PathValue("company")
	if err := statements.Member(r.Context(), a.Store, account, company); err != nil {
		a.failErr(w, r, err)
		return
	}
	entries, err := audit.After(r.Context(), a.Store, store.Who{Account: account}, audit.CompanyChain(company), after)
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	if entries == nil {
		entries = [][]byte{}
	}
	out(w, http.StatusOK, struct {
		Entries [][]byte `json:"entries"`
	}{entries})
}

var jobIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

// job is one signed job by its id: wmanager-sign checks its signature before it shows it.
func (a *API) job(w http.ResponseWriter, r *http.Request, account string) {
	if !jobIDRe.MatchString(r.PathValue("job")) {
		a.failErr(w, r, statements.ErrNoJob)
		return
	}
	j, err := statements.Job(r.Context(), a.Store, account, r.PathValue("company"), r.PathValue("job"))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, j)
}

// storeFile takes a file added with wmanager-sign add-file: its bytes as the request's body, checked against the
// hash in its path, kept on disk.
func (a *API) storeFile(w http.ResponseWriter, r *http.Request, account string) {
	if !hashRe.MatchString(r.PathValue("hash")) {
		fail(w, http.StatusNotFound, "no such file")
		return
	}
	var h [32]byte
	hex.Decode(h[:], []byte(r.PathValue("hash")))
	dir := ""
	if a.FilesDir != nil {
		dir = a.FilesDir()
	}
	// A large file arrives for longer than the server's read and write timeouts allow a request: they are moved
	// on while it keeps coming, at least UploadPace bytes in each UploadIdle.
	rc := http.NewResponseController(w)
	rc.SetReadDeadline(time.Now().Add(UploadIdle))
	body := &paced{r: r.Body, rc: rc}
	n, err := statements.StoreFile(r.Context(), a.Store, dir, account, r.PathValue("company"), h, r.ContentLength, body)
	rc.SetWriteDeadline(time.Now().Add(UploadIdle))
	if err != nil {
		a.failErr(w, r, err)
		return
	}
	out(w, http.StatusOK, struct {
		Size int64 `json:"size"`
	}{n})
}

// An upload must bring at least UploadPace bytes in each UploadIdle, or the connection's deadline ends it.
const (
	UploadIdle = time.Minute
	UploadPace = 1 << 20
)

// paced moves the connection's read deadline on each time UploadPace more bytes have come.
type paced struct {
	r    io.Reader
	rc   *http.ResponseController
	read int64
}

func (p *paced) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	p.read += int64(n)
	if p.read >= UploadPace {
		p.read = 0
		p.rc.SetReadDeadline(time.Now().Add(UploadIdle))
	}
	return n, err
}
