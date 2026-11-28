package show

import (
	"slices"
	"testing"
)

func TestVisible(t *testing.T) {
	for in, want := range map[string]string{
		"OFFICE-03":       "OFFICE-03",
		"evil‮txt.exe":    "evil<U+202E>txt.exe",
		"tab\there":       "tab<U+0009>here",
		"Łódź":            "<U+0141><U+00F3>d<U+017A>",
		"bell\a":          "bell<U+0007>",
		"esc\x1b[2J":      "esc<U+001B>[2J",
		"bad\xff":         "bad<0xFF>",
		"zero​width":      "zero<U+200B>width",
		"del\x7f":         "del<U+007F>",
		"emoji\U0001F600": "emoji<U+1F600>",
		"cr\r":            "cr<U+000D>",
		"nl\n":            "nl<U+000A>",
		"":                "",
	} {
		if got := Visible(in); got != want {
			t.Errorf("Visible(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLines(t *testing.T) {
	got := Lines("one\r\ntwo three\n")
	want := []string{"one<U+000D>", "two<U+2028>three"}
	if !slices.Equal(got, want) {
		t.Fatalf("Lines = %q", got)
	}
	if got := Clip("a‮b"+string(make([]byte, 300)), 20); len(got) != 23 {
		t.Fatalf("Clip: %q", got)
	}
}
