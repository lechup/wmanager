package app

import (
	"cmp"
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
	a.say("status.server", show.Visible(s.client.Server))
	if len(me.Companies) == 0 {
		a.say("status.nocompanies")
		return nil
	}
	// An alarm for one company doesn't hide the others; it ends the run with an error all the same.
	var alarm error
	for _, c := range me.Companies {
		name, role := show.Visible(c.Name), show.Visible(c.Role)
		held, ch, err := a.load(ctx, s, c)
		switch {
		case errors.Is(err, verify.ErrForkedChain):
			a.say("line", err.Error())
			alarm = cmp.Or(alarm, err)
		case err != nil:
			a.say("status.error", name, err.Error())
		case held != nil:
			a.say("status.held", show.Visible(held.Name), role, verify.Fingerprint(ch.Company), ch.Current().Sequence)
			b, err := a.loadState(ctx, s, c, held, ch)
			if errors.Is(err, verify.ErrForkedChain) {
				a.say("line", err.Error())
				alarm = cmp.Or(alarm, err)
				continue
			}
			if err != nil {
				a.say("status.error", show.Visible(held.Name), err.Error())
				continue
			}
			serial := home.Serial(b.signed)
			if b.reported > b.known {
				a.say("status.reported", b.reported)
			}
			waiting := 0
			if c.Role == "admin" {
				if ds, err := s.client.Drafts(ctx, c.ID); err == nil {
					waiting = len(ds)
				}
			}
			a.say("status.state", serial, waiting)
			head, n, err := a.checkAudit(ctx, s, c, held, ch)
			switch {
			case errors.Is(err, ErrAuditBroken):
				alarm = cmp.Or(alarm, err)
			case err != nil:
				a.say("status.error", show.Visible(held.Name), err.Error())
			case head.Seq > 0:
				a.say("status.audit", headString(head), n)
			}
		case c.Fingerprint == "":
			a.say("status.nochain", name, role)
		default:
			a.say("status.untrusted", name, role)
		}
	}
	return alarm
}
