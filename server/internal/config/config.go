// Package config reads the server's settings from environment variables and files, never from the command line:
// a command line is visible to every user of the host and lands in logs.
package config

import (
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"os"
	"strings"
	"time"
)

// Config is the server's settings.
type Config struct {
	// DatabaseURL is the PostgreSQL connection string of the server's role, in the group wmanager_runtime
	// (WMANAGER_DATABASE_URL, or a file named by WMANAGER_DATABASE_URL_FILE, e.g. a Docker secret).
	DatabaseURL string
	// MigrateDatabaseURL is the connection string of the role that owns the tables, for the migrations
	// (WMANAGER_MIGRATE_DATABASE_URL or ..._FILE). Optional for serve, which then expects a migrated database.
	MigrateDatabaseURL string
	// Listen is the address of the HTTP server behind Caddy (WMANAGER_LISTEN, default 127.0.0.1:8080).
	Listen string
	// PublicURL is the panel's address as people reach it, for the links it gives out (WMANAGER_PUBLIC_URL,
	// e.g. https://wm.example.com). Without it, the links use the request's host over https.
	PublicURL string
	// TrustedProxies are the addresses (CIDR) whose X-Forwarded-For is believed (WMANAGER_TRUSTED_PROXIES,
	// comma-separated). Name Caddy's exact address, not a whole network: with Docker's network, a connection from
	// outside that Docker forwards may come from the network's gateway. Without them, the client's address is the
	// connection's.
	TrustedProxies []netip.Prefix
	// LokiURL is where the audit log's heads are written down every LokiHeadEvery (WMANAGER_LOKI_URL, e.g.
	// http://loki:3100; WMANAGER_LOKI_TENANT, default wmanager-server; WMANAGER_LOKI_HEAD_EVERY, default 5m).
	// Without it, nothing is sent.
	LokiURL       string
	LokiTenant    string
	LokiHeadEvery time.Duration
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
	if c.MigrateDatabaseURL, err = secret(getenv, "WMANAGER_MIGRATE_DATABASE_URL"); err != nil {
		return Config{}, err
	}
	if v := getenv("WMANAGER_LISTEN"); v != "" {
		c.Listen = v
	}
	if v := strings.TrimRight(getenv("WMANAGER_PUBLIC_URL"), "/"); v != "" {
		u, err := url.Parse(v)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "" || u.RawQuery != "" {
			return Config{}, errors.New("config: WMANAGER_PUBLIC_URL must be https://host[:port]")
		}
		c.PublicURL = v
	}
	for _, p := range strings.Split(getenv("WMANAGER_TRUSTED_PROXIES"), ",") {
		if p = strings.TrimSpace(p); p == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(p)
		if err != nil {
			addr, err2 := netip.ParseAddr(p)
			if err2 != nil {
				return Config{}, fmt.Errorf("config: WMANAGER_TRUSTED_PROXIES: %q is not an address or CIDR", p)
			}
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		}
		c.TrustedProxies = append(c.TrustedProxies, netip.PrefixFrom(prefix.Addr().Unmap(), unmappedBits(prefix)).Masked())
	}
	if v := strings.TrimRight(getenv("WMANAGER_LOKI_URL"), "/"); v != "" {
		u, err := url.Parse(v)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return Config{}, errors.New("config: WMANAGER_LOKI_URL must be http(s)://host[:port]")
		}
		c.LokiURL = v
	}
	c.LokiTenant, c.LokiHeadEvery = "wmanager-server", 5*time.Minute
	if v := getenv("WMANAGER_LOKI_TENANT"); v != "" {
		c.LokiTenant = v
	}
	if v := getenv("WMANAGER_LOKI_HEAD_EVERY"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d < time.Second {
			return Config{}, errors.New("config: WMANAGER_LOKI_HEAD_EVERY must be a duration of a second or more")
		}
		c.LokiHeadEvery = d
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

// unmappedBits is a prefix's length once an IPv4-mapped IPv6 address becomes IPv4.
func unmappedBits(p netip.Prefix) int {
	if p.Addr().Is4In6() {
		return max(p.Bits()-96, 0)
	}
	return p.Bits()
}
