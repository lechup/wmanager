package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json/v2"
	"fmt"
	"maps"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// jobDraft is a single job as the panel prepares it. Its groups are turned into their computers here, from the
// state verified here, when it is signed: a computer added to a group later doesn't run it.
type jobDraft struct {
	Computers  []string  `json:"computers"` // ids
	Groups     []string  `json:"groups"`
	Script     string    `json:"script"` // the script's hash
	RunAs      string    `json:"run_as"`
	Secrets    []string  `json:"secrets"`
	StartAfter time.Time `json:"start_after,omitzero"` // none: at once
	ValidFor   int64     `json:"valid_for"`            // seconds after signing, at most 7 days
	Limit      int64     `json:"limit"`                // seconds it may run
}

// stopDraft stops a job on some of its computers.
type stopDraft struct {
	Job       string   `json:"job"`
	Computers []string `json:"computers"`
}

func (a *App) when(t time.Time) string { return t.Local().Format("2006-01-02 15:04") }

func computerNames(held *verify.State, ids []string) string {
	names := map[string]string{}
	for _, c := range held.Computers {
		names[c.ID] = c.Name
	}
	var out []string
	for _, id := range ids {
		n, ok := names[id]
		if !ok {
			n = "? (" + id[:8] + ")"
		}
		out = append(out, show.Visible(n))
	}
	return strings.Join(out, ", ")
}

