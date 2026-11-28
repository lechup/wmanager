// Package home is what wmanager-sign keeps on the administrator's computer, in a folder only its user can open
// ($WMANAGER_SIGN_HOME, or wmanager-sign in the user's configuration folder):
//
//	server                         the server it was set up with last
//	servers/<host[_port]>/
//	    token.json                 the sign API's token and when it ends
//	    keys.json                  the signing keys made here: their ids, public keys and credential ids
//	    companies/<id>.json        each company's fingerprint and the whole chain it verified
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

// Server is a server's folder; its address is https://host[:port] as api.Normalize writes it.
func (h *Home) Server(server string) (*Server, error) {
	u, err := url.Parse(server)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, fmt.Errorf("not a server's address: %q", server)
	}
	name := strings.NewReplacer(":", "_", "[", "", "]", "").Replace(u.Host)
	return &Server{URL: server, dir: filepath.Join(h.Dir, "servers", name)}, nil
}

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

// Company is what wmanager-sign keeps of a company: its fingerprint and the whole chain it verified.
type Company struct {
	ID          string          `json:"id"` // the server's id of it
	Name        string          `json:"name"`
	Fingerprint string          `json:"fingerprint"`
	Chain       []verify.Signed `json:"chain"`
}

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func (s *Server) companyPath(id string) (string, error) {
	if !uuidRe.MatchString(id) {
		return "", fmt.Errorf("not a company's id: %q", id)
	}
	return filepath.Join(s.dir, "companies", id+".json"), nil
}

// Company is a company's chain as held, checked again against its fingerprint; nil when none is held.
func (s *Server) Company(id string) (*Company, *verify.Chain, error) {
	p, err := s.companyPath(id)
	if err != nil {
		return nil, nil, err
	}
	var c Company
	ok, err := readJSON(p, &c)
	if err != nil || !ok {
		return nil, nil, err
	}
	ch, err := verify.VerifyChain(c.Fingerprint, c.Chain)
	if err != nil {
		return nil, nil, fmt.Errorf("the chain kept in %s doesn't check: %w", p, err)
	}
	return &c, ch, nil
}

// SetCompany keeps a company's checked chain. A chain is only ever replaced by one that starts with it: the
// caller checks that with verify.Chain.Update; this checks it again.
func (s *Server) SetCompany(id, name string, ch *verify.Chain) error {
	p, err := s.companyPath(id)
	if err != nil {
		return err
	}
	if old, held, err := s.Company(id); err != nil {
		return err
	} else if old != nil {
		if held.Company != ch.Company {
			return fmt.Errorf("%w: another company's chain", verify.ErrForkedChain)
		}
		again := &verify.Chain{Company: held.Company, Lists: held.Lists, Signed: held.Signed}
		if err := again.Update(ch.Signed); err != nil {
			return err
		}
	}
	return writeJSON(p, Company{ID: id, Name: name, Fingerprint: verify.Fingerprint(ch.Company), Chain: ch.Signed})
}

// RandomHex is n random bytes in hex.
func RandomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}
