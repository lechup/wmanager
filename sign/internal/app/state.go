package app

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/diff"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// MaxSerialJump is how far above the highest serial wmanager-sign knows the computers' reports may take the next
// one: a report through the server above that is a server inflating it, and is refused.
const MaxSerialJump = 1000

// stateDraft is a state as the panel prepares it: everything but what wmanager-sign sets itself (the format, type,
// time, company, serial and server) and the secrets' hashes, which come from the state held or from values typed.
type stateDraft struct {
	Computers []verify.Computer `json:"computers"`
	Files     map[string]string `json:"files"`
	Version   verify.Version    `json:"version"`
	Release   string            `json:"release"`
	Secrets   []string          `json:"secrets"` // the names the state has
}

func parseState(s *verify.Signed) *verify.State {
	if s == nil {
		return nil
	}
	st, err := verify.ParseState(s.Statement)
	if err != nil {
		return nil
	}
	return st
}

// base is what the next state is built on and shown against: the newer of the state verified here and the one
// signed here (which the server may not show, or may have refused), and the serials known.
type base struct {
	signed   *verify.Signed
	st       *verify.State
	known    int64 // the base's serial, or a newer one a key removed since signed
	reported int64 // the highest serial the computers report, through the server
}

func baseOf(h *home.Company, reported int64) *base {
	signed := home.Newer(h.State, h.Mine)
	return &base{signed: signed, st: parseState(signed), known: home.Serial(signed), reported: reported}
}

// formerSigner is the name an earlier admin list of the chain gives the key that signed a statement, when its
// signature checks with that key; "" otherwise.
func formerSigner(ch *verify.Chain, s verify.Signed) string {
	for i := len(ch.Lists) - 1; i >= 0; i-- {
		for _, ad := range ch.Lists[i].Administrators {
			for _, k := range ad.Keys {
				if k.ID != s.Key {
					continue
				}
				pk, err := k.PublicKey()
				if err == nil && verify.CheckAssertion(s.Hash(), verify.Assertion{AuthenticatorData: s.AuthenticatorData,
					ClientDataJSON: s.ClientDataJSON, Signature: s.Signature}, pk) == nil {
					return ad.Name
				}
			}
		}
	}
	return ""
}

// loadState brings what is known of the company's state up to the server's newest: a newer one signed by a key of
// the newest admin list is shown in short and kept. One signed by a key removed since isn't taken (the computers
// refuse it), but its serial is counted; one that doesn't check is only said. Another state with the serial held
// is an alarm. A server that is behind gets the newest state known here, when the account may give it.
func (a *App) loadState(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain) (*base, error) {
	srv, reported, err := s.client.State(ctx, c.ID)
	if err != nil {
		return nil, a.apiErr(s, err)
	}
	cur := baseOf(h, reported)
	name := show.Visible(h.Name)
	if srv == nil {
		if cur.st != nil {
			a.say("state.behind", name, 0, cur.known)
			a.pushState(ctx, s, c, cur)
		}
		return cur, nil
	}
	got := parseState(srv)
	if got == nil || got.Company != ch.CompanyID() {
		a.say("state.bad", name, a.t("state.notours"))
		return cur, nil
	}
	if _, err := ch.VerifyState(*srv, 0); err != nil {
		if signer := formerSigner(ch, *srv); signer != "" {
			a.say("state.oldkey", name, got.Serial, show.Visible(signer))
			if got.Serial > cur.known && got.Serial <= cur.known+MaxSerialJump {
				cur.known = got.Serial
			}
		} else {
			a.say("state.bad", name, err.Error())
		}
		return cur, nil
	}
	switch {
	case cur.st != nil && got.Serial == cur.st.Serial && !bytes.Equal(srv.Statement, cur.signed.Statement):
		if cur.signed != h.Mine || !h.MineRefused {
			return nil, a.failAs(verify.ErrForkedChain, "state.forked", name, got.Serial)
		}
		// The server refused the state signed here, and has another administrator's with its serial.
		a.say("state.minereplaced", name, got.Serial)
		h.DropMine()
	case cur.st != nil && got.Serial == cur.st.Serial:
		if h.State == nil || !bytes.Equal(h.State.Statement, srv.Statement) {
			h.State, h.MineRefused = srv, false // the server has the state signed here
			if err := a.Home.SetCompany(h, ch); err != nil {
				return nil, err
			}
		}
		return cur, nil
	case cur.st != nil && got.Serial < cur.st.Serial:
		a.say("state.behind", name, got.Serial, cur.st.Serial)
		a.pushState(ctx, s, c, cur)
		return cur, nil
	default:
		a.say("state.new", got.Serial, show.Visible(ch.AdminKeys()[srv.Key].Name), got.SignedAt.Local().Format("2006-01-02 15:04"))
		lines, _ := a.describeState(ctx, s, c, h, cur.st, got, false)
		for _, l := range lines {
			a.say("line", l)
		}
	}
	h.State = srv
	if err := a.Home.SetCompany(h, ch); err != nil {
		return nil, err
	}
	return baseOf(h, reported), nil
}

