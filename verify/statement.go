package verify

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json/jsontext"
	"encoding/json/v2"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
	"unicode"
)

// Format is the version of the statements' format this code reads.
const Format = 1

// The types of statements (docs/architecture.md, "Signed statements").
const (
	TypeAdmins  = "admins"
	TypeState   = "state"
	TypeJob     = "job"
	TypeStop    = "stop"
	TypeSession = "session"
)

// ErrStatement is returned for a statement that doesn't pass check 1, 2 or 6: its form, its company, or how it
// fits what came before. Its message says which.
var ErrStatement = errors.New("statement refused")

func bad(format string, args ...any) error {
	return fmt.Errorf("%w: %s", ErrStatement, fmt.Sprintf(format, args...))
}

// Signed is a statement as it travels: its exact bytes, the id of the key that signed them, and the FIDO2
// assertion over their SHA-256. Nothing is put into a canonical form: the hash is of these bytes.
type Signed struct {
	Statement         []byte `json:"statement"`
	Key               string `json:"key"`
	AuthenticatorData []byte `json:"authenticator_data"`
	ClientDataJSON    []byte `json:"client_data_json"`
	Signature         []byte `json:"signature"`
}

// Hash is the SHA-256 of the statement's bytes: what the key signs and what later versions name.
func (s Signed) Hash() [32]byte { return sha256.Sum256(s.Statement) }

func (s Signed) assertion() Assertion {
	return Assertion{AuthenticatorData: s.AuthenticatorData, ClientDataJSON: s.ClientDataJSON, Signature: s.Signature}
}

// Key is a signing key as a list names it: its id (the SHA-256 of its COSE form, in hex) and its COSE form,
// which holds its algorithm too.
type Key struct {
	ID   string `json:"id"`
	COSE []byte `json:"cose"`
}

// KeyID is a key's id: the SHA-256 of its COSE form, in hex. Its first 128 bits are the fingerprint typed when
// the key is added (docs/architecture.md).
func KeyID(cose []byte) string {
	h := sha256.Sum256(cose)
	return hex.EncodeToString(h[:])
}

// Fingerprint is the first 128 bits of a hash in 8 groups of 4 hex characters, as people read and type it.
func Fingerprint(h [32]byte) string {
	s := strings.ToUpper(hex.EncodeToString(h[:16]))
	var g []string
	for i := 0; i < len(s); i += 4 {
		g = append(g, s[i:i+4])
	}
	return strings.Join(g, "-")
}

// MatchesFingerprint compares a hash with a fingerprint as typed: case and dashes or spaces don't matter.
func MatchesFingerprint(h [32]byte, typed string) bool {
	norm := strings.ToUpper(strings.NewReplacer("-", "", " ", "").Replace(strings.TrimSpace(typed)))
	return len(norm) == 32 && norm == strings.ReplaceAll(Fingerprint(h), "-", "")
}

// PublicKey reads a list's key, checking that its id is the hash of its COSE form.
func (k Key) PublicKey() (PublicKey, error) {
	if k.ID != KeyID(k.COSE) {
		return PublicKey{}, bad("key %s: its id is not the hash of its public key", short(k.ID))
	}
	return ParseCOSEKey(k.COSE)
}