// signJob builds a job from a draft: its computers from the state verified here, a random id, its times counted
// from now. It shows all of it, the script whole, and signs it.
func (a *App) signJob(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain,
	b *base, d api.Draft) error {
	held := b.st
	var dr jobDraft
	if err := json.Unmarshal(d.Body, &dr, json.RejectUnknownMembers(true)); err != nil {
		return a.fail("err.baddraft", show.Clip(err.Error(), 200))
	}
	if held == nil {
		return a.fail("err.nostate", show.Visible(h.Name))
	}
	// The computers: those named, and those of the groups, each in the state verified here.
	inState := map[string]bool{}
	for _, co := range held.Computers {
		inState[co.ID] = true
	}
	ids := map[string]bool{}
	for _, id := range dr.Computers {
		if !inState[id] {
			return a.fail("err.notinstate", show.Clip(id, 64))
		}
		ids[id] = true
	}
	for _, g := range dr.Groups {
		n := 0
		for _, co := range held.Computers {
			if slices.Contains(co.Groups, g) {
				ids[co.ID] = true
				n++
			}
		}
		if n == 0 {
			return a.fail("err.emptygroup", show.Visible(g))
		}
	}
	for _, n := range dr.Secrets {
		if held.Secrets[n] == "" {
			return a.fail("err.nosecret", show.Visible(n))
		}
	}
	if dr.ValidFor < 1 || dr.ValidFor > int64(verify.MaxJobLife/time.Second) {
		return a.fail("err.validfor")
	}
	script, err := a.fetch(ctx, s, c, dr.Script)
	if err != nil {
		return a.fail("err.noscript", err.Error())
	}
	if !isText(script) {
		return a.fail("err.scriptnottext")
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	now := a.signedAt()
	start := dr.StartAfter.UTC().Truncate(time.Second)
	if start.IsZero() {
		start = now
	}
	id := make([]byte, 16)
	rand.Read(id)
	computers := slices.Sorted(maps.Keys(ids))
	secrets := dr.Secrets
	if secrets == nil {
		secrets = []string{}
	}
	job := verify.Job{Format: verify.Format, Type: verify.TypeJob, SignedAt: now, Company: ch.CompanyID(),
		ID: hex.EncodeToString(id), Computers: computers, Script: dr.Script, RunAs: dr.RunAs, Secrets: secrets,
		StartAfter: start, Expires: now.Add(time.Duration(dr.ValidFor) * time.Second), Limit: dr.Limit}
	raw, err := verify.Marshal(job)
	if err != nil {
		return err
	}
	if _, err := verify.ParseJob(raw); err != nil {
		return a.fail("err.badjob", err.Error())
	}

	a.say("job.head", job.ID, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	a.say("job.computers", len(computers), computerNames(held, computers))
	if len(dr.Groups) > 0 {
		a.say("job.groups", show.Visible(strings.Join(dr.Groups, ", ")))
	}
	if job.RunAs == "user" {
		a.say("job.asuser")
	} else {
		a.say("job.assystem")
	}
	if len(secrets) > 0 {
		a.say("job.secrets", show.Visible(strings.Join(secrets, ", ")))
	}
	a.say("job.times", a.when(job.StartAfter), a.when(job.Expires), (time.Duration(job.Limit) * time.Second).String())
	lines := show.Lines(string(script))
	a.say("job.script", len(lines))
	for i, l := range lines {
		a.say("line", fmt.Sprintf("    %4d | %s", i+1, l))
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	signed, err := a.signAsAdmin(s, ch, raw)
	if err != nil {
		return err
	}
	if _, err := ch.VerifyJob(signed, ch.AdminKeys()); err != nil {
		return err
	}
	if err := s.client.SubmitJob(ctx, c.ID, signed, d.ID); err != nil {
		if api.Status(err) == http.StatusConflict {
			return a.fail("err.nottaken", err.Error())
		}
		return a.apiErr(s, err)
	}
	a.say("job.signed", job.ID[:8], show.Visible(h.Name))
	return nil
}

// signStop builds a stop of a job signed before, on some of its computers. The job is fetched by its id and its
// signature checked against the chain (an administrator removed since may have signed it), then shown whole.
func (a *App) signStop(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain,
	b *base, d api.Draft) error {
	held := b.st
	var dr stopDraft
	if err := json.Unmarshal(d.Body, &dr, json.RejectUnknownMembers(true)); err != nil {
		return a.fail("err.baddraft", show.Clip(err.Error(), 200))
	}
	if held == nil {
		return a.fail("err.nostate", show.Visible(h.Name))
	}
	if !jobIDRe.MatchString(dr.Job) {
		return a.fail("err.nojob", show.Clip(dr.Job, 32))
	}
	js, err := s.client.Job(ctx, c.ID, dr.Job)
	if api.Status(err) == http.StatusNotFound {
		return a.fail("err.nojob", dr.Job)
	}
	if err != nil {
		return a.apiErr(s, err)
	}
	signer := formerSigner(ch, js)
	job, perr := verify.ParseJob(js.Statement)
	if signer == "" || perr != nil || job.ID != dr.Job || job.Company != ch.CompanyID() {
		return a.fail("err.jobbad", dr.Job)
	}
	for _, id := range dr.Computers {
		if !slices.Contains(job.Computers, id) {
			return a.fail("err.notinjob", show.Clip(id, 64))
		}
	}
	script, err := a.fetch(ctx, s, c, job.Script)
	if err != nil {
		return a.fail("err.noscript", err.Error())
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	stop := verify.Stop{Format: verify.Format, Type: verify.TypeStop, SignedAt: a.signedAt(), Company: ch.CompanyID(),
		Job: job.ID, Computers: dr.Computers}
	raw, err := verify.Marshal(stop)
	if err != nil {
		return err
	}
	if _, err := verify.ParseStop(raw); err != nil {
		return a.fail("err.badjob", err.Error())
	}
	a.say("stop.head", job.ID, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	a.say("job.computers", len(dr.Computers), computerNames(held, dr.Computers))
	a.say("stop.job", a.when(job.SignedAt), show.Visible(signer))
	a.say("job.computers", len(job.Computers), computerNames(held, job.Computers))
	if job.RunAs == "user" {
		a.say("job.asuser")
	} else {
		a.say("job.assystem")
	}
	a.say("job.times", a.when(job.StartAfter), a.when(job.Expires), (time.Duration(job.Limit) * time.Second).String())
	lines := show.Lines(string(script))
	a.say("job.script", len(lines))
	for i, l := range lines {
		a.say("line", fmt.Sprintf("    %4d | %s", i+1, l))
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	signed, err := a.signAsAdmin(s, ch, raw)
	if err != nil {
		return err
	}
	if _, err := ch.VerifyStop(signed, ch.AdminKeys()); err != nil {
		return err
	}
	if err := s.client.SubmitStop(ctx, c.ID, signed, d.ID); err != nil {
		if api.Status(err) == http.StatusConflict || api.Status(err) == http.StatusNotFound {
			return a.fail("err.nottaken", err.Error())
		}
		return a.apiErr(s, err)
	}
	a.say("stop.signed", job.ID[:8], show.Visible(h.Name))
	return nil
}

var jobIDRe = regexp.MustCompile(`^[0-9a-f]{32}$`)

// setSecret makes the next state with a secret's new value, typed here, and signs it: the only change.
func (a *App) setSecret(ctx context.Context, which, name string) error {
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
	held := b.st
	if held == nil {
		return a.fail("err.nostate", show.Visible(h.Name))
	}
	serial, err := a.nextSerial(b)
	if err != nil {
		return err
	}
	if err := a.checkClock(ctx, s); err != nil {
		return err
	}
	next := *held
	next.SignedAt, next.Serial, next.Server = a.signedAt(), serial, s.client.Server
	next.Secrets = maps.Clone(held.Secrets)
	next.Secrets[name] = strings.Repeat("0", 64)
	if raw, err := verify.Marshal(next); err != nil {
		return err
	} else if _, err := verify.ParseState(raw); err != nil {
		return a.fail("err.badstate", err.Error())
	}
	typed, err := a.lackingValues(ctx, s, c, next.Secrets, []string{name})
	if err != nil {
		return err
	}
	typed = append([]string{name}, typed...)
	a.say("state.next", serial, show.Visible(h.Name), verify.Fingerprint(ch.Company))
	if !a.showNext(ctx, s, c, h, b, &next) {
		return a.fail("err.unshown")
	}
	var values []api.Secret
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
		values = append(values, api.Secret{Name: n, Salt: salt, Value: []byte(v)})
	}
	raw, err := verify.Marshal(next)
	if err != nil {
		return err
	}
	if ok, err := a.confirm("sign.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	signed, err := a.signAsAdmin(s, ch, raw)
	if err != nil {
		return err
	}
	return a.submitState(ctx, s, c, h, ch, b, signed, "", values)
}
