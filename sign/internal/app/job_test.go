package app

import (
	"strings"
	"testing"
	"time"

	"github.com/lechup/wmanager/verify"
)

// withState is a world whose first state, signed by Anna, has OFFICE-03 (office) and OFFICE-07 (office, finance)
// and the secret wifi.
func withState(t *testing.T) (*world, verify.Computer, verify.Computer) {
	w := setup(t)
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	o7 := verify.Computer{ID: computerID("OFFICE-07"), Name: "OFFICE-07", Groups: []string{"office", "finance"}}
	w.srv.Draft(w.anna.account, w.company, "state", draft([]verify.Computer{o3, o7}, map[string]string{}, "wifi"))
	w.anna.secrets = []string{"pw", "pw"}
	w.anna.must("1\n"+o3.ID[:8]+"\n"+o7.ID[:8]+"\nyes\n", "sign", "Acme")
	return w, o3, o7
}

func jobDraftOf(script string, computers, groups []string, secrets ...string) map[string]any {
	if secrets == nil {
		secrets = []string{}
	}
	return map[string]any{"computers": computers, "groups": groups, "script": script, "run_as": "system",
		"secrets": secrets, "valid_for": 86400, "limit": 600}
}

func TestJobsAndStops(t *testing.T) {
	w, o3, o7 := withState(t)
	srv, acme := w.srv, w.company
	script := srv.File(w.anna.account, acme, []byte("Restart-Service Spooler\nWrite-Output 'done\u202e'\n"))
	srv.Draft(w.anna.account, acme, "job", jobDraftOf(script, []string{}, []string{"finance"}, "wifi"))
	out := w.anna.must("1\nyes\n", "sign", "Acme")
	for _, want := range []string{"Computers (1): OFFICE-07", "from the groups finance", "Runs as SYSTEM", "Secrets it may use: wifi",
		"The script (2 lines):", "1 | Restart-Service Spooler", "2 | Write-Output 'done<U+202E>'", "is signed and with the server"} {
		if !strings.Contains(out, want) {
			t.Errorf("the job doesn't show %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "OFFICE-03") {
		t.Errorf("a computer outside the group:\n%s", out)
	}

	// A job by computer and group together.
	srv.Draft(w.anna.account, acme, "job", jobDraftOf(script, []string{o3.ID}, []string{"finance"}))
	if out := w.anna.must("1\nyes\n", "sign", "Acme"); !strings.Contains(out, "Computers (2): ") {
		t.Fatalf("by computer and group: %s", out)
	}

	// The stop of the first job, on OFFICE-07.
	js, err := jobsOf(t, w)
	if err != nil {
		t.Fatal(err)
	}
	var first *verify.Job
	for _, j := range js {
		if len(j.Computers) == 1 {
			first = j
		}
	}
	srv.Draft(w.anna.account, acme, "stop", map[string]any{"job": first.ID, "computers": []string{o7.ID}})
	out = w.anna.must("1\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "Stop job "+first.ID) || !strings.Contains(out, "by Anna, which runs") ||
		!strings.Contains(out, "Computers (1): OFFICE-07") || !strings.Contains(out, "The stop of job") {
		t.Fatalf("the stop: %s", out)
	}
	// A stop on a computer the job doesn't run on.
	srv.Draft(w.anna.account, acme, "stop", map[string]any{"job": first.ID, "computers": []string{o3.ID}})
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "doesn't run on") {
		t.Fatalf("a stop on another computer: %v", err)
	}
}

// jobsOf is the jobs the server has, as Anna's wmanager-sign would see them.
func jobsOf(t *testing.T, w *world) ([]*verify.Job, error) {
	t.Helper()
	s, err := w.anna.session()
	if err != nil {
		return nil, err
	}
	signed, err := s.client.Jobs(t.Context(), w.company)
	if err != nil {
		return nil, err
	}
	var out []*verify.Job
	for _, js := range signed {
		j, err := verify.ParseJob(js.Statement)
		if err != nil {
			return nil, err
		}
		out = append(out, j)
	}
	return out, nil
}

func TestJobRefusals(t *testing.T) {
	w, o3, _ := withState(t)
	srv, acme := w.srv, w.company
	script := srv.File(w.anna.account, acme, []byte("Write-Output 'x'\n"))
	for name, c := range map[string]struct {
		draft map[string]any
		want  string
	}{
		"a computer not in the state": {jobDraftOf(script, []string{computerID("OFFICE-99")}, nil), "isn't in the state"},
		"an empty group":              {jobDraftOf(script, nil, []string{"nobody"}), "No computer of the state"},
		"a secret not in the state":   {jobDraftOf(script, []string{o3.ID}, nil, "vpn"), "The secret vpn"},
		"a script not here":           {jobDraftOf(strings.Repeat("ee", 32), []string{o3.ID}, nil), "couldn't be fetched"},
		"a script not text":           {jobDraftOf(srv.File(w.anna.account, acme, []byte{0, 1, 2}), []string{o3.ID}, nil), "isn't text"},
		"valid too long": {func() map[string]any {
			d := jobDraftOf(script, []string{o3.ID}, nil)
			d["valid_for"] = int64((8 * 24 * time.Hour).Seconds())
			return d
		}(), "7 days"},
		"an unknown member": {func() map[string]any {
			d := jobDraftOf(script, []string{o3.ID}, nil)
			d["expires"] = "2099-01-01T00:00:00Z"
			return d
		}(), "isn't one wmanager-sign reads"},
	} {
		srv.Draft(w.anna.account, acme, "job", c.draft)
		_, err := w.anna.run("1\nyes\n", "sign", "Acme")
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", name, err)
		}
		w.srv.ClearDrafts(w.company) // the refused draft stays waiting

	}
	// A script the server changes on the way.
	srv.Draft(w.anna.account, acme, "job", jobDraftOf(script, []string{o3.ID}, nil))
	w.anna.rewriteFile = func(b []byte) []byte { return append(b, '!') }
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "doesn't match its hash") {
		t.Fatalf("a changed script: %v", err)
	}
}

