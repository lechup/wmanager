package app

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/lechup/wmanager/verify"
)

func TestAddFile(t *testing.T) {
	w := setup(t)
	srv, acme := w.srv, w.company
	o3 := verify.Computer{ID: computerID("OFFICE-03"), Name: "OFFICE-03", Groups: []string{"office"}}
	if _, err := w.anna.run("", "add-file", "Acme", "drivers/x.cab", "/nonexistent"); err == nil || !strings.Contains(err.Error(), "No state") {
		t.Fatalf("add-file before a state: %v", err)
	}
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{}))
	w.anna.must("1\n"+o3.ID[:8]+"\nyes\n", "sign", "Acme")

	local := filepath.Join(t.TempDir(), "x.cab")
	os.WriteFile(local, []byte{0x4d, 0x5a, 0, 1, 2, 3}, 0o600)
	out := w.anna.must("yes\n", "add-file", "Acme", "drivers/x.cab", local)
	if !strings.Contains(out, "+ drivers/x.cab (added here with add-file from "+local+", 6 bytes)") || !strings.Contains(out, "State 2 of Acme is signed") {
		t.Fatalf("add-file: %s", out)
	}
	// The next state from the panel keeps the file: unchanged, nothing to show.
	srv.Draft(w.anna.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{"drivers/x.cab": hashOf([]byte{0x4d, 0x5a, 0, 1, 2, 3})}))
	if out := w.anna.must("1\nyes\n", "sign", "Acme"); !strings.Contains(out, "State 3 of Acme is signed") || strings.Contains(out, "x.cab") {
		t.Fatalf("a state keeping the file: %s", out)
	}
	// Bob didn't add it: a draft that adds it at another path can't be shown to him, so he doesn't sign it.
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	w.bob.must("", "")
	srv.Draft(w.bob.account, acme, "state", draft([]verify.Computer{o3}, map[string]string{
		"drivers/x.cab": hashOf([]byte{0x4d, 0x5a, 0, 1, 2, 3}), "drivers/y.cab": hashOf([]byte{0x4d, 0x5a, 0, 1, 2, 3})}))
	if _, err := w.bob.run("1\nyes\n", "sign", "Acme"); err == nil || !strings.Contains(err.Error(), "Not every file") {
		t.Fatalf("a file another administrator added, at a new path: %v", err)
	}
	// A bad path, and something that isn't a file.
	if _, err := w.anna.run("yes\n", "add-file", "Acme", "../x.cab", local); err == nil || !strings.Contains(err.Error(), "isn't valid") {
		t.Fatalf("a bad path: %v", err)
	}
	if _, err := w.anna.run("yes\n", "add-file", "Acme", "drivers/z.cab", t.TempDir()); err == nil || !strings.Contains(err.Error(), "isn't a file") {
		t.Fatalf("a folder: %v", err)
	}
}

func hashOf(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
