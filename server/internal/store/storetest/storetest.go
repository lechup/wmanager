// Package storetest gives each test a fresh, migrated database of its own, reached through a role that is not a
// superuser, so row-level security applies as it does on a real server.
//
// It needs WMANAGER_TEST_DATABASE_URL: a PostgreSQL superuser's connection string, e.g.
//
//	docker run -d --name wmanager-test-db -e POSTGRES_PASSWORD=test -p 127.0.0.1:55432:5432 postgres:17
//	export WMANAGER_TEST_DATABASE_URL=postgres://postgres:test@127.0.0.1:55432/postgres
//
// Without it the tests that need a database fail, rather than pass without running: CI sets it.
package storetest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/store"
)

// New returns a store on a new database, migrated, and drops the database when the test ends.
func New(t *testing.T) *store.Store {
	t.Helper()
	s, _ := NewWithURL(t)
	return s
}

// NewWithURL is New, and also returns the connection string of the database's own role (not a superuser).
func NewWithURL(t *testing.T) (*store.Store, string) {
	t.Helper()
	admin := os.Getenv("WMANAGER_TEST_DATABASE_URL")
	if admin == "" {
		t.Fatal("WMANAGER_TEST_DATABASE_URL is not set (see the storetest package)")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	suffix := rand.Text()[:12]
	name := "wm_test_" + hex.EncodeToString([]byte(suffix))[:16]
	role := name + "_app"
	password := rand.Text()
	for _, q := range []string{
		`CREATE ROLE ` + role + ` LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '` + password + `'`,
		`CREATE DATABASE ` + name + ` OWNER ` + role,
	} {
		if _, err := conn.Exec(ctx, q); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		c, err := pgx.Connect(context.Background(), admin)
		if err != nil {
			t.Log(err)
			return
		}
		defer c.Close(context.Background())
		c.Exec(context.Background(), `DROP DATABASE IF EXISTS `+name+` WITH (FORCE)`)
		c.Exec(context.Background(), `DROP ROLE IF EXISTS `+role)
	})

	u, err := url.Parse(admin)
	if err != nil {
		t.Fatal(err)
	}
	u.User = url.UserPassword(role, password)
	u.Path = "/" + name
	s, err := store.Open(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	if err := s.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	return s, u.String()
}

// AdminURL is the superuser connection string, for tests that check what a superuser role does.
func AdminURL(t *testing.T) string {
	t.Helper()
	u := os.Getenv("WMANAGER_TEST_DATABASE_URL")
	if u == "" {
		t.Fatal("WMANAGER_TEST_DATABASE_URL is not set (see the storetest package)")
	}
	return u
}

// Superuser connects to the test's own database as the superuser, for tests that do what someone with the
// database itself could do (row-level security doesn't stop a superuser).
func Superuser(t *testing.T, s *store.Store) *pgx.Conn {
	t.Helper()
	ctx := context.Background()
	var db string
	if err := s.Pool.QueryRow(ctx, `SELECT current_database()`).Scan(&db); err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(AdminURL(t))
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + db
	c, err := pgx.Connect(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close(context.Background()) })
	return c
}