func TestSecretSet(t *testing.T) {
	w, _, _ := withState(t)
	w.anna.secrets = []string{"new pw", "new pw"}
	out := w.anna.must("yes\n", "secret", "set", "Acme", "wifi")
	if !strings.Contains(out, "State 2 of Acme") || !strings.Contains(out, "~ wifi (a new value)") || !strings.Contains(out, "State 2 of Acme is signed") {
		t.Fatalf("secret set: %s", out)
	}
	w.anna.secrets = []string{"vpn pw", "vpn pw"}
	if out := w.anna.must("yes\n", "secret", "set", "Acme", "vpn"); !strings.Contains(out, "+ vpn") {
		t.Fatalf("a new secret: %s", out)
	}
	w.anna.secrets = []string{"x", "x"}
	if _, err := w.anna.run("yes\n", "secret", "set", "Acme", "bad name"); err == nil || !strings.Contains(err.Error(), "isn't valid") {
		t.Fatalf("a bad name: %v", err)
	}
	if out := w.bob.must("", ""); !strings.Contains(out, "state 3") {
		t.Fatalf("Bob: %s", out)
	}
}

// A stop shows the job it stops only once the job's signature checks: a server can't have a running job stopped
// by showing another one in its place.
func TestStopShowsTheSignedJob(t *testing.T) {
	w, o3, o7 := withState(t)
	srv, acme := w.srv, w.company
	firmware := srv.File(w.anna.account, acme, []byte("Update-Firmware -Now\n"))
	harmless := srv.File(w.anna.account, acme, []byte("Write-Output 'hello'\n"))
	d := jobDraftOf(firmware, []string{o3.ID, o7.ID}, nil)
	d["run_as"] = "user"
	d["start_after"] = "2020-01-01T00:00:00Z"
	srv.Draft(w.anna.account, acme, "job", d)
	out := w.anna.must("1\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "Runs as the signed-in user") || !strings.Contains(out, "From 2020-01-01") {
		t.Fatalf("a job as the user, from the past: %s", out)
	}
	js, _ := jobsOf(t, w)
	id := js[0].ID

	// The server shows the job with a harmless script: the signature doesn't check, nothing is signed.
	w.anna.rewriteJob = func(j *verify.Signed) {
		job, _ := verify.ParseJob(j.Statement)
		job.Script = harmless
		j.Statement, _ = verify.Marshal(job)
	}
	srv.Draft(w.anna.account, acme, "stop", map[string]any{"job": id, "computers": []string{o3.ID}})
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "isn't one signed by an administrator") {
		t.Fatalf("a forged job behind a stop: %v", err)
	}
	w.anna.rewriteJob = nil
	out = w.anna.must("1\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "1 | Update-Firmware -Now") || !strings.Contains(out, "Runs as the signed-in user") ||
		!strings.Contains(out, "Computers (2): ") {
		t.Fatalf("the stop: %s", out)
	}
	// The same stop again.
	srv.Draft(w.anna.account, acme, "stop", map[string]any{"job": id, "computers": []string{o3.ID}})
	// (The test's clock stands still, so it is the same statement, byte for byte.)
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "here already") {
		t.Fatalf("the same stop again: %v", err)
	}
}

// A job signed by an administrator removed since can still be stopped.
func TestStopAJobOfARemovedAdmin(t *testing.T) {
	w, o3, _ := withState(t)
	srv, acme := w.srv, w.company
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	script := srv.File(w.bob.account, acme, []byte("Write-Output 'x'\n"))
	srv.Draft(w.bob.account, acme, "job", jobDraftOf(script, []string{o3.ID}, nil))
	w.bob.must("1\nyes\n", "sign", "Acme")
	js, _ := jobsOf(t, w)
	w.anna.must("2\nyes\n", "admins", "remove", "Acme")
	srv.Draft(w.anna.account, acme, "stop", map[string]any{"job": js[0].ID, "computers": []string{o3.ID}})
	if out := w.anna.must("1\nyes\n", "sign", "Acme"); !strings.Contains(out, "by Bob, which runs") || !strings.Contains(out, "The stop of job") {
		t.Fatalf("stopping a removed admin's job: %s", out)
	}
}
