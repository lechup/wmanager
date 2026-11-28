// Command wmanager-server is the server of wmanager v1 (docs/architecture.md).
//
//	wmanager-server serve                       serve the panel (plain HTTP behind Caddy); migrates first when
//	                                            WMANAGER_MIGRATE_DATABASE_URL is set
//	wmanager-server migrate                     migrate the database, as the role that owns the tables
//	wmanager-server healthcheck                 ask the running server's /healthz (for Docker's health check)
//	wmanager-server create-owner <e-mail>       make the owner of the server; asks for the password
//	wmanager-server unlock <e-mail>             end an account's lockout after wrong second-factor codes
//	wmanager-server audit verify <chain> [<seq>:<hash>]
//	                                            check a chain of the audit log, and that it leads to a head seen
//	wmanager-server audit export <chain> json|csv
//	                                            write a chain of the audit log
//
// A chain is "server" or "company:<id>". The settings come from the environment, never from the command line:
// WMANAGER_DATABASE_URL (the server's role, in wmanager_runtime), WMANAGER_MIGRATE_DATABASE_URL (the role that
// owns the tables), each also as ..._FILE, WMANAGER_LISTEN, WMANAGER_PUBLIC_URL and WMANAGER_TRUSTED_PROXIES.
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"github.com/lechup/wmanager/server/internal/accounts"
	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/auth"
	"github.com/lechup/wmanager/server/internal/config"
	"github.com/lechup/wmanager/server/internal/lokihead"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/web"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:], os.Stdin, os.Stdout, os.Stderr, os.Getenv); err != nil {
		fmt.Fprintln(os.Stderr, "wmanager-server:", err)
		os.Exit(1)
	}
}

const usage = `usage:
  wmanager-server serve | migrate | healthcheck
  wmanager-server create-owner <e-mail>
  wmanager-server unlock <e-mail>
  wmanager-server audit verify <chain> [<seq>:<hash>]
  wmanager-server audit export <chain> json|csv`

func run(ctx context.Context, args []string, stdin io.Reader, stdout, stderr io.Writer, getenv func(string) string) error {
	if len(args) == 0 {
		return errors.New(usage)
	}
	if args[0] == "healthcheck" && len(args) == 1 {
		return healthcheck(getenv)
	}
	cfg, err := config.Load(getenv)
	if err != nil {
		return err
	}
	if args[0] == "migrate" && len(args) == 1 {
		if cfg.MigrateDatabaseURL == "" {
			return errors.New("migrate needs WMANAGER_MIGRATE_DATABASE_URL: the role that owns the tables")
		}
		if err := store.Migrate(ctx, cfg.MigrateDatabaseURL); err != nil {
			return err
		}
		// And the server's own role is one it may run as (not the owner, in wmanager_runtime only).
		s, err := store.Open(ctx, cfg.DatabaseURL)
		if err != nil {
			return err
		}
		s.Close()
		fmt.Fprintln(stdout, "the database is up to date")
		return nil
	}
	if args[0] == "serve" && cfg.MigrateDatabaseURL != "" {
		if err := store.Migrate(ctx, cfg.MigrateDatabaseURL); err != nil {
			return err
		}
	}
	s, err := store.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer s.Close()
	switch {
	case args[0] == "serve" && len(args) == 1:
		return serve(ctx, cfg, s, stderr)
	case args[0] == "create-owner" && len(args) == 2:
		pw, err := readPassword(stdin, stderr)
		if err != nil {
			return err
		}
		id, err := accounts.CreateAccount(ctx, s, accounts.SystemActor, args[1], "", pw, true)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "owner %s made (%s); the second factor is set up at the first sign-in\n", args[1], id)
		return nil
	case args[0] == "unlock" && len(args) == 2:
		if err := accounts.Unlock(ctx, s, accounts.SystemActor, args[1]); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "%s unlocked\n", args[1])
		return nil
	case args[0] == "audit" && len(args) >= 3 && args[1] == "verify" && len(args) <= 4:
		var seen *audit.Head
		if len(args) == 4 {
			h, err := parseHead(args[2], args[3])
			if err != nil {
				return err
			}
			seen = &h
		}
		head, err := audit.Verify(ctx, s, store.System, args[2], seen)
		if err != nil {
			return err
		}
		fmt.Fprintf(stdout, "the chain is whole; its head: %d:%x\n", head.Seq, head.Hash)
		return nil
	case args[0] == "audit" && len(args) == 4 && args[1] == "export":
		recs, err := audit.Read(ctx, s, store.System, args[2])
		if err != nil {
			return err
		}
		switch args[3] {
		case "json":
			return audit.ExportJSON(stdout, recs)
		case "csv":
			return audit.ExportCSV(stdout, recs)
		}
	}
	return errors.New(usage)
}

func parseHead(chain, s string) (audit.Head, error) {
	seq, hash, ok := strings.Cut(s, ":")
	n, err1 := strconv.ParseInt(seq, 10, 64)
	b, err2 := hex.DecodeString(hash)
	if !ok || err1 != nil || err2 != nil || len(b) != 32 {
		return audit.Head{}, errors.New("a head is <seq>:<64 hex characters>")
	}
	h := audit.Head{Chain: chain, Seq: n}
	copy(h.Hash[:], b)
	return h, nil
}

// readPassword asks for the password twice at a terminal, without showing it. From a pipe (e.g.
// docker exec -i) it reads one line. It is never taken from the command line.
func readPassword(stdin io.Reader, stderr io.Writer) (string, error) {
	if f, ok := stdin.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		fmt.Fprint(stderr, "Password (at least 12 characters): ")
		a, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(stderr)
		if err != nil {
			return "", err
		}
		fmt.Fprint(stderr, "The same password again: ")
		b, err := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(stderr)
		if err != nil {
			return "", err
		}
		if string(a) != string(b) {
			return "", errors.New("the passwords differ")
		}
		return string(a), nil
	}
	line, err := bufio.NewReader(stdin).ReadString('\n')
	if err != nil && !(errors.Is(err, io.EOF) && line != "") {
		return "", errors.New("no password on the standard input")
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func serve(ctx context.Context, cfg config.Config, s *store.Store, stderr io.Writer) error {
	log := slog.New(slog.NewJSONHandler(stderr, nil))
	a := auth.New(s)
	a.Log = log
	panel, err := web.New(s, a, log)
	if err != nil {
		return err
	}
	panel.PublicURL, panel.TrustedProxies, panel.FilesDir = cfg.PublicURL, cfg.TrustedProxies, cfg.FilesDir
	if cfg.LokiURL != "" {
		p := &lokihead.Pusher{Store: s, URL: cfg.LokiURL, Tenant: cfg.LokiTenant, Every: cfg.LokiHeadEvery, Log: log}
		go p.Run(ctx)
	}
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           panel.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      90 * time.Second, // long polls of the agents wait up to 60 seconds (stage 3)
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    32 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
	}
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	log.Info("serving", "listen", cfg.Listen)
	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
		shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return srv.Shutdown(shut)
	}
}

// healthcheck asks the server listening at WMANAGER_LISTEN (the image has no curl).
func healthcheck(getenv func(string) string) error {
	listen := getenv("WMANAGER_LISTEN")
	if listen == "" {
		listen = "127.0.0.1:8080"
	}
	host, port, err := net.SplitHostPort(listen)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/healthz")
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("healthz: %s", resp.Status)
	}
	return nil
}
