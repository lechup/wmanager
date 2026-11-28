// Package api is wmanager-sign's side of the server's sign API (/api/sign/v1/). Nothing the server says is
// trusted: chains are checked against the fingerprint wmanager-sign keeps, and messages are shown with show.
package api

import (
	"bytes"
	"context"
	"encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// Prefix is where the API lives on the server.
const Prefix = "/api/sign/v1/"

// MaxAnswer is the largest answer read: a long chain of admin lists.
const MaxAnswer = 64 << 20

// Client talks to one server.
type Client struct {
	Server string // https://host[:port]
	Token  string
	HTTP   *http.Client
}

// Error is the server's refusal.
type Error struct {
	Status  int
	Message string // as the server said it; show it with show.Clip
}

func (e *Error) Error() string {
	return fmt.Sprintf("the server answered %d: %s", e.Status, show.Clip(e.Message, 200))
}

// Status is the HTTP status of a refusal, or 0.
func Status(err error) int {
	var e *Error
	if errors.As(err, &e) {
		return e.Status
	}
	return 0
}

// hostRe is a host name (letters, digits and "-" in labels between dots) or an IPv4 address.
var hostRe = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

// ErrBadServer refuses an address that isn't https://host[:port].
var ErrBadServer = errors.New("the server's address is https://host or https://host:port, with nothing after it")

// Normalize is the server's address as wmanager-sign keeps it and key proofs name it: https://host[:port] in lower
// case, the default port left out. A bare host gets https://.
func Normalize(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || (u.Path != "" && u.Path != "/") ||
		u.RawQuery != "" || u.Fragment != "" || u.Opaque != "" || strings.HasSuffix(raw, "?") || strings.HasSuffix(raw, "#") {
		return "", ErrBadServer
	}
	host := strings.ToLower(u.Hostname())
	switch {
	case strings.Contains(host, ":"):
		if net.ParseIP(host) == nil {
			return "", ErrBadServer
		}
		host = "[" + host + "]"
	case !hostRe.MatchString(host):
		return "", ErrBadServer
	}
	out := "https://" + host
	if p := u.Port(); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return "", ErrBadServer
		}
		if n != 443 {
			out += ":" + strconv.Itoa(n)
		}
	}
	return out, nil
}

func (c *Client) do(ctx context.Context, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.Server+Prefix+path, body)
	if err != nil {
		return err
	}
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	hc := c.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, MaxAnswer+1))
	if err != nil {
		return err
	}
	if len(raw) > MaxAnswer {
		return errors.New("the server's answer is too large")
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(raw, &e) != nil || e.Error == "" {
			e.Error = http.StatusText(resp.StatusCode)
		}
		return &Error{Status: resp.StatusCode, Message: e.Error}
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return fmt.Errorf("the server's answer is not what this call gives: %w", err)
	}
	return nil
}

// Login is a code exchanged for a token.
type Login struct {
	Token   string    `json:"token"`
	Account string    `json:"account"`
	Expires time.Time `json:"expires"`
}

// Login exchanges a code from the panel for a token.
func (c *Client) Login(ctx context.Context, code string) (Login, error) {
	var l Login
	err := c.do(ctx, http.MethodPost, "login", map[string]string{"code": code}, &l)
	if err == nil && (l.Token == "" || l.Account == "") {
		err = errors.New("the server gave no token")
	}
	return l, err
}

// Time is the server's clock.
func (c *Client) Time(ctx context.Context) (time.Time, error) {
	var t struct {
		Now time.Time `json:"now"`
	}
	err := c.do(ctx, http.MethodGet, "time", nil, &t)
	return t.Now, err
}

// Company is a company as the server lists it. The fingerprint is the server's word only.
type Company struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Role        string `json:"role"`
	Fingerprint string `json:"fingerprint"`
}

// Me is the account and its companies.
type Me struct {
	Account   string    `json:"account"`
	Companies []Company `json:"companies"`
}

// Me is who the token is for.
func (c *Client) Me(ctx context.Context) (Me, error) {
	var m Me
	err := c.do(ctx, http.MethodGet, "me", nil, &m)
	return m, err
}

func companyPath(id, rest string) string { return "companies/" + url.PathEscape(id) + "/" + rest }

// Chain is a company's chain as the server holds it.
func (c *Client) Chain(ctx context.Context, company string) ([]verify.Signed, error) {
	var ch struct {
		Lists []verify.Signed `json:"lists"`
	}
	err := c.do(ctx, http.MethodGet, companyPath(company, "chain"), nil, &ch)
	return ch.Lists, err
}

// Append gives the server the company's next admin list.
func (c *Client) Append(ctx context.Context, company string, next verify.Signed) error {
	return c.do(ctx, http.MethodPost, companyPath(company, "chain"), next, nil)
}

// Key is a signing key a member of the company registered. The e-mail is the server's word only.
type Key struct {
	ID    string `json:"id"`
	Email string `json:"email"`
	COSE  []byte `json:"cose"`
}

// CompanyKeys is the keys the company's members registered.
func (c *Client) CompanyKeys(ctx context.Context, company string) ([]Key, error) {
	var ks struct {
		Keys []Key `json:"keys"`
	}
	err := c.do(ctx, http.MethodGet, companyPath(company, "keys"), nil, &ks)
	return ks.Keys, err
}

// RegisterKey registers a new signing key with its proof.
func (c *Client) RegisterKey(ctx context.Context, cose []byte, proof verify.Signed) (string, error) {
	var r struct {
		ID string `json:"id"`
	}
	err := c.do(ctx, http.MethodPost, "keys", map[string]any{"cose": cose, "proof": proof}, &r)
	return r.ID, err
}
