package app

import (
	"bufio"
	"io"
	"maps"
	"regexp"
	"slices"
	"strings"
	"testing"
)

// verbRe is a fmt verb, with its explicit argument index when it has one.
var verbRe = regexp.MustCompile(`%(\[\d+\])?[sdvq]`)

// verbs is a message's verbs, numbered as fmt takes their arguments.
func verbs(msg string) []string {
	var out []string
	next := 1
	for _, m := range verbRe.FindAllStringSubmatch(msg, -1) {
		n := next
		if m[1] != "" {
			n = int(m[1][1] - '0')
			for _, c := range m[1][2 : len(m[1])-1] {
				n = n*10 + int(c-'0')
			}
		}
		out = append(out, string(rune('0'+n))+m[0][len(m[0])-1:])
		next = n + 1
	}
	slices.Sort(out)
	return out
}

// Every language has every message, with the same arguments, and asks for the word that confirms.
func TestLanguages(t *testing.T) {
	en := catalogs["en"]
	for _, l := range Languages {
		c := catalogs[l]
		if c == nil {
			t.Errorf("no lang/%s.json", l)
			continue
		}
		if !slices.Equal(slices.Sorted(maps.Keys(c)), slices.Sorted(maps.Keys(en))) {
			for k := range en {
				if _, ok := c[k]; !ok {
					t.Errorf("%s: no %s", l, k)
				}
			}
			for k := range c {
				if _, ok := en[k]; !ok {
					t.Errorf("%s: %s isn't in English", l, k)
				}
			}
		}
		for k, msg := range c {
			if en[k] != "" && !slices.Equal(verbs(msg), verbs(en[k])) {
				t.Errorf("%s: %s has the arguments %v, English %v", l, k, verbs(msg), verbs(en[k]))
			}
			if strings.Count(msg, "\n") != strings.Count(en[k], "\n") {
				t.Errorf("%s: %s has another number of lines", l, k)
			}
		}
		for _, k := range []string{"sign.confirm", "audit.confirm"} {
			if !strings.Contains(c[k], c["word.yes"]) {
				t.Errorf("%s: %s doesn't ask for %q", l, k, c["word.yes"])
			}
		}
	}
}

func TestLanguage(t *testing.T) {
	for _, env := range []string{"WMANAGER_LANG", "LC_ALL", "LC_MESSAGES", "LANG"} {
		t.Setenv(env, "")
	}
	t.Setenv("LANG", "pl_PL.UTF-8")
	if l := Language(""); l != "pl" {
		t.Fatalf("LANG=pl_PL.UTF-8: %s", l)
	}
	t.Setenv("WMANAGER_LANG", "de")
	if l := Language(""); l != "de" {
		t.Fatalf("WMANAGER_LANG=de: %s", l)
	}
	if l := Language("fr"); l != "fr" {
		t.Fatalf("-lang fr: %s", l)
	}
	t.Setenv("WMANAGER_LANG", "xx")
	t.Setenv("LANG", "C.UTF-8")
	if l := Language(""); l != "en" {
		t.Fatalf("no language of ours: %s", l)
	}
}

func TestConfirmWords(t *testing.T) {
	for in, want := range map[string]bool{"yes": true, "YES": true, "si": true, "sí": true, "s": false, "no": false, "": false} {
		a := &App{Lang: "es", In: bufio.NewReader(strings.NewReader(in + "\n")), Out: io.Discard}
		if got, err := a.confirm("sign.confirm"); err != nil || got != want {
			t.Errorf("%q: %v %v", in, got, err)
		}
	}
}