// pushState gives a server that is behind the newest state known here; a server that refuses it (it may lack a
// secret's value) is only said.
func (a *App) pushState(ctx context.Context, s *session, c api.Company, b *base) {
	if c.Role != "admin" || b.signed == nil {
		return
	}
	if _, err := s.client.SubmitState(ctx, c.ID, *b.signed, "", nil); err != nil {
		a.say("state.pushfailed", err.Error())
		return
	}
	a.say("state.pushed", b.known)
}

// nextSerial is one more than the highest serial known. A computer reporting a newer state than any known here is
// a state the server doesn't show: the next one can't be shown against what the computers have, so it isn't signed.
func (a *App) nextSerial(b *base) (int64, error) {
	if b.reported > b.known {
		return 0, a.fail("err.reportednewer", b.reported, b.known)
	}
	return b.known + 1, nil
}

func isText(b []byte) bool { return utf8.Valid(b) && !bytes.ContainsRune(b, 0) }

// describeState is what changes from the state held to the next, every name and line shown visibly. With full,
// every new or changed file is shown: a text file whole when new and as its changed lines otherwise, its content
// fetched from the server and checked against its hash; without, only which files change. It is false when a
// file couldn't be shown: such a state isn't signed.
func (a *App) describeState(ctx context.Context, s *session, c api.Company, h *home.Company, old, next *verify.State, full bool) ([]string, bool) {
	var out []string
	shown := true
	add := func(format string, args ...any) { out = append(out, fmt.Sprintf(format, args...)) }
	if old == nil {
		old = &verify.State{Computers: []verify.Computer{}, Files: map[string]string{}, Secrets: map[string]string{}}
		add("%s", a.t("state.first"))
	}
	if old.Server != next.Server {
		add("%s", a.t("state.server", show.Visible(next.Server)))
	}
	unchecked := false
	if old.Release != next.Release {
		add("%s", a.t("state.release", next.Release))
		unchecked = true
	}
	if old.Version.Name != next.Version.Name || !maps.Equal(old.Version.Files, next.Version.Files) {
		if old.Version.Name == "" {
			add("%s", a.t("state.versionfirst", show.Visible(next.Version.Name)))
		} else {
			add("%s", a.t("state.version", show.Visible(old.Version.Name), show.Visible(next.Version.Name)))
		}
		for _, l := range pathChanges(old.Version.Files, next.Version.Files, full) {
			add("    %s", l)
		}
		unchecked = true
	}
	if unchecked && full {
		add("%s", a.t("state.unchecked"))
	}

	// Computers, by id.
	was := map[string]verify.Computer{}
	for _, co := range old.Computers {
		was[co.ID] = co
	}
	var comp []string
	now := map[string]bool{}
	for _, co := range next.Computers {
		now[co.ID] = true
		groups := show.Visible(strings.Join(co.Groups, ", "))
		p, ok := was[co.ID]
		switch {
		case !ok:
			comp = append(comp, fmt.Sprintf("+ %s (%s), %s", show.Visible(co.Name), co.ID[:8], a.t("state.groups", groups)))
		case p.Name != co.Name || !slices.Equal(p.Groups, co.Groups):
			comp = append(comp, fmt.Sprintf("~ %s -> %s (%s), %s", show.Visible(p.Name), show.Visible(co.Name), co.ID[:8],
				a.t("state.groups", groups)))
		}
	}
	for _, co := range old.Computers {
		if !now[co.ID] {
			comp = append(comp, fmt.Sprintf("- %s (%s)", show.Visible(co.Name), co.ID[:8]))
		}
	}
	if len(comp) > 0 {
		add("%s", a.t("state.computers"))
		for _, l := range comp {
			add("  %s", l)
		}
	}

	// Files, by path.
	paths := slices.Sorted(maps.Keys(next.Files))
	var files []string
	for _, p := range paths {
		hash, before := next.Files[p], old.Files[p]
		if hash == before {
			continue
		}
		mark := "~"
		if before == "" {
			mark = "+"
		}
		if !full {
			files = append(files, mark+" "+show.Visible(p))
			continue
		}
		lines, ok := a.fileLines(ctx, s, c, mark, p, before, hash)
		files, shown = append(files, lines...), shown && ok
	}
	for _, p := range slices.Sorted(maps.Keys(old.Files)) {
		if _, ok := next.Files[p]; !ok {
			files = append(files, "- "+show.Visible(p))
		}
	}
	if len(files) > 0 {
		add("%s", a.t("state.files"))
		for _, l := range files {
			add("  %s", l)
		}
	}

	// Secrets, by name.
	var secs []string
	for _, n := range slices.Sorted(maps.Keys(next.Secrets)) {
		switch old.Secrets[n] {
		case next.Secrets[n]:
		case "":
			secs = append(secs, "+ "+show.Visible(n))
		default:
			secs = append(secs, "~ "+show.Visible(n)+" "+a.t("state.newvalue"))
		}
	}
	for _, n := range slices.Sorted(maps.Keys(old.Secrets)) {
		if _, ok := next.Secrets[n]; !ok {
			secs = append(secs, "- "+show.Visible(n))
		}
	}
	if len(secs) > 0 {
		add("%s", a.t("state.secrets"))
		for _, l := range secs {
			add("  %s", l)
		}
	}
	if len(out) == 0 {
		add("%s", a.t("state.nochange"))
	}
	return out, shown
}

