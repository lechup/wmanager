package app

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

var auditRe = regexp.MustCompile(`audit log: entry (\d+), (\d+) new`)

func auditOf(t *testing.T, out string) (seq, fresh int) {
	t.Helper()
	m := auditRe.FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("no audit line: %s", out)
	}
	seq, _ = strconv.Atoi(m[1])
	fresh, _ = strconv.Atoi(m[2])
	return seq, fresh
}

func TestAuditHead(t *testing.T) {
	w := setup(t)
	first, _ := auditOf(t, w.anna.must("", ""))
	if first < 1 {
		t.Fatalf("audit head %d", first)
	}
	if seq, fresh := auditOf(t, w.anna.must("", "")); seq != first || fresh != 0 {
		t.Fatalf("again: %d, %d new", seq, fresh)
	}
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	seq, fresh := auditOf(t, w.anna.must("", ""))
	if seq <= first || fresh != seq-first {
		t.Fatalf("after a list: %d, %d new (from %d)", seq, fresh, first)
	}

	// A server restored from an older backup: the history ends before the head seen.
	w.anna.rewriteAudit = func(after string, e [][]byte) [][]byte { return nil }
	if out := w.anna.must("", ""); !strings.Contains(out, "WARNING") || !strings.Contains(out, "no longer leads to entry "+strconv.Itoa(seq)) {
		t.Fatalf("a shorter history: %s", out)
	}
	// The entry seen, changed.
	w.anna.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if len(e) > 0 {
			e[0] = bytes.Replace(e[0], []byte(`"admins.signed"`), []byte(`"admins.changed"`), 1)
		}
		return e
	}
	if out := w.anna.must("", ""); !strings.Contains(out, "is not the one you saw") && !strings.Contains(out, "no longer leads") {
		t.Fatalf("a changed entry: %s", out)
	}
	w.anna.rewriteAudit = nil

	// A history with an entry taken out, seen by Bob for the first time.
	w.bob.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if len(e) > 2 {
			return append(e[:1], e[2:]...)
		}
		return e
	}
	if out := w.bob.must("", ""); !strings.Contains(out, "missing or out of place") {
		t.Fatalf("an entry taken out: %s", out)
	}
	w.bob.rewriteAudit = nil
	if bs, _ := auditOf(t, w.bob.must("", "")); bs != seq {
		t.Fatalf("Bob's head %d, Anna's %d", bs, seq)
	}
	// Anna's head didn't move during the lies.
	if again, fresh := auditOf(t, w.anna.must("", "")); again != seq || fresh != 0 {
		t.Fatalf("Anna after the lies: %d, %d new", again, fresh)
	}
}