// short is the start of a key id for a message; anything that isn't hex shows as "?", so a log gets no raw bytes.
func short(id string) string {
	for _, r := range id {
		if !strings.ContainsRune("0123456789abcdef", r) {
			return "?"
		}
	}
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// header is what every statement starts with.
type header struct {
	Format   int       `json:"format"`
	Type     string    `json:"type"`
	SignedAt time.Time `json:"signed_at"`
}

// MaxSize is the largest statement of each type, checked before anything is read.
var MaxSize = map[string]int{TypeAdmins: 256 << 10, TypeState: 8 << 20, TypeJob: 1 << 20, TypeStop: 1 << 20,
	TypeSession: 16 << 10}

// MaxSerial is the largest serial and sequence: far beyond any real use, and far from where a number would wrap.
// It only keeps numbers sane: what stops a server's inflated report is wmanager-sign refusing a serial far above
// the highest it knows (stage 2b).
const MaxSerial = 1 << 53

// members are the members of each type: all required, unless optional.
var members = map[string]struct{ required, optional []string }{
	TypeAdmins:  {[]string{"format", "type", "signed_at", "sequence", "administrators"}, []string{"company", "nonce", "previous"}},
	TypeState:   {[]string{"format", "type", "signed_at", "company", "serial", "server", "release", "computers", "files", "version", "secrets"}, nil},
	TypeJob:     {[]string{"format", "type", "signed_at", "company", "id", "computers", "script", "run_as", "secrets", "start_after", "expires", "limit"}, nil},
	TypeStop:    {[]string{"format", "type", "signed_at", "company", "job", "computers"}, nil},
	TypeSession: {[]string{"format", "type", "signed_at", "company", "id", "computer", "person", "viewer_key", "may", "open_by", "max_length"}, nil},
}

// checkMembers checks that the top-level object has every required member, only known ones, and no null.
func checkMembers(raw []byte, typ string) error {
	var obj map[string]jsontext.Value
	if err := json.Unmarshal(raw, &obj); err != nil {
		return bad("not a JSON object: %v", err)
	}
	m := members[typ]
	known := map[string]bool{}
	for _, k := range m.required {
		known[k] = true
		v, ok := obj[k]
		if !ok {
			return bad("%s: no %s", typ, k)
		}
		if v.Kind() == 'n' {
			return bad("%s: %s is null", typ, k)
		}
	}
	for _, k := range m.optional {
		known[k] = true
		if v, ok := obj[k]; ok && v.Kind() == 'n' {
			return bad("%s: %s is null", typ, k)
		}
	}
	for k := range obj {
		if !known[k] {
			return bad("%s: unknown member %q", typ, k)
		}
	}
	return nil
}

// decode reads a statement of a type strictly (check 1): its size, known format and type, and exactly the members
// of that type, each once, in its exact case, none null.
func decode(raw []byte, typ string, v any) error {
	if len(raw) > MaxSize[typ] {
		return bad("%s of %d bytes, more than %d", typ, len(raw), MaxSize[typ])
	}
	var h header
	if err := json.Unmarshal(raw, &h); err != nil {
		return bad("not JSON: %v", err)
	}
	if h.Format != Format {
		return bad("format %d, this agent reads %d", h.Format, Format)
	}
	if h.Type != typ {
		return bad("a %q statement where %q was expected", h.Type, typ)
	}
	if err := checkMembers(raw, typ); err != nil {
		return err
	}
	if err := json.Unmarshal(raw, v, json.RejectUnknownMembers(true)); err != nil {
		return bad("%s: %v", typ, err)
	}
	if h.SignedAt.IsZero() {
		return bad("%s: no signed_at", typ)
	}
	return nil
}

// Limits of what a statement holds.
const (
	maxName  = 100
	maxItems = 10000
)

var (
	hex64     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	hex32     = regexp.MustCompile(`^[0-9a-f]{32}$`)
	pathChars = regexp.MustCompile(`^[A-Za-z0-9._/-]+$`)
	groupName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$`)
)

func checkHash(what, s string) error {
	if !hex64.MatchString(s) {
		return bad("%s: not a SHA-256 in lower-case hex", what)
	}
	return nil
}

// checkName refuses a name a screen could show differently from what it is: control characters, bidirectional
// overrides, invisible formatting; wmanager-sign shows the rest.
func checkName(what, s string) error {
	if s == "" || len([]rune(s)) > maxName || strings.TrimSpace(s) != s {
		return bad("%s: 1 to %d characters, no space around", what, maxName)
	}
	for _, r := range s {
		if unicode.IsControl(r) || unicode.In(r, unicode.Cf, unicode.Zl, unicode.Zp, unicode.Co, unicode.Cs) ||
			invisible[r] {
			return bad("%s: a control, formatting or invisible character %U", what, r)
		}
	}
	return nil
}

// invisible are letters that show nothing (Hangul fillers and the like), which a name could hide behind.
var invisible = map[rune]bool{0x115F: true, 0x1160: true, 0x3164: true, 0xFFA0: true, 0x180E: true, 0x2800: true}

// checkPath allows the file paths of the design: letters, digits, - _ . and /, relative, no part "." or "..".
func checkPath(p string) error {
	if !pathChars.MatchString(p) || len(p) > 200 || strings.HasPrefix(p, "/") || strings.HasSuffix(p, "/") {
		return bad("file path %q", p)
	}
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." || part == ".." {
			return bad("file path %q", p)
		}
	}
	return nil
}

func checkKeys(what string, keys []Key, seen map[string]bool) error {
	if len(keys) == 0 || len(keys) > 20 {
		return bad("%s: 1 to 20 keys", what)
	}
	for _, k := range keys {
		if seen[k.ID] {
			return bad("%s: key %s twice", what, short(k.ID))
		}
		seen[k.ID] = true
		pk, err := k.PublicKey()
		if err != nil {
			return bad("%s: %v", what, err)
		}
		if err := CheckKey(pk); err != nil {
			return bad("%s: %v", what, err)
		}
	}
	return nil
}

// --- admins

// Administrator is one administrator of a company with their signing keys.
type Administrator struct {
	Name string `json:"name"`
	Keys []Key  `json:"keys"`
}

// Admins is a version of a company's admin list.
type Admins struct {
	Format         int             `json:"format"`
	Type           string          `json:"type"`
	SignedAt       time.Time       `json:"signed_at"`
	Company        string          `json:"company,omitzero"`  // every version but the first
	Nonce          string          `json:"nonce,omitzero"`    // the first version only: 128 random bits in hex
	Sequence       int64           `json:"sequence"`          // 1, 2, 3...
	Previous       string          `json:"previous,omitzero"` // every version but the first: the hash of the one before
	Administrators []Administrator `json:"administrators"`
}

// ParseAdmins reads an admin list strictly. It doesn't check how it fits the chain: see VerifyChain.
func ParseAdmins(raw []byte) (*Admins, error) {
	var a Admins
	if err := decode(raw, TypeAdmins, &a); err != nil {
		return nil, err
	}
	first := a.Sequence == 1
	switch {
	case a.Sequence < 1 || a.Sequence > MaxSerial:
		return nil, bad("admins: sequence %d", a.Sequence)
	case first && (a.Company != "" || a.Previous != "" || !hex32.MatchString(a.Nonce)):
		return nil, bad("admins: the first version has a nonce and no company or previous")
	case !first && (a.Nonce != "" || checkHash("admins: company", a.Company) != nil || checkHash("admins: previous", a.Previous) != nil):
		return nil, bad("admins: a later version has its company and previous and no nonce")
	case len(a.Administrators) == 0 || len(a.Administrators) > 100:
		return nil, bad("admins: 1 to 100 administrators")
	}
	seen := map[string]bool{}
	names := map[string]bool{}
	for _, ad := range a.Administrators {
		if err := checkName("an administrator's name", ad.Name); err != nil {
			return nil, err
		}
		if names[strings.ToLower(ad.Name)] {
			return nil, bad("admins: the name %q twice", ad.Name)
		}
		names[strings.ToLower(ad.Name)] = true
		if err := checkKeys("administrator "+ad.Name, ad.Keys, seen); err != nil {
			return nil, err
		}
	}
	return &a, nil
}

// keys is the admin list's keys by id, with their administrators' names.
func (a *Admins) keys() map[string]Signer {
	out := map[string]Signer{}
	for _, ad := range a.Administrators {
		for _, k := range ad.Keys {
			if pk, err := k.PublicKey(); err == nil {
				out[k.ID] = Signer{Key: pk, Name: ad.Name}
			}
		}
	}
	return out
}

// --- state

// Computer is a computer of the company: its id (the SHA-256 of its public key, in hex), name and groups.
type Computer struct {
	ID     string   `json:"id"`
	Name   string   `json:"name"`
	Groups []string `json:"groups"`
}

// Version is the wmanager version the state names, with the SHA-256 of each of its files.
type Version struct {
	Name  string            `json:"name"`
	Files map[string]string `json:"files"`
}

// State is a version of a company's state: what its computers have.
type State struct {
	Format   int       `json:"format"`
	Type     string    `json:"type"`
	SignedAt time.Time `json:"signed_at"`
	Company  string    `json:"company"`
	Serial   int64     `json:"serial"`
	Server   string    `json:"server"`  // the server's address (https), so a server can't move the computers
	Release  string    `json:"release"` // the SHA-256 of the release certificate (DER) the agent accepts
	// Computers, by id; a computer is in no group until a state names it.
	Computers []Computer `json:"computers"`
	// Files of the groups (package lists, scripts, jobs, triggers, settings) by path, with their SHA-256.
	Files   map[string]string `json:"files"`
	Version Version           `json:"version"`
	// Secrets by name, each the salted SHA-256 of its value (the salt is kept with the value, not here).
	Secrets map[string]string `json:"secrets"`
}

// ParseState reads a state strictly. The company and the serial are checked against the chain and the last
// state by VerifyState.
func ParseState(raw []byte) (*State, error) {
	var s State
	if err := decode(raw, TypeState, &s); err != nil {
		return nil, err
	}
	if err := checkHash("state: company", s.Company); err != nil {
		return nil, err
	}
	if s.Serial < 1 || s.Serial > MaxSerial {
		return nil, bad("state: serial %d", s.Serial)
	}
	if err := checkServer(s.Server); err != nil {
		return nil, err
	}
	if err := checkHash("state: release", s.Release); err != nil {
		return nil, err
	}
	if len(s.Computers) > maxItems || len(s.Files) > maxItems || len(s.Secrets) > maxItems ||
		len(s.Version.Files) > maxItems {
		return nil, bad("state: too many items")
	}
	ids, names := map[string]bool{}, map[string]bool{}
	for _, c := range s.Computers {
		if err := checkHash("state: a computer's id", c.ID); err != nil {
			return nil, err
		}
		if err := checkName("a computer's name", c.Name); err != nil {
			return nil, err
		}
		if ids[c.ID] || names[strings.ToLower(c.Name)] {
			return nil, bad("state: computer %s twice", c.Name)
		}
		ids[c.ID], names[strings.ToLower(c.Name)] = true, true
		if err := checkNames("state: groups of "+c.Name, c.Groups, 100); err != nil {
			return nil, err
		}
	}
	for p, h := range s.Files {
		if err := checkPath(p); err != nil {
			return nil, err
		}
		if err := checkHash("state: file "+p, h); err != nil {
			return nil, err
		}
	}
	if err := checkName("state: version", s.Version.Name); err != nil {
		return nil, err
	}
	for p, h := range s.Version.Files {
		if err := checkPath(p); err != nil {
			return nil, err
		}
		if err := checkHash("state: version file "+p, h); err != nil {
			return nil, err
		}
	}
	for n, h := range s.Secrets {
		if !groupName.MatchString(n) {
			return nil, bad("state: secret name %q", n)
		}
		if err := checkHash("state: secret "+n, h); err != nil {
			return nil, err
		}
	}
	return &s, nil
}

// --- job, stop, session: their forms and signatures here; when they may run is stage 5 (jobs) and v2 (sessions)

// Job is a single job (docs/architecture.md, "Single jobs").
type Job struct {
	Format     int       `json:"format"`
	Type       string    `json:"type"`
	SignedAt   time.Time `json:"signed_at"`
	Company    string    `json:"company"`
	ID         string    `json:"id"`        // 128 random bits in hex, made in wmanager-sign
	Computers  []string  `json:"computers"` // their ids: a group is resolved when the job is signed
	Script     string    `json:"script"`    // the script's SHA-256
	RunAs      string    `json:"run_as"`    // "system" or "user"
	Secrets    []string  `json:"secrets"`
	StartAfter time.Time `json:"start_after"`
	Expires    time.Time `json:"expires"` // at most 7 days after signing
	Limit      int64     `json:"limit"`   // seconds the script may run
}

// MaxJobLife is how long after signing a job may be valid.
const MaxJobLife = 7 * 24 * time.Hour

// ParseJob reads a job strictly.
func ParseJob(raw []byte) (*Job, error) {
	var j Job
	if err := decode(raw, TypeJob, &j); err != nil {
		return nil, err
	}
	if err := checkHash("job: company", j.Company); err != nil {
		return nil, err
	}
	if !hex32.MatchString(j.ID) {
		return nil, bad("job: id")
	}
	if len(j.Computers) == 0 || len(j.Computers) > maxItems {
		return nil, bad("job: 1 to %d computers", maxItems)
	}
	seen := map[string]bool{}
	for _, c := range j.Computers {
		if err := checkHash("job: a computer", c); err != nil || seen[c] {
			return nil, bad("job: a computer's id, or one twice")
		}
		seen[c] = true
	}
	if err := checkHash("job: script", j.Script); err != nil {
		return nil, err
	}
	if j.RunAs != "system" && j.RunAs != "user" {
		return nil, bad("job: run_as %q", j.RunAs)
	}
	if err := checkNames("job: secrets", j.Secrets, 100); err != nil {
		return nil, err
	}
	switch {
	case !j.Expires.After(j.StartAfter) || !j.Expires.After(j.SignedAt):
		return nil, bad("job: it expires before it may start, or before it was signed")
	case j.Expires.Sub(j.SignedAt) > MaxJobLife:
		return nil, bad("job: valid for more than %v after signing", MaxJobLife)
	case j.Limit < 1 || j.Limit > int64((24*time.Hour).Seconds()):
		return nil, bad("job: limit of %d seconds", j.Limit)
	}
	return &j, nil
}

// Stop stops a running job, or refuses it when it comes later.
type Stop struct {
	Format    int       `json:"format"`
	Type      string    `json:"type"`
	SignedAt  time.Time `json:"signed_at"`
	Company   string    `json:"company"`
	Job       string    `json:"job"`
	Computers []string  `json:"computers"`
}

// ParseStop reads a stop strictly.
func ParseStop(raw []byte) (*Stop, error) {
	var s Stop
	if err := decode(raw, TypeStop, &s); err != nil {
		return nil, err
	}
	if err := checkHash("stop: company", s.Company); err != nil {
		return nil, err
	}
	if !hex32.MatchString(s.Job) || len(s.Computers) == 0 || len(s.Computers) > maxItems {
		return nil, bad("stop: a job's id and 1 to %d computers", maxItems)
	}
	seen := map[string]bool{}
	for _, c := range s.Computers {
		if err := checkHash("stop: a computer", c); err != nil {
			return nil, err
		}
		if seen[c] {
			return nil, bad("stop: a computer twice")
		}
		seen[c] = true
	}
	return &s, nil
}

// Session allows one remote support session (v2, docs/architecture.md "Remote support").
type Session struct {
	Format    int       `json:"format"`
	Type      string    `json:"type"`
	SignedAt  time.Time `json:"signed_at"`
	Company   string    `json:"company"`
	ID        string    `json:"id"`
	Computer  string    `json:"computer"`
	Person    string    `json:"person"`     // the name the admin list (or the state) gives the key that signs it
	ViewerKey []byte    `json:"viewer_key"` // the public key the viewer made for this session
	May       []string  `json:"may"`        // "screen", "keyboard", "files", "privacy"
	OpenBy    time.Time `json:"open_by"`
	MaxLength int64     `json:"max_length"` // seconds
}

// ParseSession reads a session strictly.
func ParseSession(raw []byte) (*Session, error) {
	var s Session
	if err := decode(raw, TypeSession, &s); err != nil {
		return nil, err
	}
	if err := checkHash("session: company", s.Company); err != nil {
		return nil, err
	}
	if !hex32.MatchString(s.ID) {
		return nil, bad("session: id")
	}
	if err := checkHash("session: computer", s.Computer); err != nil {
		return nil, err
	}
	if err := checkName("session: person", s.Person); err != nil {
		return nil, err
	}
	if len(s.ViewerKey) == 0 || len(s.ViewerKey) > 1024 {
		return nil, bad("session: viewer key")
	}
	allowed := map[string]bool{"screen": true, "keyboard": true, "files": true, "privacy": true}
	seen := map[string]bool{}
	for _, m := range s.May {
		if !allowed[m] || seen[m] {
			return nil, bad("session: may %q", m)
		}
		seen[m] = true
	}
	if !s.OpenBy.After(s.SignedAt) || s.OpenBy.Sub(s.SignedAt) > 15*time.Minute {
		return nil, bad("session: open_by within 15 minutes of signing")
	}
	if s.MaxLength < 60 || s.MaxLength > int64((12*time.Hour).Seconds()) {
		return nil, bad("session: max_length of %d seconds", s.MaxLength)
	}
	return &s, nil
}

// Marshal writes a statement's bytes, as wmanager-sign does before it signs them.
func Marshal(v any) ([]byte, error) {
	return json.Marshal(v, json.Deterministic(true), jsontext.EscapeForHTML(false))
}

// checkNames checks a list of group or secret names: each well formed, each once, at most max.
func checkNames(what string, names []string, max int) error {
	if len(names) > max {
		return bad("%s: more than %d", what, max)
	}
	seen := map[string]bool{}
	for _, n := range names {
		if !groupName.MatchString(n) || seen[n] {
			return bad("%s: %q bad or twice", what, n)
		}
		seen[n] = true
	}
	return nil
}

// checkServer allows exactly https://host[:port], the host in lower case, the port without leading zeros, and
// nothing after it: one address has one spelling.
func checkServer(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return bad("state: server is not https://host[:port]")
	}
	want := "https://" + strings.ToLower(u.Hostname())
	if strings.Contains(u.Hostname(), ":") {
		want = "https://[" + strings.ToLower(u.Hostname()) + "]"
	}
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return bad("state: server has a bad port")
		}
		want += ":" + strconv.Itoa(n)
	}
	if raw != want {
		return bad("state: server %q is not written as %q", clip(raw), want)
	}
	return nil
}
