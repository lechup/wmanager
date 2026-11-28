package app

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

func computerID(name string) string {
	h := sha256.Sum256([]byte("computer " + name))
	return hex.EncodeToString(h[:])
}

// draft is a state draft as the panel will make it.
func draft(computers []verify.Computer, files map[string]string, secrets ...string) map[string]any {
	if secrets == nil {
		secrets = []string{}
	}
	return map[string]any{"computers": computers, "files": files,
		"version": verify.Version{Name: "v1.0.0", Files: map[string]string{"Provision.ps1": strings.Repeat("cd", 32)}},
		"release": strings.Repeat("ab", 32), "secrets": secrets}
}

func TestStates(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	srv, acme := w.srv, w.company

	script := srv.File(w.anna.account, acme, []byte("Write-Output 'hello'\nWrite-Output 'evil\u202etxt'\n"))
	list := srv.File(w.anna.account, acme, []byte("7zip\n"))
	office3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3},
		map[string]string{"groups/office/hello.ps1": script, "groups/office/choco-reqs.txt": list}, "wifi-office"))

	// Anna signs the first state: everything shown, the new computer's id typed, the secret's value typed twice.
	w.anna.secrets = []string{"the wifi password", "the wifi password"}
	out := w.anna.must("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme")
	for _, want := range []string{"State 1 of Acme", "The first state", "+ OFFICE-03 (" + office3.ID[:8] + "), groups: office",
		"+ groups/office/hello.ps1 (2 lines)", "1 + Write-Output 'hello'", "2 + Write-Output 'evil<U+202E>txt'",
		"+ groups/office/choco-reqs.txt (1 lines)", "+ wifi-office", "wmanager's version: v1.0.0",
		"+ Provision.ps1 " + strings.Repeat("cd", 32), "doesn't check the release certificate", "State 1 of Acme is signed"} {
		if !strings.Contains(out, want) {
			t.Errorf("the first state doesn't show %q:\n%s", want, out)
		}
	}
	if strings.ContainsRune(out, 0x202e) {
		t.Error("a bidirectional override reached the screen")
	}
	if srv.Drafts(w.anna.account, acme) != 0 {
		t.Fatal("the draft still waits")
	}

	// Bob sees the new state, signed by Anna, in short.
	out = w.bob.must("", "")
	if !strings.Contains(out, "New state 1, signed by Anna") || !strings.Contains(out, "+ groups/office/hello.ps1") ||
		strings.Contains(out, "Write-Output") || !strings.Contains(out, "state 1, 0 waiting") {
		t.Fatalf("Bob's status: %s", out)
	}

	// Bob signs the next one: a line of the script changed, a computer replaced; the secret keeps its value.
	script2 := srv.File(w.bob.account, acme, []byte("Write-Output 'hello'\nWrite-Output 'bye'\n"))
	office7 := verify.Computer{ID: computerID("OFFICE-07"), Name: "OFFICE-07", Groups: []string{"office", "finance"}}
	srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{office7},
		map[string]string{"groups/office/hello.ps1": script2, "groups/office/choco-reqs.txt": list}, "wifi-office"))
	out = w.bob.must("1\n"+strings.ToUpper(office7.ID[:8])+"\nyes\n", "sign", "Acme")
	for _, want := range []string{"State 2 of Acme", "+ OFFICE-07", "- OFFICE-03", "~ groups/office/hello.ps1 (+1 -1)",
		"2 - Write-Output 'evil<U+202E>txt'", "2 + Write-Output 'bye'", "State 2 of Acme is signed"} {
		if !strings.Contains(out, want) {
			t.Errorf("the second state doesn't show %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "wifi-office") || strings.Contains(out, "choco-reqs") || strings.Contains(out, "release") {
		t.Errorf("what doesn't change is shown as a change:\n%s", out)
	}
	if out := w.anna.must("", ""); !strings.Contains(out, "New state 2, signed by Bob") {
		t.Fatalf("Anna's status: %s", out)
	}

	// A new version of wmanager: each changed file's new hash, and that it isn't checked yet.
	d := draft([]verify.Computer{office7}, map[string]string{"groups/office/hello.ps1": script2, "groups/office/choco-reqs.txt": list}, "wifi-office")
	d["version"] = verify.Version{Name: "v1.1.0", Files: map[string]string{"Provision.ps1": strings.Repeat("ef", 32)}}
	srv.Draft(w.anna.account, acme, "state", d)
	out = w.anna.must("1\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "wmanager's version: v1.0.0 -> v1.1.0") || !strings.Contains(out, "~ Provision.ps1 "+strings.Repeat("ef", 32)) ||
		!strings.Contains(out, "doesn't check the release certificate") || strings.Contains(out, "The release certificate the computers accept changes") {
		t.Fatalf("a new version: %s", out)
	}
}

func TestStateRefusals(t *testing.T) {
	w := setup(t)
	srv, acme := w.srv, w.company
	script := srv.File(w.anna.account, acme, []byte("Write-Output 'hello'\n"))
	office3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3}, map[string]string{"a.ps1": script}, "wifi"))

	// The start of another id: nothing signed.
	w.anna.secrets = []string{"v", "v"}
	if _, err := w.anna.run("1\n00000000\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "not the start of the id") {
		t.Fatalf("a wrong id: %v", err)
	}
	// Two different values.
	w.anna.secrets = []string{"v", "w"}
	if _, err := w.anna.run("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "differ") {
		t.Fatalf("two values: %v", err)
	}
	// A file the server changed on the way: it doesn't match its hash, isn't shown, and nothing is signed.
	w.anna.rewriteFile = func(b []byte) []byte { return append(b, '!') }
	w.anna.secrets = []string{"v", "v"}
	if out, err := w.anna.run("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "Not every file") ||
		!strings.Contains(out, "doesn't match its hash") {
		t.Fatalf("a changed file: %v\n%s", err, out)
	}
	w.anna.rewriteFile = nil
	// The computers reporting a state the server doesn't show: what they have is unknown here, so nothing is signed.
	for _, reported := range []int64{41, 5000} {
		w.anna.rewriteState = func(_ **verify.Signed, r *int64) { *r = reported }
		if _, err := w.anna.run("1\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "newer than any known") {
			t.Fatalf("a reported state %d: %v", reported, err)
		}
	}
	w.anna.rewriteState = nil
	w.anna.secrets = []string{"v", "v"}
	if out := w.anna.must("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme"); !strings.Contains(out, "State 1 of Acme is signed") {
		t.Fatalf("the state: %s", out)
	}
	if n := srv.Drafts(w.anna.account, acme); n != 0 {
		t.Fatalf("%d drafts", n)
	}

	// A file that isn't text, from the panel: shown by its size only, so not signed.
	blob := srv.File(w.anna.account, acme, []byte{0xff, 0xfe, 'W', 0, 'r', 0})
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3}, map[string]string{"a.ps1": script, "x.ps1": blob}, "wifi"))
	if out, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "Not every file") ||
		!strings.Contains(out, "x.ps1 (not text, 6 bytes)") {
		t.Fatalf("a file that isn't text: %v\n%s", err, out)
	}
	srv.ClearDrafts(acme)
	// A secret named twice.
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3}, map[string]string{"a.ps1": script}, "wifi", "vpn", "vpn"))
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "named twice") {
		t.Fatalf("a secret twice: %v", err)
	}
	srv.ClearDrafts(acme)

	// A draft naming a file the server doesn't have can't be shown, so isn't signed.
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3}, map[string]string{"a.ps1": strings.Repeat("ee", 32)}, "wifi"))
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "Not every file") {
		t.Fatalf("a missing file: %v", err)
	}

	// Another state with the serial held is an alarm.
	k := w.anna.dev.Key(verify.KeyID(mustCOSE(t, w.anna)))
	w.bob.must("", "")
	w.bob.rewriteState = func(st **verify.Signed, _ *int64) {
		s, err := verify.ParseState((*st).Statement)
		if err != nil {
			t.Fatal(err)
		}
		s.Files = map[string]string{}
		raw, _ := verify.Marshal(s)
		other, err := k.SignStatement(raw, softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		*st = &other
	}
	if _, err := w.bob.run("", ""); err == nil || !strings.Contains(err.Error(), "ALARM") {
		t.Fatalf("another state with the same serial: %v", err)
	}
	// A newer state signed by a key not in the list isn't taken.
	stranger, _ := softkey.New(verify.ES256)
	w.bob.rewriteState = func(st **verify.Signed, _ *int64) {
		s, _ := verify.ParseState((*st).Statement)
		s.Serial++
		raw, _ := verify.Marshal(s)
		other, _ := stranger.SignStatement(raw, softkey.Options{})
		*st = &other
	}
	if out := w.bob.must("", ""); !strings.Contains(out, "doesn't check") {
		t.Fatalf("a state by a stranger: %s", out)
	}
	if h, _, _ := w.bob.home.ByServer(srv.URL, acme); h == nil || home.Serial(h.State) != 1 {
		t.Fatal("a state by a stranger was kept")
	}
	// A person, not an administrator, can't sign.
	carol := newPerson(t, srv, srv.Person("carol@example.com", acme, "person"))
	carol.connect()
	carol.must(w.fp+"\n", "company", "trust", "Acme")
	if _, err := carol.run("1\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "not an administrator") {
		t.Fatalf("a person signs: %v", err)
	}
}

