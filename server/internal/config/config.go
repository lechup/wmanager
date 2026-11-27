// Package config reads the server's settings from environment variables and files, never from the command line:
// a command line is visible to every user of the host and lands in logs.
package config

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// Config is the server's settings.
type Config struct {
	// DatabaseURL is the PostgreSQL connection string (WMANAGER_DATABASE_URL, or a file named by
	// WMANAGER_DATABASE_URL_FILE, e.g. a Docker secret).
	DatabaseURL string
	// Listen is the address of the HTTP server behind Caddy (WMANAGER_LISTEN, default 127.0.0.1:8080).
	Listen string
}

// Load reads the settings. getenv is os.Getenv outside tests.
func Load(getenv func(string) string) (Config, error) {
	c := Config{Listen: "127.0.0.1:8080"}
	var err error
	if c.DatabaseURL, err = secret(getenv, "WMANAGER_DATABASE_URL"); err != nil {
		return Config{}, err
	}
	if c.DatabaseURL == "" {
		return Config{}, errors.New("config: WMANAGER_DATABASE_URL or WMANAGER_DATABASE_URL_FILE is not set")
	}
	if v := getenv("WMANAGER_LISTEN"); v != "" {
		c.Listen = v
	}
	return c, nil
}

// secret reads NAME, or the file NAME_FILE names. Setting both is an error, so it is clear which one is used.
func secret(getenv func(string) string, name string) (string, error) {
	v, file := getenv(name), getenv(name+"_FILE")
	switch {
	case v != "" && file != "":
		return "", fmt.Errorf("config: both %s and %s_FILE are set", name, name)
	case file != "":
		b, err := os.ReadFile(file)
		if err != nil {
			return "", fmt.Errorf("config: %s_FILE: %w", name, err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return v, nil
}
