package app

import (
	"embed"
	"encoding/json/v2"
	"fmt"
	"os"
	"slices"
	"strings"
)

//go:embed lang/*.json
var langFiles embed.FS

// Languages are wmanager's ten (docs/languages.md), English the default. Only those with a file are loaded.
var Languages = []string{"en", "de", "fr", "es", "it", "pl", "nl", "pt", "ro", "cs"}

var catalogs = func() map[string]map[string]string {
	out := map[string]map[string]string{}
	for _, l := range Languages {
		b, err := langFiles.ReadFile("lang/" + l + ".json")
		if err != nil {
			continue
		}
		m := map[string]string{}
		if err := json.Unmarshal(b, &m); err != nil {
			panic(fmt.Sprintf("app: lang/%s.json: %v", l, err))
		}
		out[l] = m
	}
	if out["en"] == nil {
		panic("app: no lang/en.json")
	}
	return out
}()

// t is a message in the run's language, falling back to English and then to the key.
func (a *App) t(key string, args ...any) string {
	msg, ok := catalogs[a.Lang][key]
	if !ok {
		msg, ok = catalogs["en"][key]
	}
	if !ok {
		msg = key
	}
	if len(args) > 0 {
		return fmt.Sprintf(msg, args...)
	}
	return msg
}

// Language is the language to use: -lang, WMANAGER_LANG, then the locale's (LC_ALL, LC_MESSAGES, LANG), else
// English.
func Language(flag string) string {
	for _, v := range []string{flag, os.Getenv("WMANAGER_LANG"), os.Getenv("LC_ALL"), os.Getenv("LC_MESSAGES"), os.Getenv("LANG")} {
		base, _, _ := strings.Cut(strings.ToLower(v), "_")
		base, _, _ = strings.Cut(base, ".")
		base, _, _ = strings.Cut(base, "-")
		if slices.Contains(Languages, base) && catalogs[base] != nil {
			return base
		}
	}
	return "en"
}