// A server that hides a newer state can't have it reverted unseen: the computers' report of it stops signing, and
// a state signed here is the base of the next one even when the server hides it.
func TestHiddenStates(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	srv, acme := w.srv, w.company
	stolen := verify.Computer{ID: computerID("STOLEN"), Name: "STOLEN", Groups: []string{"office"}}
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{}))
	w.anna.must("1\n"+o3.ID[:8]+"\n"+stolen.ID[:8]+"\nyes\n", "sign", "Acme")
	var first *verify.Signed
	w.bob.rewriteState = func(st **verify.Signed, _ *int64) { first = *st }
	w.bob.must("", "")
	w.bob.rewriteState = nil
	// Bob removes STOLEN in state 2.
	srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}))
	w.bob.must("1\nyes\n", "sign", "Acme")

	// The server shows Anna state 1 and reports 2, with a draft that brings STOLEN back.
	w.anna.rewriteState = func(st **verify.Signed, r *int64) { *st, *r = first, 2 }
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{}))
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "report state 2") {
		t.Fatalf("a hidden state the computers report: %v", err)
	}
	srv.ClearDrafts(acme)
	w.anna.rewriteState = nil
	w.anna.must("", "") // Anna takes state 2

	// Anna signs state 3; the server keeps it but the answer is lost, then it shows her state 2.
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{"a.txt": srv.File(w.anna.account, acme, []byte("a\n"))}))
	w.anna.lose = true
	if _, err := w.anna.run("1\nyes\n", "sign", "Acme"); err == nil {
		t.Fatal("a lost answer")
	}
	w.anna.lose = false
	w.anna.rewriteState = func(st **verify.Signed, _ *int64) {
		s, _ := verify.ParseState((*st).Statement)
		if s.Serial == 3 {
			*st = nil // hidden
		}
	}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{"a.txt": srv.File(w.anna.account, acme, []byte("a\n"))}))
	out := w.anna.must("1\n"+stolen.ID[:8]+"\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "State 4 of Acme") || !strings.Contains(out, "+ STOLEN") || strings.Contains(out, "+ a.txt") {
		t.Fatalf("the next state after one hidden: %s", out)
	}
}

