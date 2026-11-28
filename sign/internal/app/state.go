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

// loadState brings the state held up to the server's newest: a newer one is checked as a computer will (a key of
// the newest admin list, a higher serial), its changes are shown in short, and it is kept. Another state with the
// serial held is an alarm; an older one means the server is behind.
func (a *App) loadState(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain) (*verify.State, int64, error) {
	srv, reported, err := s.client.State(ctx, c.ID)
	if err != nil {
		return nil, 0, a.apiErr(s, err)
	}
	held := parseState(h.State)
	name := show.Visible(h.Name)
	switch {
	case srv == nil && held == nil:
		return nil, reported, nil
	case srv == nil:
		a.say("state.behind", name, 0, held.Serial)
		return held, reported, nil
	}
	got := parseState(srv)
	switch {
	case got == nil:
		return held, reported, a.fail("state.bad", name, "not a state")
	case held != nil && got.Serial == held.Serial:
		if !bytes.Equal(srv.Statement, h.State.Statement) {
			return held, reported, a.failAs(verify.ErrForkedChain, "state.forked", name, held.Serial)
		}
		return held, reported, nil
	case held != nil && got.Serial < held.Serial:
		a.say("state.behind", name, got.Serial, held.Serial)
		return held, reported, nil
	}
	var last int64
	if held != nil {
		last = held.Serial
	}
	st, err := ch.VerifyState(*srv, last)
	if err != nil {
		return held, reported, a.fail("state.bad", name, err.Error())
	}
	a.say("state.new", st.Serial, show.Visible(ch.AdminKeys()[srv.Key].Name), st.SignedAt.Local().Format("2006-01-02 15:04"))
	lines, _ := a.describeState(ctx, s, c, held, st, false)
	for _, l := range lines {
		a.say("line", l)
	}
	h.State = srv
	if err := a.Home.SetCompany(h, ch); err != nil {
		return nil, 0, err
	}
	return st, reported, nil
}

// nextSerial is one more than the highest serial known: the state held, the highest signed here, and the
// computers' reports, which may not take it more than MaxSerialJump above the other two.
func (a *App) nextSerial(h *home.Company, held *verify.State, reported int64) (int64, error) {
	known := h.Signed
	if held != nil {
		known = max(known, held.Serial)
	}
	if reported > known+MaxSerialJump {
		return 0, a.fail("err.serialjump", reported, known)
	}
	return max(known, reported) + 1, nil
}

func isText(b []byte) bool { return utf8.Valid(b) && !bytes.ContainsRune(b, 0) }

// describeState is what changes from the state held to the next, every name and line shown visibly. With full,
// every new or changed file is shown: a text file whole when new and as its changed lines otherwise, its content
// fetched from the server and checked against its hash; without, only which files change. It is false when a
// file couldn't be shown: such a state isn't signed.
func (a *App) describeState(ctx context.Context, s *session, c api.Company, old, next *verify.State, full bool) ([]string, bool) {
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
	if old.Release != next.Release {
		add("%s", a.t("state.release", next.Release))
	}
	if old.Version.Name != next.Version.Name || !maps.Equal(old.Version.Files, next.Version.Files) {
		if old.Version.Name == "" {
			add("%s", a.t("state.versionfirst", show.Visible(next.Version.Name)))
		} else {
			add("%s", a.t("state.version", show.Visible(old.Version.Name), show.Visible(next.Version.Name)))
		}
		for _, l := range pathChanges(old.Version.Files, next.Version.Files) {
			add("    %s", l)
		}
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
		h, before := next.Files[p], old.Files[p]
		if h == before {
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
		lines, ok := a.fileLines(ctx, s, c, mark, p, before, h)
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

func pathChanges(old, next map[string]string) []string {
	var out []string
	for _, p := range slices.Sorted(maps.Keys(next)) {
		switch old[p] {
		case next[p]:
		case "":
			out = append(out, "+ "+show.Visible(p))
		default:
			out = append(out, "~ "+show.Visible(p))
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
		return []string{head + " " + a.t("state.binary", len(content))}, true
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
	held, reported, err := a.loadState(ctx, s, c, h, ch)
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
	d := ds[n]
	switch d.Type {
	case verify.TypeState:
		return a.signState(ctx, s, c, h, ch, held, reported, d)
	}
	return a.fail("err.drafttype", show.Visible(d.Type))
}

// signState builds the next state from a draft, shows what it changes from the state held, asks for what only the
// administrator can give (the start of each new computer's id, the values of new secrets), and signs it.
func (a *App) signState(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain,
	held *verify.State, reported int64, d api.Draft) error {
	var dr stateDraft
	if err := json.Unmarshal(d.Body, &dr, json.RejectUnknownMembers(true)); err != nil {
		return a.fail("err.baddraft", show.Clip(err.Error(), 200))
	}
	serial, err := a.nextSerial(h, held, reported)
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
	for _, n := range dr.Secrets {
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
	lines, shown := a.describeState(ctx, s, c, held, &next, true)
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
	var last int64
	if held != nil {
		last = held.Serial
	}
	if _, err := ch.VerifyState(signed, last); err != nil {
		return err
	}
	// The serial counts as used once signed, whether or not the server takes the state.
	h.Signed = max(h.Signed, serial)
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	if _, err := s.client.SubmitState(ctx, c.ID, signed, d.ID, secrets); err != nil {
		if api.Status(err) == http.StatusConflict {
			return a.fail("err.statetaken", err.Error())
		}
		return a.apiErr(s, err)
	}
	h.State = &signed
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	a.say("state.signed", serial, show.Visible(h.Name))
	return nil
}
