package config

import (
	"os"
	"path/filepath"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestLoad(t *testing.T) {
	if _, err := Load(env(nil)); err == nil {
		t.Fatal("no database URL accepted")
	}
	c, err := Load(env(map[string]string{"WMANAGER_DATABASE_URL": "postgres://x"}))
	if err != nil || c.DatabaseURL != "postgres://x" || c.Listen != "127.0.0.1:8080" {
		t.Fatalf("%+v %v", c, err)
	}
	f := filepath.Join(t.TempDir(), "db")
	os.WriteFile(f, []byte("postgres://from-file\n"), 0o600)
	c, err = Load(env(map[string]string{"WMANAGER_DATABASE_URL_FILE": f, "WMANAGER_LISTEN": ":9000"}))
	if err != nil || c.DatabaseURL != "postgres://from-file" || c.Listen != ":9000" {
		t.Fatalf("%+v %v", c, err)
	}
	if _, err := Load(env(map[string]string{"WMANAGER_DATABASE_URL_FILE": f, "WMANAGER_DATABASE_URL": "x"})); err == nil {
		t.Fatal("both the value and the file accepted")
	}
}
