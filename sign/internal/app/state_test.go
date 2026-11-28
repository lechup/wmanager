package app

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"

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
	blob := srv.File(w.anna.account, acme, []byte{0x4d, 0x5a, 0, 1, 2})
	office3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{office3},
		map[string]string{"groups/office/hello.ps1": script, "drivers/x.cab": blob}, "wifi-office"))

	// Anna signs the first state: everything shown, the new computer's id typed, the secret's value typed twice.
	w.anna.secrets = []string{"the wifi password", "the wifi password"}
	out := w.anna.must("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme")
	for _, want := range []string{"State 1 of Acme", "The first state", "+ OFFICE-03 (" + office3.ID[:8] + "), groups: office",
		"+ groups/office/hello.ps1 (2 lines)", "1 + Write-Output 'hello'", "2 + Write-Output 'evil<U+202E>txt'",
		"+ drivers/x.cab (not text, 5 bytes)", "+ wifi-office", "wmanager's version: v1.0.0", "State 1 of Acme is signed"} {
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
		map[string]string{"groups/office/hello.ps1": script2, "drivers/x.cab": blob}, "wifi-office"))
	out = w.bob.must("1\n"+strings.ToUpper(office7.ID[:8])+"\nyes\n", "sign", "Acme")
	for _, want := range []string{"State 2 of Acme", "+ OFFICE-07", "- OFFICE-03", "~ groups/office/hello.ps1 (+1 -1)",
		"2 - Write-Output 'evil<U+202E>txt'", "2 + Write-Output 'bye'", "State 2 of Acme is signed"} {
		if !strings.Contains(out, want) {
			t.Errorf("the second state doesn't show %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "wifi-office") || strings.Contains(out, "drivers/x.cab") {
		t.Errorf("what doesn't change is shown as a change:\n%s", out)
	}
	if out := w.anna.must("", ""); !strings.Contains(out, "New state 2, signed by Bob") {
		t.Fatalf("Anna's status: %s", out)
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
	// A serial the server inflates.
	w.anna.rewriteState = func(_ **verify.Signed, reported *int64) { *reported = 5000 }
	if _, err := w.anna.run("1\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "inflating") {
		t.Fatalf("an inflated serial: %v", err)
	}
	// A serial reported a little higher counts.
	w.anna.rewriteState = func(_ **verify.Signed, reported *int64) { *reported = 41 }
	w.anna.secrets = []string{"v", "v"}
	if out := w.anna.must("1\n"+office3.ID[:8]+"\nyes\n", "sign", "Acme"); !strings.Contains(out, "State 42 of Acme is signed") {
		t.Fatalf("a reported serial: %s", out)
	}
	w.anna.rewriteState = nil
	if n := srv.Drafts(w.anna.account, acme); n != 0 {
		t.Fatalf("%d drafts", n)
	}

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
	if h, _, _ := w.bob.home.ByServer(srv.URL, acme); h == nil || h.StateSerial() != 42 {
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