// A state signed by an administrator removed since doesn't stop the others signing.
func TestStateOfARemovedAdmin(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	srv, acme := w.srv, w.company
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}))
	w.bob.must("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme")
	// Anna removes Bob before she has seen his state.
	w.anna.must("2\nyes\n", "admins", "remove", "Acme")
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}))
	out := w.anna.must("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "signed by Bob, whose key is no longer in the admin list") || !strings.Contains(out, "State 2 of Acme is signed") ||
		!strings.Contains(out, "computers that have state 1, signed by Bob, removed since") {
		t.Fatalf("after a removed admin's state: %s", out)
	}
	// Bob's state removed STOLEN; Anna's next draft brings it back: shown for the computers that have Bob's.
	stolen := verify.Computer{ID: computerID("STOLEN"), Name: "STOLEN", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{}))
	if out := w.anna.must("1\n"+stolen.ID[:8]+"\nyes\n", "sign", "Acme"); !strings.Contains(out, "+ STOLEN") {
		t.Fatalf("a computer brought back: %s", out)
	}
	// A state with the serial held but not signed by an admin is only said, not an alarm.
	stranger, _ := softkey.New(verify.ES256)
	w.anna.rewriteState = func(st **verify.Signed, _ *int64) {
		s, _ := verify.ParseState((*st).Statement)
		s.Files = map[string]string{}
		raw, _ := verify.Marshal(s)
		o, _ := stranger.SignStatement(raw, softkey.Options{})
		*st = &o
	}
	if out, err := w.anna.run("", ""); err != nil || !strings.Contains(out, "doesn't check") {
		t.Fatalf("a stranger's state with the serial held: %v\n%s", err, out)
	}
}

