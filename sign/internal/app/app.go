// Package app is wmanager-sign's commands: connecting to a server with a code from the panel, making and
// registering signing keys, and a company's chain of admin lists (docs/architecture.md, "wmanager-sign").
//
// Everything it shows that came from a server or a statement goes through show, and everything it signs it
// built itself and showed first.
package app

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
)

// MaxClockSkew is how far wmanager-sign's clock may be from the server's for it to sign.
const MaxClockSkew = 10 * time.Minute

// App is one run of wmanager-sign.
type App struct {
	Home *home.Home
	In   *bufio.Reader
	Out  io.Writer
	// ReadSecret reads what nobody else should see (a code from the panel, a PIN) without showing it.
	ReadSecret func(prompt string) (string, error)
	// OpenDevice opens the security key.
	OpenDevice func() (fido.Device, error)
	HTTP       *http.Client
	Now        func() time.Time
	Lang       string
	Server     string // -server, or "" for the one set up last
}

// ErrUsage is a command line that isn't one.
var ErrUsage = errors.New("usage")

// errShown is an error with its explanation for the screen, and what it is, for errors.Is.
type errShown struct {
	msg string
	err error
}

func (e errShown) Error() string { return e.msg }
func (e errShown) Unwrap() error { return e.err }

func (a *App) say(key string, args ...any) { fmt.Fprintln(a.Out, a.t(key, args...)) }

func (a *App) fail(key string, args ...any) error { return errShown{msg: a.t(key, args...)} }

// failAs is fail for an error that callers tell apart.
func (a *App) failAs(err error, key string, args ...any) error {
	return errShown{msg: a.t(key, args...), err: err}
}

// ask reads a line.
func (a *App) ask(key string, args ...any) (string, error) {
	fmt.Fprint(a.Out, a.t(key, args...)+" ")
	line, err := a.In.ReadString('\n')
	if err != nil && (line == "" || !errors.Is(err, io.EOF)) {
		if errors.Is(err, io.EOF) {
			return "", a.fail("err.eof")
		}
		return "", err
	}
	return strings.TrimSpace(line), nil
}

// confirm asks for the word "yes", in the language shown or in English, and nothing else, before signing. An accent
// may be left out (si for sí).
func (a *App) confirm(key string, args ...any) (bool, error) {
	ans, err := a.ask(key, args...)
	if err != nil {
		return false, err
	}
	return strings.EqualFold(ans, "yes") || strings.EqualFold(unaccented(ans), unaccented(a.t("word.yes"))), nil
}

var accents = strings.NewReplacer("á", "a", "à", "a", "â", "a", "ã", "a", "é", "e", "è", "e", "ê", "e", "í", "i", "ì", "i",
	"î", "i", "ó", "o", "ò", "o", "ô", "o", "õ", "o", "ú", "u", "ù", "u", "û", "u", "Í", "I", "Ì", "I", "Á", "A", "É", "E")

func unaccented(s string) string { return accents.Replace(strings.TrimSpace(s)) }

// Run runs a command line.
func (a *App) Run(ctx context.Context, args []string) error {
	if a.Now == nil {
		a.Now = time.Now
	}
	if err := a.Home.Init(); err != nil {
		return err
	}
	unlock, err := a.Home.Lock()
	if err != nil {
		return a.fail("err.locked", a.Home.Dir)
	}
	defer unlock()
	cmd := ""
	if len(args) > 0 {
		cmd, args = args[0], args[1:]
	}
	switch cmd {
	case "", "companies":
		return a.status(ctx)
	case "connect":
		if len(args) != 1 {
			return ErrUsage
		}
		return a.connect(ctx, args[0])
	case "disconnect":
		return a.disconnect()
	case "key":
		if len(args) == 1 && args[0] == "new" {
			return a.newKey(ctx)
		}
		if len(args) == 1 && args[0] == "list" {
			return a.listKeys()
		}
	case "company":
		if len(args) == 2 {
			switch args[0] {
			case "init":
				return a.initCompany(ctx, args[1])
			case "trust":
				return a.trustCompany(ctx, args[1])
			}
		}
	case "fingerprint":
		if len(args) == 1 {
			return a.fingerprint(ctx, args[0])
		}
	case "admins":
		switch {
		case len(args) == 1:
			return a.showAdmins(ctx, args[0])
		case len(args) == 2:
			return a.changeAdmins(ctx, args[1], args[0])
		}
	case "sign":
		if len(args) == 1 {
			return a.signDraft(ctx, args[0])
		}
	case "audit":
		if len(args) == 2 && args[0] == "accept" {
			return a.acceptAudit(ctx, args[1])
		}
	case "secret":
		if len(args) == 3 && args[0] == "set" {
			return a.setSecret(ctx, args[1], args[2])
		}
	case "help", "-h", "-help", "--help":
		a.say("usage")
		return nil
	}
	return ErrUsage
}