// pathChanges is what changes among files known by their hashes; with hashes, each new hash is shown too.
func pathChanges(old, next map[string]string, hashes bool) []string {
	var out []string
	with := func(p, h string) string {
		if hashes {
			return show.Visible(p) + " " + h
		}
		return show.Visible(p)
	}
	for _, p := range slices.Sorted(maps.Keys(next)) {
		switch old[p] {
		case next[p]:
		case "":
			out = append(out, "+ "+with(p, next[p]))
		default:
			out = append(out, "~ "+with(p, next[p]))
		}
	}
	for _, p := range slices.Sorted(maps.Keys(old)) {
		if _, ok := next[p]; !ok {
			out = append(out, "- "+show.Visible(p))
		}
	}
	return out
}

// fileLines shows a new or changed file: a text file whole when new, its changed lines with two around each
// otherwise; anything else by its size. It is false when the file couldn't be fetched, and so wasn't shown.
func (a *App) fileLines(ctx context.Context, s *session, c api.Company, mark, path, before, after string) ([]string, bool) {
	head := mark + " " + show.Visible(path)
	content, err := a.fetch(ctx, s, c, after)
	if err != nil {
		return []string{head, "    " + a.t("state.nofile", err.Error())}, false
	}
	if !isText(content) {
		// A file that isn't text can't be shown: one comes only with add-file, from the administrator's own disk.
		return []string{head + " " + a.t("state.binary", len(content))}, false
	}
	newLines := strings.Split(strings.TrimSuffix(string(content), "\n"), "\n")
	if before == "" {
		out := []string{head + " " + a.t("state.lines", len(newLines))}
		for i, l := range show.Lines(string(content)) {
			out = append(out, fmt.Sprintf("    %4d + %s", i+1, l))
		}
		return out, true
	}
	old, err := a.fetch(ctx, s, c, before)
	if err != nil || !isText(old) {
		// The old content is gone from the server, or wasn't text: the new one is shown whole.
		out := []string{head + " " + a.t("state.lines", len(newLines)) + " " + a.t("state.noold")}
		for i, l := range show.Lines(string(content)) {
			out = append(out, fmt.Sprintf("    %4d + %s", i+1, l))
		}
		return out, true
	}
	oldLines := strings.Split(strings.TrimSuffix(string(old), "\n"), "\n")
	edits := diff.Lines(oldLines, newLines)
	added, removed := diff.Count(edits)
	out := []string{fmt.Sprintf("%s (+%d -%d)", head, added, removed)}
	if bytes.HasSuffix(old, []byte("\n")) != bytes.HasSuffix(content, []byte("\n")) {
		out = append(out, "    "+a.t("state.newline"))
	}
	for i, hunk := range diff.Hunks(edits, 2) {
		if i > 0 {
			out = append(out, "    ...")
		}
		for _, e := range hunk {
			out = append(out, fmt.Sprintf("    %4d %c %s", e.Num, e.Op, show.Visible(e.Line)))
		}
	}
	return out, true
}