// A state signed here that the server refused, or whose answer was lost, and another administrator's with its
// serial: no alarm, and the next state is shown against both.
func TestStateSignedHereAndAnother(t *testing.T) {
	for _, how := range []string{"refused", "lost"} {
		t.Run(how, func(t *testing.T) {
			w := setup(t)
			w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
			w.bob.must("", "")
			srv, acme := w.srv, w.company
			o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
			o7 := verify.Computer{ID: computerID("OFFICE-07"), Name: "OFFICE-07", Groups: []string{"office"}}
			srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}, "wifi"))
			w.anna.refuseOnly, w.anna.drop = how == "refused", how == "lost"
			w.anna.secrets = []string{"pw", "pw"}
			if _, err := w.anna.run("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme"); err == nil {
				t.Fatal("a state the server didn't get")
			}
			w.anna.refuseOnly, w.anna.drop = false, false
			srv.ClearDrafts(acme)
			srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{o7}, map[string]string{}))
			w.bob.must("1\n"+o7.ID[:8]+"\nyes\n", "sign", "Acme")
			out := w.anna.must("", "")
			if !strings.Contains(out, "Both may be on computers") || strings.Contains(out, "ALARM") {
				t.Fatalf("after Bob's state: %s", out)
			}
			// Anna's next state keeps the secret her state named: its value never reached the server, so it is typed
			// again.
			srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, o7}, map[string]string{}, "wifi"))
			w.anna.secrets = []string{"pw2", "pw2"}
			out = w.anna.must("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme")
			for _, want := range []string{"State 2 of Acme", "+ OFFICE-03", "What it changes for the computers that have state 1 signed here",
				"+ OFFICE-07", "State 2 of Acme is signed"} {
				if !strings.Contains(out, want) {
					t.Errorf("Anna's next state doesn't show %q:\n%s", want, out)
				}
			}
		})
	}
}

// A secret typed for a state that never reached the server is typed again for the next one.
func TestSecretValueLost(t *testing.T) {
	w := setup(t)
	srv, acme := w.srv, w.company
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}, "wifi"))
	w.anna.drop = true
	w.anna.secrets = []string{"pw", "pw"}
	if _, err := w.anna.run("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme"); err == nil {
		t.Fatal("a dropped state")
	}
	w.anna.drop = false
	w.anna.secrets = []string{"pw", "pw"}
	out := w.anna.must("1\nyes\n", "sign", "Acme")
	if !strings.Contains(out, "lacks the value of the secret wifi") || !strings.Contains(out, "~ wifi (a new value)") ||
		!strings.Contains(out, "State 2 of Acme is signed") {
		t.Fatalf("the next state: %s", out)
	}
}

// The review's case: Anna's state has STOLEN, Bob's next removes it, Anna removes Bob before she sees it, and her
// next draft brings STOLEN back. It is shown for the computers that took Bob's.
func TestRemovedAdminsStateNotUndoneUnseen(t *testing.T) {
	w := setup(t)
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	srv, acme := w.srv, w.company
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	stolen := verify.Computer{ID: computerID("STOLEN"), Name: "STOLEN", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{}))
	w.anna.must("1\n"+o3.ID[:8]+"\n"+stolen.ID[:8]+"\nyes\n", "sign", "Acme")
	w.bob.must("", "")
	srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}))
	w.bob.must("1\nyes\n", "sign", "Acme")
	w.anna.must("2\nyes\n", "admins", "remove", "Acme")
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3, stolen}, map[string]string{}))
	out := w.anna.must("1\nyes\n", "sign", "Acme")
	i := strings.Index(out, "computers that have state 2, signed by Bob")
	if i < 0 || !strings.Contains(out[i:], "+ STOLEN") || !strings.Contains(out, "State 3 of Acme is signed") {
		t.Fatalf("Bob's state undone unseen: %s", out)
	}
}
