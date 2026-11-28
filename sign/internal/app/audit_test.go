package app

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

var auditRe = regexp.MustCompile(`audit log: entry (\d+):([0-9a-f]{64}), (\d+) new`)

func auditOf(t *testing.T, out string) (seq, fresh int, hash string) {
	t.Helper()
	m := auditRe.FindStringSubmatch(out)
	if m == nil {
		t.Fatalf("no audit line: %s", out)
	}
	seq, _ = strconv.Atoi(m[1])
	fresh, _ = strconv.Atoi(m[3])
	return seq, fresh, m[2]
}

func TestAuditHead(t *testing.T) {
	w := setup(t)
	first, _, _ := auditOf(t, w.anna.must("", ""))
	if first < 1 {
		t.Fatalf("audit head %d", first)
	}
	if seq, fresh, _ := auditOf(t, w.anna.must("", "")); seq != first || fresh != 0 {
		t.Fatalf("again: %d, %d new", seq, fresh)
	}
	w.anna.must("Bob\n"+w.bobKey+"\nyes\n", "admins", "add", "Acme")
	seq, fresh, hash := auditOf(t, w.anna.must("", ""))
	if seq <= first || fresh != seq-first {
		t.Fatalf("after a list: %d, %d new (from %d)", seq, fresh, first)
	}

	broken := func(p *person, want string) string {
		t.Helper()
		out, err := p.run("", "")
		if !errors.Is(err, ErrAuditBroken) || !strings.Contains(out, want) {
			t.Fatalf("want %q and a broken log: %v\n%s", want, err, out)
		}
		return out
	}
	// A server restored from an older backup: the history ends before the entry seen.
	w.anna.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if after == "0" && len(e) > 1 {
			return e[:1]
		}
		return nil
	}
	if out := broken(w.anna, "no longer leads to entry "+strconv.Itoa(seq)+":"+hash); !strings.Contains(out, "audit accept Acme") {
		t.Fatalf("the warning doesn't say how to go on: %s", out)
	}
	// An entry long before the one seen, changed.
	w.anna.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if after == "0" && len(e) > 0 {
			e[0] = bytes.Replace(e[0], []byte(`"seq":1`), []byte(`"seq":1 `), 1)
		}
		return e
	}
	broken(w.anna, "is not the one you saw")
	w.anna.rewriteAudit = nil
	if again, fresh, _ := auditOf(t, w.anna.must("", "")); again != seq || fresh != 0 {
		t.Fatalf("Anna after the lies: %d, %d new", again, fresh)
	}

	// A history with an entry taken out, seen by Bob for the first time.
	w.bob.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if after == "0" && len(e) > 2 {
			return append(e[:1], e[2:]...)
		}
		return e
	}
	broken(w.bob, "doesn't link")
	w.bob.rewriteAudit = nil
	if bs, _, _ := auditOf(t, w.bob.must("", "")); bs != seq {
		t.Fatalf("Bob's head %d, Anna's %d", bs, seq)
	}

	// After a restore the administrator takes the log as it is now, explicitly.
	w.anna.rewriteAudit = func(after string, e [][]byte) [][]byte {
		if after == "0" && len(e) > 1 {
			return e[:1]
		}
		return nil
	}
	broken(w.anna, "WARNING")
	if out := w.anna.must("yes\n", "audit", "accept", "Acme"); !strings.Contains(out, "The newest entry you saw: "+strconv.Itoa(seq)) ||
		!strings.Contains(out, "is taken as it is now (1:") {
		t.Fatalf("audit accept: %s", out)
	}
	if s, _, _ := auditOf(t, w.anna.must("", "")); s != 1 {
		t.Fatalf("after accepting: entry %d", s)
	}
}

// A long audit log is read page by page, and linked whole.
func TestAuditLongLog(t *testing.T) {
	w := setup(t)
	chain := "company:" + w.company
	var raws [][]byte
	var prev [32]byte
	for i := 1; i <= 2500; i++ {
		raw := []byte(fmt.Sprintf(`{"seq":%d,"at":"2026-11-28T12:00:00Z","chain":%q,"actor":"system","action":"test"}`, i, chain))
		raws = append(raws, raw)
		prev = link(prev, raw)
	}
	w.anna.rewriteAudit = func(after string, _ [][]byte) [][]byte {
		n, _ := strconv.Atoi(after)
		if n >= len(raws) {
			return nil
		}
		return raws[n:min(n+1000, len(raws))]
	}
	seq, fresh, hash := auditOf(t, w.anna.must("", ""))
	if seq != 2500 || fresh != 2500 || hash != hex.EncodeToString(prev[:]) {
		t.Fatalf("a long log: %d, %d new, %s", seq, fresh, hash)
	}
}
