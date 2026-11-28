// Package home is what wmanager-sign keeps on the administrator's computer, in a folder only its user can open
// ($WMANAGER_SIGN_HOME, or wmanager-sign in the user's configuration folder):
//
//	server                         the server it was set up with last
//	servers/<host[_port]>/
//	    token.json                 the sign API's token and when it ends
//	    keys.json                  the signing keys made here: their ids, public keys and credential ids
//	companies/<id>.json            each company's fingerprint and the whole chain it verified, under the company's
//	                               own id (the hash of its first admin list)
//
// The chains are what protect the administrator against a server that shows an older chain or another one: they
// are written only after being checked, and only ever replaced by a longer chain that starts with them.
package home

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/lechup/wmanager/verify"
)

// Home is the folder.
type Home struct {
	Dir string
}

// Default is $WMANAGER_SIGN_HOME, or wmanager-sign in the user's configuration folder.
func Default() (*Home, error) {
	if d := os.Getenv("WMANAGER_SIGN_HOME"); d != "" {
		return &Home{Dir: d}, nil
	}
	c, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	return &Home{Dir: filepath.Join(c, "wmanager-sign")}, nil
}

// write writes a file whole or not at all, readable by its user only.
func write(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return write(path, b)
}

// readJSON reads a file into v; false when there is none.
func readJSON(path string, v any) (bool, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal(b, v); err != nil {
		return false, fmt.Errorf("%s: %w", path, err)
	}
	return true, nil
}

// Init makes the folder, for its user only.
func (h *Home) Init() error {
	if err := os.MkdirAll(h.Dir, 0o700); err != nil {
		return err
	}
	return os.Chmod(h.Dir, 0o700)
}

// DefaultServer is the server set up last, or "".
func (h *Home) DefaultServer() (string, error) {
	b, err := os.ReadFile(filepath.Join(h.Dir, "server"))
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	return strings.TrimSpace(string(b)), err
}

// SetDefaultServer keeps the server set up last.
func (h *Home) SetDefaultServer(server string) error {
	return write(filepath.Join(h.Dir, "server"), []byte(server+"\n"))
}

// Server is what wmanager-sign keeps of one server.
type Server struct {
	URL string
	dir string
}

// Server is a server's folder; its address is https://host[:port] as api.Normalize writes it. The folder is the
// host, "_" and the port when there is one; an IPv6 address is "ipv6_" and the address with "-" for ":".
func (h *Home) Server(server string) (*Server, error) {
	u, err := url.Parse(server)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" {
		return nil, fmt.Errorf("not a server's address: %q", server)
	}
	name := u.Hostname()
	if strings.Contains(name, ":") {
		name = "ipv6_" + strings.ReplaceAll(name, ":", "-")
	}
	if p := u.Port(); p != "" {
		name += "_" + p
	}
	if !folderRe.MatchString(name) || strings.Contains(name, "..") || strings.HasPrefix(name, ".") {
		return nil, fmt.Errorf("not a server's address: %q", server)
	}
	return &Server{URL: server, dir: filepath.Join(h.Dir, "servers", name)}, nil
}

var folderRe = regexp.MustCompile(`^(ipv6_[0-9a-f-]+|[a-z0-9.-]+)(_[0-9]{1,5})?$`)

// Token is the sign API's token.
type Token struct {
	Token   string    `json:"token"`
	Account string    `json:"account"`
	Expires time.Time `json:"expires"`
}

func (s *Server) tokenPath() string { return filepath.Join(s.dir, "token.json") }

// Token is the token kept, or nil (none, or ended).
func (s *Server) Token(now time.Time) (*Token, error) {
	var t Token
	ok, err := readJSON(s.tokenPath(), &t)
	if err != nil || !ok || !now.Before(t.Expires) {
		return nil, err
	}
	return &t, nil
}

// SetToken keeps a token.
func (s *Server) SetToken(t Token) error { return writeJSON(s.tokenPath(), t) }

// ForgetToken removes the token.
func (s *Server) ForgetToken() error {
	err := os.Remove(s.tokenPath())
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	return err
}

// Key is a signing key made here. Its credential id lets the security key be asked for that key only.
type Key struct {
	ID           string    `json:"id"`
	COSE         []byte    `json:"cose"`
	CredentialID []byte    `json:"credential_id"`
	Account      string    `json:"account"`
	Made         time.Time `json:"made"`
}