func (a *App) fetch(ctx context.Context, s *session, c api.Company, hexHash string) ([]byte, error) {
	var h [32]byte
	if b, err := hex.DecodeString(hexHash); err != nil || len(b) != 32 {
		return nil, errors.New("not a hash")
	} else {
		copy(h[:], b)
	}
	return s.client.File(ctx, c.ID, h)
}

// sign signs one of the company's drafts, after showing it.
func (a *App) signDraft(ctx context.Context, which string) error {
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
	b, err := a.loadState(ctx, s, c, h, ch)
	if err != nil {
		return err
	}
	ds, err := s.client.Drafts(ctx, c.ID)
	if err != nil {
		return a.apiErr(s, err)
	}
	if len(ds) == 0 {
		a.say("sign.nodrafts", show.Visible(h.Name))
		return nil
	}
	for i, d := range ds {
		a.say("sign.draft", i+1, show.Visible(d.Type), show.Visible(d.CreatedBy), d.CreatedAt.Local().Format("2006-01-02 15:04"))
	}
	n, err := a.choose(len(ds), "sign.which")
	if err != nil {
		return err
	}
	d, err := s.client.Draft(ctx, c.ID, ds[n].ID)
	if err != nil {
		return a.apiErr(s, err)
	}
	if d.ID != ds[n].ID || d.Type != ds[n].Type {
		return a.fail("err.baddraft", "not the draft chosen")
	}
	switch d.Type {
	case verify.TypeState:
		return a.signState(ctx, s, c, h, ch, b, d)
	}
	return a.fail("err.drafttype", show.Visible(d.Type))
}

