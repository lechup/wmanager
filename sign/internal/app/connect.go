package app

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// connect exchanges a code from the panel's page "Account" for a token of 12 hours. The code is typed, never
// given on the command line.
func (a *App) connect(ctx context.Context, raw string) error {
	server, err := api.Normalize(raw)
	if err != nil {
		return a.fail("err.badserver")
	}
	srv, err := a.Home.Server(server)
	if err != nil {
		return err
	}
	a.say("connect.where", server)
	code, err := a.ReadSecret(a.t("connect.code"))
	if err != nil {
		return err
	}
	code = strings.TrimSpace(code)
	if code == "" {
		return a.fail("err.nocode")
	}
	c := &api.Client{Server: server, HTTP: a.HTTP}
	l, err := c.Login(ctx, code)
	switch api.Status(err) {
	case 0:
	case http.StatusUnauthorized:
		return a.fail("err.badcode")
	case http.StatusTooManyRequests:
		return a.fail("err.toomany")
	}
	if err != nil {
		return err
	}
	if err := srv.SetToken(home.Token{Token: l.Token, Account: l.Account, Expires: l.Expires}); err != nil {
		return err
	}
	if err := a.Home.SetDefaultServer(server); err != nil {
		return err
	}
	a.say("connect.done", server, l.Expires.Local().Format("2006-01-02 15:04"))
	a.Server = server
	return a.status(ctx)
}

// disconnect forgets the token here; the panel's "Disconnect wmanager-sign everywhere" ends it on the server.
func (a *App) disconnect() error {
	server := a.Server
	if server == "" {
		var err error
		if server, err = a.Home.DefaultServer(); err != nil || server == "" {
			return err
		}
	}
	srv, err := a.Home.Server(server)
	if err != nil {
		return err
	}
	if err := srv.ForgetToken(); err != nil {
		return err
	}
	a.say("disconnect.done", server)
	return nil
}

// status lists the account's companies: whether wmanager-sign holds each one's chain, and any admin lists the
// server has that it hadn't seen.
func (a *App) status(ctx context.Context) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	me, err := s.client.Me(ctx)
	if err != nil {
		return a.apiErr(s, err)
	}
	a.say("status.server", s.client.Server)
	if len(me.Companies) == 0 {
		a.say("status.nocompanies")
		return nil
	}
	for _, c := range me.Companies {
		held, ch, err := s.srv.Company(c.ID)
		if err != nil {
			return err
		}
		name, role := show.Visible(c.Name), show.Visible(c.Role)
		if held == nil {
			if c.Fingerprint == "" {
				a.say("status.nochain", name, role)
			} else {
				a.say("status.untrusted", name, role)
			}
			continue
		}
		if _, err := a.refresh(ctx, s, c, held, ch); err != nil {
			if errors.Is(err, verify.ErrForkedChain) {
				return err
			}
			a.say("status.error", name, err.Error())
			continue
		}
		a.say("status.held", name, role, verify.Fingerprint(ch.Company), ch.Current().Sequence)
	}
	return nil
}
