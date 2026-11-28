// Package show writes text from a server, a statement or a file to the screen so that what is shown is what is
// signed: printable ASCII as it is, and every other character visibly, as <U+202E>, so nothing can be hidden,
// reordered or drawn over on the screen (docs/architecture.md, "wmanager-sign").
package show

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// Visible is s on one line: printable ASCII (space to ~) as it is; every other character, a line break and a tab
// too, as <U+XXXX>; a byte that isn't UTF-8 as <0xNN>.
func Visible(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && n == 1:
			fmt.Fprintf(&b, "<0x%02X>", s[i])
		case r >= 0x20 && r < 0x7f:
			b.WriteRune(r)
		default:
			fmt.Fprintf(&b, "<U+%04X>", r)
		}
		i += n
	}
	return b.String()
}

// Lines is a text as lines, each shown with Visible: only "\n" breaks a line, so a "\r" or another separator
// shows where it is. A text ending in "\n" has no empty last line.
func Lines(s string) []string {
	s = strings.TrimSuffix(s, "\n")
	parts := strings.Split(s, "\n")
	for i, p := range parts {
		parts[i] = Visible(p)
	}
	return parts
}

// Clip is Visible, cut to about n characters: for what a server says, which is only ever a message.
func Clip(s string, n int) string {
	v := Visible(s)
	if len(v) > n {
		v = v[:n] + "..."
	}
	return v
}