// session is a server with its token and the account it is for.
type session struct {
	srv     *home.Server
	client  *api.Client
	account string
}

// connected is the server set up, with a token that hasn't ended.
func (a *App) connected() (*session, error) {
	server := a.Server
	if server == "" {
		var err error
		if server, err = a.Home.DefaultServer(); err != nil {
			return nil, err
		}
	}
	if server == "" {
		return nil, a.fail("err.noserver")
	}
	server, err := api.Normalize(server)
	if err != nil {
		return nil, err
	}
	srv, err := a.Home.Server(server)
	if err != nil {
		return nil, err
	}
	tok, err := srv.Token(a.Now())
	if err != nil {
		return nil, err
	}
	if tok == nil {
		return nil, a.fail("err.notoken", server)
	}
	return &session{srv: srv, client: &api.Client{Server: server, Token: tok.Token, HTTP: a.HTTP}, account: tok.Account}, nil
}

// apiErr explains a refusal of the server; a token that ended asks for a new code.
func (a *App) apiErr(s *session, err error) error {
	if api.Status(err) == http.StatusUnauthorized {
		s.srv.ForgetToken()
		return a.fail("err.tokenended", s.client.Server)
	}
	return err
}

// checkClock refuses to sign with a clock more than MaxClockSkew from the server's.
func (a *App) checkClock(ctx context.Context, s *session) error {
	t, err := s.client.Time(ctx)
	if err != nil {
		return a.apiErr(s, err)
	}
	if d := a.Now().Sub(t); d.Abs() > MaxClockSkew {
		return a.fail("err.clock", d.Round(time.Second).String(), t.UTC().Format(time.RFC3339))
	}
	return nil
}

// company finds a company of the account: first among those held, by the name it had when it was taken (so a
// server that swaps two companies' names doesn't swap which one is signed for), then among the server's, by its
// name or id.
func (a *App) company(ctx context.Context, s *session, which string) (api.Company, error) {
	me, err := s.client.Me(ctx)
	if err != nil {
		return api.Company{}, a.apiErr(s, err)
	}
	byID := map[string]api.Company{}
	for _, c := range me.Companies {
		byID[c.ID] = c
	}
	held, _, err := a.Home.Companies()
	if err != nil {
		return api.Company{}, err
	}
	var found []api.Company
	for _, h := range held {
		if id, ok := h.Servers[s.client.Server]; ok && strings.EqualFold(h.Name, which) {
			c, ok := byID[id]
			if !ok {
				return api.Company{}, a.fail("err.notlisted", show.Visible(h.Name))
			}
			found = append(found, c)
		}
	}
	if len(found) == 0 {
		for _, c := range me.Companies {
			if c.ID == which || strings.EqualFold(c.Name, which) {
				found = append(found, c)
			}
		}
	}
	switch len(found) {
	case 0:
		return api.Company{}, a.fail("err.nocompany", show.Visible(which))
	case 1:
		return found[0], nil
	}
	return api.Company{}, a.fail("err.twocompanies", show.Visible(which))
}