// signState builds the next state from a draft, shows what it changes from the state held, asks for what only the
// administrator can give (the start of each new computer's id, the values of new secrets), and signs it.
func (a *App) signState(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain,
	b *base, d api.Draft) error {
	var dr stateDraft
	if err := json.Unmarshal(d.Body, &dr, json.RejectUnknownMembers(true)); err != nil {
		return a.fail("err.baddraft", show.Clip(err.Error(), 200))
	}
	held := b.st
	serial, err := a.nextSerial(b)
	if err != nil {
		return err
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	next := verify.State{Format: verify.Format, Type: verify.TypeState, SignedAt: a.signedAt(), Company: ch.CompanyID(),
		Serial: serial, Server: s.client.Server, Release: dr.Release, Computers: dr.Computers, Files: dr.Files,
		Version: dr.Version, Secrets: map[string]string{}}
	if next.Computers == nil {
		next.Computers = []verify.Computer{}
	}
	if next.Files == nil {
		next.Files = map[string]string{}
	}
	if next.Version.Files == nil {
		next.Version.Files = map[string]string{}
	}
	var typed []string
	seen := map[string]bool{}
	for _, n := range dr.Secrets {
		if seen[n] {
			return a.fail("err.badstate", "a secret named twice")
		}
		seen[n] = true
		if held != nil && held.Secrets[n] != "" {
			next.Secrets[n] = held.Secrets[n]
		} else {
			next.Secrets[n] = strings.Repeat("0", 64) // typed below, once the state is known to be valid
			typed = append(typed, n)
		}
	}
	raw, err := verify.Marshal(next)
	if err != nil {
		return err
	}
	if _, err := verify.ParseState(raw); err != nil {
		return a.fail("err.badstate", err.Error())
	}
	if len(raw) > verify.MaxSize[verify.TypeState] {
		return a.fail("err.badstate", "too large")
	}

	a.say("state.next", serial, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	lines, shown := a.describeState(ctx, s, c, h, held, &next, true)
	for _, l := range lines {
		a.say("line", l)
	}
	if !shown {
		return a.fail("err.unshown")
	}

	// A new computer is added only with the start of its id typed, as its installer showed it: the server can't
	// swap two waiting computers.
	known := map[string]bool{}
	if held != nil {
		for _, co := range held.Computers {
			known[co.ID] = true
		}
	}
	for _, co := range next.Computers {
		if known[co.ID] {
			continue
		}
		got, err := a.ask("state.typeid", show.Visible(co.Name))
		if err != nil {
			return err
		}
		if !strings.EqualFold(strings.TrimSpace(got), co.ID[:8]) {
			return a.fail("err.idmismatch", show.Visible(co.Name))
		}
	}
	// New secrets' values, typed twice, each with a salt of its own.
	var secrets []api.Secret
	for _, n := range typed {
		v, err := a.ReadSecret(a.t("state.secretvalue", show.Visible(n)))
		if err != nil {
			return err
		}
		again, err := a.ReadSecret(a.t("state.secretagain"))
		if err != nil {
			return err
		}
		if v == "" || v != again {
			return a.fail("err.secretmismatch", show.Visible(n))
		}
		salt := make([]byte, verify.SecretSaltSize)
		rand.Read(salt)
		next.Secrets[n] = verify.SecretHash(ch.CompanyID(), n, salt, []byte(v))
		secrets = append(secrets, api.Secret{Name: n, Salt: salt, Value: []byte(v)})
	}
	if raw, err = verify.Marshal(next); err != nil {
		return err
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	d2, pin, err := a.device()
	if err != nil {
		return err
	}
	defer d2.Close()
	allowed := map[string]verify.PublicKey{}
	for id, k := range ch.AdminKeys() {
		allowed[id] = k.Key
	}
	mine, err := a.myKeys(s)
	if err != nil {
		return err
	}
	signed, err := a.signWith(d2, pin, raw, allowed, mine)
	if err != nil {
		return err
	}
	return a.submitState(ctx, s, c, h, ch, b, signed, d.ID, secrets)
}

// submitState keeps a state signed here as the base of the next one, before the server has it (the server may
// keep it and answer otherwise), then gives it to the server.
func (a *App) submitState(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain, b *base,
	signed verify.Signed, draft string, secrets []api.Secret) error {
	st, err := ch.VerifyState(signed, b.known)
	if err != nil {
		return err
	}
	h.Mine, h.MineRefused = &signed, false
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	if _, err := s.client.SubmitState(ctx, c.ID, signed, draft, secrets); err != nil {
		if st := api.Status(err); st >= 400 && st < 500 && st != http.StatusUnauthorized {
			h.MineRefused = true
			if serr := a.Home.SetCompany(h, ch); serr != nil {
				return serr
			}
			return a.fail("err.nottaken", err.Error())
		}
		return a.apiErr(s, err)
	}
	h.State = &signed
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	a.say("state.signed", st.Serial, show.Visible(h.Name))
	return nil
}
