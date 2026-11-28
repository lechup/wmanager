package app

import (
	"context"
	"encoding/hex"
	"errors"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// load is the company as held, brought up to the server's chain; nil when it isn't held. The chain held is found
// by the company's own id (its first list's hash), whatever id the server lists it under now. A longer chain that
// starts with the held one is checked list by list, its changes are shown, and it is kept. A server that is behind
// gets the lists it lacks, when the account may give them. A chain that leaves the held one, or another chain for
// the id the server gave this company before, is an alarm: it could bring back a key removed since.
func (a *App) load(ctx context.Context, s *session, c api.Company) (*home.Company, *verify.Chain, error) {
	lists, err := s.client.Chain(ctx, c.ID)
	if err != nil {
		return nil, nil, a.apiErr(s, err)
	}
	mapped, mappedCh, err := a.Home.ByServer(s.client.Server, c.ID)
	if err != nil {
		return nil, nil, err
	}
	held, ch := mapped, mappedCh
	if len(lists) > 0 {
		id := lists[0].Hash()
		if mapped != nil && mappedCh.Company != id {
			return nil, nil, a.failAs(verify.ErrForkedChain, "chain.forked", show.Visible(c.Name),
				a.t("chain.another", verify.Fingerprint(mappedCh.Company)))
		}
		if held, ch, err = a.Home.Company(hex.EncodeToString(id[:])); err != nil {
			return nil, nil, err
		}
	}
	if held == nil {
		return nil, nil, nil
	}
	name := show.Visible(held.Name)
	before := len(ch.Signed)
	err = ch.Update(lists)
	switch {
	case errors.Is(err, verify.ErrOlderChain):
		a.say("chain.older", name, len(lists), before)
		if c.Role == "admin" {
			for _, l := range ch.Signed[len(lists):] {
				if err := s.client.Append(ctx, c.ID, l); err != nil {
					a.say("chain.pushfailed", err.Error())
					break
				}
			}
			if l, err := s.client.Chain(ctx, c.ID); err == nil && len(l) == before {
				a.say("chain.pushed", before-len(lists))
			}
		}
	case errors.Is(err, verify.ErrForkedChain):
		return nil, nil, a.failAs(verify.ErrForkedChain, "chain.forked", name, err.Error())
	case err != nil:
		return nil, nil, a.fail("chain.bad", name, err.Error())
	}
	for i := before; i < len(ch.Signed); i++ {
		a.say("chain.new", ch.Lists[i].Sequence, show.Visible(signerName(ch.Lists[i-1], ch.Signed[i].Key)),
			ch.Lists[i].SignedAt.Local().Format("2006-01-02 15:04"))
		for _, line := range describe(ch.Lists[i-1], ch.Lists[i]) {
			a.say("line", line)
		}
	}
	if old, ok := held.Servers[s.client.Server]; ok && old != c.ID {
		a.say("company.newid", name)
	}
	if held.Name != c.Name {
		a.say("company.renamed", name, show.Visible(c.Name))
	}
	if len(ch.Signed) > before || held.Servers[s.client.Server] != c.ID {
		held.Servers[s.client.Server] = c.ID
		if err := a.Home.SetCompany(held, ch); err != nil {
			return nil, nil, err
		}
	}
	return held, ch, nil
}

// held is a company whose chain is held, brought up to the server's.
func (a *App) held(ctx context.Context, s *session, which string) (api.Company, *home.Company, *verify.Chain, error) {
	c, err := a.company(ctx, s, which)
	if err != nil {
		return c, nil, nil, err
	}
	h, ch, err := a.load(ctx, s, c)
	if err == nil && h == nil {
		err = a.fail("err.untrusted", show.Visible(c.Name), show.Visible(which))
	}
	return c, h, ch, err
}

// signerName is the name the list before gives the key that signed the next one.
func signerName(prev *verify.Admins, key string) string {
	for _, ad := range prev.Administrators {
		for _, k := range ad.Keys {
			if k.ID == key {
				return ad.Name
			}
		}
	}
	return "?"
}

func idFingerprint(id string) string {
	b, err := hex.DecodeString(id)
	if err != nil || len(b) != 32 {
		return "?"
	}
	return verify.Fingerprint([32]byte(b))
}

func fingerprints(keys []verify.Key) string {
	var fs []string
	for _, k := range keys {
		fs = append(fs, idFingerprint(k.ID))
	}
	return strings.Join(fs, ", ")
}

// describe is what changes from one admin list to the next, one line each, names shown visibly.
func describe(prev, next *verify.Admins) []string {
	var out []string
	old := map[string]verify.Administrator{}
	for _, ad := range prev.Administrators {
		old[ad.Name] = ad
	}
	now := map[string]bool{}
	for _, ad := range next.Administrators {
		now[ad.Name] = true
		was, ok := old[ad.Name]
		if !ok {
			out = append(out, "+ "+show.Visible(ad.Name)+": "+fingerprints(ad.Keys))
			continue
		}
		for _, k := range ad.Keys {
			if !slices.ContainsFunc(was.Keys, func(x verify.Key) bool { return x.ID == k.ID }) {
				out = append(out, "  "+show.Visible(ad.Name)+": + "+idFingerprint(k.ID))
			}
		}
		for _, k := range was.Keys {
			if !slices.ContainsFunc(ad.Keys, func(x verify.Key) bool { return x.ID == k.ID }) {
				out = append(out, "  "+show.Visible(ad.Name)+": - "+idFingerprint(k.ID))
			}
		}
	}
	for _, ad := range prev.Administrators {
		if !now[ad.Name] {
			out = append(out, "- "+show.Visible(ad.Name)+": "+fingerprints(ad.Keys))
		}
	}
	return out
}

func (a *App) printList(h *home.Company, ch *verify.Chain) {
	cur := ch.Current()
	a.say("admins.head", cur.Sequence, show.Visible(h.Name), verify.Fingerprint(ch.Company),
		cur.SignedAt.Local().Format("2006-01-02 15:04"))
	for _, ad := range cur.Administrators {
		a.say("line", "  "+show.Visible(ad.Name)+": "+fingerprints(ad.Keys))
	}
}

// warnFewKeys says when one lost key would leave nobody who can sign.
func (a *App) warnFewKeys(l *verify.Admins) {
	n := 0
	for _, ad := range l.Administrators {
		n += len(ad.Keys)
	}
	if n < 2 {
		a.say("admins.onekey")
	}
}

// fingerprint prints the company's fingerprint as held.
func (a *App) fingerprint(ctx context.Context, which string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	_, h, ch, err := a.held(ctx, s, which)
	if err != nil {
		return err
	}
	a.say("company.fingerprint", show.Visible(h.Name), verify.Fingerprint(ch.Company))
	return nil
}

// showAdmins shows the newest admin list.
func (a *App) showAdmins(ctx context.Context, which string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	_, h, ch, err := a.held(ctx, s, which)
	if err != nil {
		return err
	}
	a.printList(h, ch)
	return nil
}

// trustCompany takes a company's chain for the first time, against the fingerprint typed in: the one written down
// when the company was made, or read out by one of its administrators. Not the one the panel shows: a hacked server
// could show its own there. A company held already is only brought up to the server's chain.
func (a *App) trustCompany(ctx context.Context, which string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	c, err := a.company(ctx, s, which)
	if err != nil {
		return err
	}
	if h, ch, err := a.load(ctx, s, c); err != nil {
		return err
	} else if h != nil {
		a.say("company.heldalready", show.Visible(h.Name), verify.Fingerprint(ch.Company))
		return nil
	}
	lists, err := s.client.Chain(ctx, c.ID)
	if err != nil {
		return a.apiErr(s, err)
	}
	if len(lists) == 0 {
		return a.fail("err.nochainyet", show.Visible(c.Name))
	}
	typed, err := a.ask("company.typefp")
	if err != nil {
		return err
	}
	if !verify.MatchesFingerprint(lists[0].Hash(), typed) {
		return a.fail("err.fpmismatch", show.Visible(c.Name))
	}
	ch, err := verify.VerifyChain(typed, lists)
	if err != nil {
		return a.fail("chain.bad", show.Visible(c.Name), err.Error())
	}
	h := &home.Company{Name: c.Name, Servers: map[string]string{s.client.Server: c.ID}}
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	a.say("company.trusted", show.Visible(c.Name))
	a.printList(h, ch)
	return nil
}

func (a *App) signedAt() time.Time { return a.Now().UTC().Truncate(time.Second) }

// initCompany makes a company's first admin list, with the administrator's name and a key made here, signed by
// that key. Its hash is the company's id, and its fingerprint is shown to be written down.
func (a *App) initCompany(ctx context.Context, which string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	c, err := a.company(ctx, s, which)
	if err != nil {
		return err
	}
	if c.Role != "admin" {
		return a.fail("err.notadmin", show.Visible(c.Name))
	}
	if h, _, err := a.load(ctx, s, c); err != nil {
		return err
	} else if h != nil {
		return a.fail("err.haschain", show.Visible(h.Name))
	}
	lists, err := s.client.Chain(ctx, c.ID)
	if err != nil {
		return a.apiErr(s, err)
	}
	if len(lists) > 0 {
		return a.fail("err.haschain", show.Visible(c.Name))
	}
	mine, err := a.myKeys(s)
	if err != nil {
		return err
	}
	var key home.Key
	switch len(mine) {
	case 0:
		return a.fail("err.nokeys")
	case 1:
		key = mine[0]
	default:
		for i, k := range mine {
			a.say("line", strconv.Itoa(i+1)+") "+keyFingerprint(k.COSE))
		}
		n, err := a.choose(len(mine), "company.whichkey")
		if err != nil {
			return err
		}
		key = mine[n]
	}
	name, err := a.ask("admins.yourname")
	if err != nil {
		return err
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	first := verify.Admins{Format: verify.Format, Type: verify.TypeAdmins, SignedAt: a.signedAt(),
		Nonce: home.RandomHex(16), Sequence: 1,
		Administrators: []verify.Administrator{{Name: name, Keys: []verify.Key{{ID: key.ID, COSE: key.COSE}}}}}
	raw, err := verify.Marshal(first)
	if err != nil {
		return err
	}
	if _, err := verify.ParseAdmins(raw); err != nil {
		return a.fail("err.badlist", err.Error())
	}
	a.say("company.first", show.Visible(c.Name))
	a.say("line", "+ "+show.Visible(name)+": "+keyFingerprint(key.COSE))
	a.warnFewKeys(&first)
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	d, pin, err := a.device()
	if err != nil {
		return err
	}
	defer d.Close()
	pk, err := verify.ParseCOSEKey(key.COSE)
	if err != nil {
		return err
	}
	signed, err := a.signWith(d, pin, raw, map[string]verify.PublicKey{key.ID: pk}, []home.Key{key})
	if err != nil {
		return err
	}
	ch, err := verify.VerifyChain(verify.Fingerprint(signed.Hash()), []verify.Signed{signed})
	if err != nil {
		return err
	}
	// Kept and shown before the server has it: an answer lost on the way mustn't lose the fingerprint, and the
	// server gets the list again from load if it hasn't.
	h := &home.Company{Name: c.Name, Servers: map[string]string{s.client.Server: c.ID}}
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	a.say("company.made", show.Visible(c.Name), verify.Fingerprint(ch.Company))
	if err := s.client.Append(ctx, c.ID, signed); err != nil {
		if st := api.Status(err); st >= 400 && st < 500 {
			// Refused: this list is no company's; forget it, and its fingerprint with it.
			a.Home.ForgetCompany(ch.CompanyID())
			a.say("company.refused")
			return a.apiErr(s, err)
		}
		a.say("company.notsent", err.Error())
		return nil
	}
	return nil
}

// myKeys is the keys made here for the account.
func (a *App) myKeys(s *session) ([]home.Key, error) {
	all, err := s.srv.Keys()
	if err != nil {
		return nil, err
	}
	var mine []home.Key
	for _, k := range all {
		if k.Account == s.account {
			mine = append(mine, k)
		}
	}
	return mine, nil
}

// choose reads a number from 1 to n.
func (a *App) choose(n int, key string) (int, error) {
	ans, err := a.ask(key, n)
	if err != nil {
		return 0, err
	}
	i, err := strconv.Atoi(ans)
	if err != nil || i < 1 || i > n {
		return 0, a.fail("err.choice")
	}
	return i - 1, nil
}

// typedKey finds the key whose whole fingerprint was typed, among those made here and those the company's members
// registered. Nothing the server says is taken without that: a hacked server could put a key of its own in the
// place of the one meant.
func (a *App) typedKey(ctx context.Context, s *session, c api.Company, in *verify.Admins) (verify.Key, error) {
	typed, err := a.ask("admins.typekey")
	if err != nil {
		return verify.Key{}, err
	}
	var candidates [][]byte
	mine, err := s.srv.Keys()
	if err != nil {
		return verify.Key{}, err
	}
	for _, k := range mine {
		candidates = append(candidates, k.COSE)
	}
	reg, err := s.client.CompanyKeys(ctx, c.ID)
	if err != nil {
		return verify.Key{}, a.apiErr(s, err)
	}
	for _, k := range reg {
		candidates = append(candidates, k.COSE)
	}
	for _, cose := range candidates {
		h := sha256Sum(cose)
		if !verify.MatchesFingerprint(h, typed) {
			continue
		}
		if _, err := verify.ParseCOSEKey(cose); err != nil {
			return verify.Key{}, a.fail("err.badkey", err.Error())
		}
		k := verify.Key{ID: verify.KeyID(cose), COSE: cose}
		for _, ad := range in.Administrators {
			if slices.ContainsFunc(ad.Keys, func(x verify.Key) bool { return x.ID == k.ID }) {
				return verify.Key{}, a.fail("err.keyinlist", show.Visible(ad.Name))
			}
		}
		return k, nil
	}
	return verify.Key{}, a.fail("err.nokeyfp")
}

// changeAdmins makes the next admin list: an administrator added or removed, a key added or removed.
func (a *App) changeAdmins(ctx context.Context, which, op string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	c, h, ch, err := a.held(ctx, s, which)
	if err != nil {
		return err
	}
	if c.Role != "admin" {
		return a.fail("err.notadmin", show.Visible(h.Name))
	}
	cur := ch.Current()
	next := verify.Admins{Administrators: slices.Clone(cur.Administrators)}
	for i := range next.Administrators {
		next.Administrators[i].Keys = slices.Clone(next.Administrators[i].Keys)
	}
	pickAdmin := func() (int, error) {
		for i, ad := range next.Administrators {
			a.say("line", strconv.Itoa(i+1)+") "+show.Visible(ad.Name)+": "+fingerprints(ad.Keys))
		}
		return a.choose(len(next.Administrators), "admins.which")
	}
	switch op {
	case "add":
		name, err := a.ask("admins.name")
		if err != nil {
			return err
		}
		k, err := a.typedKey(ctx, s, c, &next)
		if err != nil {
			return err
		}
		next.Administrators = append(next.Administrators, verify.Administrator{Name: name, Keys: []verify.Key{k}})
	case "add-key":
		i, err := pickAdmin()
		if err != nil {
			return err
		}
		k, err := a.typedKey(ctx, s, c, &next)
		if err != nil {
			return err
		}
		next.Administrators[i].Keys = append(next.Administrators[i].Keys, k)
	case "remove-key":
		type ref struct{ admin, key int }
		var refs []ref
		for i, ad := range next.Administrators {
			for j, k := range ad.Keys {
				refs = append(refs, ref{i, j})
				a.say("line", strconv.Itoa(len(refs))+") "+show.Visible(ad.Name)+": "+idFingerprint(k.ID))
			}
		}
		n, err := a.choose(len(refs), "admins.whichkey")
		if err != nil {
			return err
		}
		r := refs[n]
		if len(next.Administrators[r.admin].Keys) == 1 {
			return a.fail("err.lastkey", show.Visible(next.Administrators[r.admin].Name))
		}
		next.Administrators[r.admin].Keys = slices.Delete(next.Administrators[r.admin].Keys, r.key, r.key+1)
	case "remove":
		i, err := pickAdmin()
		if err != nil {
			return err
		}
		if len(next.Administrators) == 1 {
			return a.fail("err.lastadmin")
		}
		next.Administrators = slices.Delete(next.Administrators, i, i+1)
	default:
		return ErrUsage
	}
	return a.signNext(ctx, s, c, h, ch, next)
}

// signNext signs the next admin list after showing what it changes, checks it as a computer will, gives it to
// the server and keeps the longer chain.
func (a *App) signNext(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain, next verify.Admins) error {
	cur, prev := ch.Current(), ch.Signed[len(ch.Signed)-1].Hash()
	next.Format, next.Type, next.SignedAt = verify.Format, verify.TypeAdmins, a.signedAt()
	next.Company, next.Sequence, next.Previous = ch.CompanyID(), cur.Sequence+1, hex.EncodeToString(prev[:])
	raw, err := verify.Marshal(next)
	if err != nil {
		return err
	}
	parsed, err := verify.ParseAdmins(raw)
	if err != nil {
		return a.fail("err.badlist", err.Error())
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	a.say("admins.next", parsed.Sequence, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	for _, line := range describe(cur, parsed) {
		a.say("line", line)
	}
	a.warnFewKeys(parsed)
	mine, err := a.myKeys(s)
	if err != nil {
		return err
	}
	if !slices.ContainsFunc(mine, func(k home.Key) bool { return hasKey(parsed, k.ID) }) {
		a.say("admins.nolocal")
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	d, pin, err := a.device()
	if err != nil {
		return err
	}
	defer d.Close()
	allowed := map[string]verify.PublicKey{}
	for id, k := range ch.AdminKeys() {
		allowed[id] = k.Key
	}
	signed, err := a.signWith(d, pin, raw, allowed, mine)
	if err != nil {
		return err
	}
	longer := &verify.Chain{Company: ch.Company, Lists: slices.Clone(ch.Lists), Signed: slices.Clone(ch.Signed)}
	if err := longer.Extend(signed); err != nil {
		return err
	}
	if err := s.client.Append(ctx, c.ID, signed); err != nil {
		return a.apiErr(s, err)
	}
	if err := a.Home.SetCompany(h, longer); err != nil {
		return err
	}
	a.say("admins.signed", parsed.Sequence, show.Visible(h.Name))
	return nil
}

func hasKey(l *verify.Admins, id string) bool {
	for _, ad := range l.Administrators {
		if slices.ContainsFunc(ad.Keys, func(x verify.Key) bool { return x.ID == id }) {
			return true
		}
	}
	return false
}
