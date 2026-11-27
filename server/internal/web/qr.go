package web

import (
	"fmt"
	"html/template"
	"net/url"
	"strings"

	"rsc.io/qr"
)

// totpQR draws the otpauth:// address as an SVG QR code (no image file, no script), and returns the secret in
// groups of four for typing in by hand.
func totpQR(otpauth string) (template.HTML, string, error) {
	code, err := qr.Encode(otpauth, qr.M)
	if err != nil {
		return "", "", err
	}
	n := code.Size
	var b strings.Builder
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-4 -4 %d %d" class="qr" role="img" aria-label="QR">`,
		n+8, n+8)
	b.WriteString(`<rect x="-4" y="-4" width="100%" height="100%" fill="#fff"/><path fill="#000" d="`)
	for y := range n {
		for x := range n {
			if code.Black(x, y) {
				fmt.Fprintf(&b, "M%d %dh1v1h-1z", x, y)
			}
		}
	}
	b.WriteString(`"/></svg>`)
	u, err := url.Parse(otpauth)
	if err != nil {
		return "", "", err
	}
	secret := u.Query().Get("secret")
	var groups []string
	for i := 0; i < len(secret); i += 4 {
		groups = append(groups, secret[i:min(i+4, len(secret))])
	}
	// The SVG is built here from numbers only, so it is safe as HTML.
	return template.HTML(b.String()), strings.Join(groups, " "), nil
}
