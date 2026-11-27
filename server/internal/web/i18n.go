package web

import (
	"embed"
	"encoding/json/v2"
	"fmt"
	"net/http"
	"slices"
	"strings"
)

//go:embed lang/*.json
var langFiles embed.FS

// languages are the panel's languages, the ten of wmanager (docs/languages.md); English is the default.
var languages = []string{"en", "de", "fr", "es", "it", "pl", "nl", "pt", "ro", "cs"}

var catalogs = func() map[string]map[string]string {
	out := map[string]map[string]string{}
	for _, l := range languages {
		b, err := langFiles.ReadFile("lang/" + l + ".json")
		if err != nil {
			panic(err)
		}
		m := map[string]string{}
		if err := json.Unmarshal(b, &m); err != nil {
			panic(fmt.Sprintf("web: lang/%s.json: %v", l, err))
		}
		out[l] = m
	}
	return out
}()

// translate looks a message up in a language, falling back to English and then to the key itself.
func translate(lang, key string, args ...any) string {
	msg, ok := catalogs[lang][key]
	if !ok {
		msg, ok = catalogs["en"][key]
	}
	if !ok {
		return key
	}
	if len(args) > 0 {
		return fmt.Sprintf(msg, args...)
	}
	return msg
}

const langCookie = "wmanager-lang"

// language is the request's language: ?lang= (kept in a cookie), the cookie, or the browser's
// Accept-Language, else English.
func (s *Server) language(w http.ResponseWriter, r *http.Request) string {
	if l := r.URL.Query().Get("lang"); slices.Contains(languages, l) {
		http.SetCookie(w, &http.Cookie{Name: langCookie, Value: l, Path: "/", MaxAge: 365 * 24 * 3600,
			Secure: true, HttpOnly: true, SameSite: http.SameSiteLaxMode})
		return l
	}
	if c, err := r.Cookie(langCookie); err == nil && slices.Contains(languages, c.Value) {
		return c.Value
	}
	for _, part := range strings.Split(r.Header.Get("Accept-Language"), ",") {
		tag, _, _ := strings.Cut(strings.TrimSpace(part), ";")
		base, _, _ := strings.Cut(strings.ToLower(tag), "-")
		if slices.Contains(languages, base) {
			return base
		}
	}
	return "en"
}