func (s *Server) keysPath() string { return filepath.Join(s.dir, "keys.json") }

// Keys is the signing keys made here for this server.
func (s *Server) Keys() ([]Key, error) {
	var ks []Key
	_, err := readJSON(s.keysPath(), &ks)
	return ks, err
}

// AddKey keeps a key made here.
func (s *Server) AddKey(k Key) error {
	ks, err := s.Keys()
	if err != nil {
		return err
	}
	return writeJSON(s.keysPath(), append(ks, k))
}

// Company is what wmanager-sign keeps of a company: its fingerprint and the whole chain it verified, the name it
// had when it was taken, and the id each server gives it. It is filed under the company's own id (the hash of its
// first admin list), not under a server's id for it: a server that lists the company again under a new id still
// meets the chain held, and can't have it taken again from an older one.
type Company struct {
	Name        string            `json:"name"`
	Fingerprint string            `json:"fingerprint"`
	Servers     map[string]string `json:"servers"` // a server's address: its id of the company
	Chain       []verify.Signed   `json:"chain"`
}

var hex64 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func (h *Home) companyPath(id string) (string, error) {
	if !hex64.MatchString(id) {
		return "", fmt.Errorf("not a company's id: %q", id)
	}
	return filepath.Join(h.Dir, "companies", id+".json"), nil
}

// Company is a company held, by its own id, with its chain checked again against its fingerprint; nil when it
// isn't held.
func (h *Home) Company(id string) (*Company, *verify.Chain, error) {
	p, err := h.companyPath(id)
	if err != nil {
		return nil, nil, err
	}
	var c Company
	ok, err := readJSON(p, &c)
	if err != nil || !ok {
		return nil, nil, err
	}
	ch, err := verify.VerifyChain(c.Fingerprint, c.Chain)
	if err != nil || ch.CompanyID() != id {
		return nil, nil, fmt.Errorf("the chain kept in %s doesn't check: %v", p, err)
	}
	if c.Servers == nil {
		c.Servers = map[string]string{}
	}
	return &c, ch, nil
}

// Companies is every company held.
func (h *Home) Companies() ([]*Company, []*verify.Chain, error) {
	names, err := filepath.Glob(filepath.Join(h.Dir, "companies", "*.json"))
	if err != nil {
		return nil, nil, err
	}
	var cs []*Company
	var chs []*verify.Chain
	for _, n := range names {
		c, ch, err := h.Company(strings.TrimSuffix(filepath.Base(n), ".json"))
		if err != nil {
			return nil, nil, err
		}
		if c != nil {
			cs, chs = append(cs, c), append(chs, ch)
		}
	}
	return cs, chs, nil
}

// ByServer is the company held that a server calls by its id; nil when none.
func (h *Home) ByServer(server, serverID string) (*Company, *verify.Chain, error) {
	cs, chs, err := h.Companies()
	if err != nil {
		return nil, nil, err
	}
	for i, c := range cs {
		if c.Servers[server] == serverID {
			return c, chs[i], nil
		}
	}
	return nil, nil, nil
}

// SetCompany keeps a company with its checked chain. A chain is only ever replaced by one that starts with it: the
// caller checks that with verify.Chain.Update; this checks it again.
func (h *Home) SetCompany(c *Company, ch *verify.Chain) error {
	p, err := h.companyPath(ch.CompanyID())
	if err != nil {
		return err
	}
	if _, held, err := h.Company(ch.CompanyID()); err != nil {
		return err
	} else if held != nil {
		again := &verify.Chain{Company: held.Company, Lists: held.Lists, Signed: held.Signed}
		if err := again.Update(ch.Signed); err != nil {
			return err
		}
	}
	return writeJSON(p, Company{Name: c.Name, Fingerprint: verify.Fingerprint(ch.Company), Servers: c.Servers, Chain: ch.Signed})
}

// ForgetCompany removes a company held: only for a first list the server refused, never for a chain taken.
func (h *Home) ForgetCompany(id string) error {
	p, err := h.companyPath(id)
	if err != nil {
		return err
	}
	return os.Remove(p)
}

// RandomHex is n random bytes in hex.
func RandomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
