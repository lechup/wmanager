// Package storetest gives each test a fresh, migrated database of its own, set up as on a real server: one role
// owns the tables and runs the migrations, and the server's role is in wmanager_runtime, so row-level security
// and the grants apply.
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
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/store"
)

// DB is a test's database.
type DB struct {
	Store    *store.Store // as the server's role
	URL      string       // the server's role
	OwnerURL string       // the role that owns the tables
}

// New returns the server's store on a new, migrated database, dropped when the test ends.
func New(t *testing.T) *store.Store {
	t.Helper()
	return NewDB(t).Store
}

// NewDB is New with the connection strings.
func NewDB(t *testing.T) *DB {
	t.Helper()
	admin := AdminURL(t)
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, admin)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	name := "wm_test_" + strings.ToLower(rand.Text()[:16])
	owner, runtime := name+"_owner", name+"_server"
	ownerPw, runtimePw := rand.Text(), rand.Text()
	for _, q := range []string{
		// The group is shared by every test database of the cluster; another test may make it at the same time.
		`DO $$ BEGIN CREATE ROLE ` + store.RuntimeGroup + ` NOLOGIN;
		 EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END $$`,
		`CREATE ROLE ` + owner + ` LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '` + ownerPw + `'`,
		`CREATE ROLE ` + runtime + ` LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '` + runtimePw + `' IN ROLE ` +
			store.RuntimeGroup,
		`CREATE DATABASE ` + name + ` OWNER ` + owner,
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
		c.Exec(context.Background(), `DROP ROLE IF EXISTS `+runtime)
		c.Exec(context.Background(), `DROP ROLE IF EXISTS `+owner)
	})

	with := func(user, pw string) string {
		u, err := url.Parse(admin)
		if err != nil {
			t.Fatal(err)
		}
		u.User = url.UserPassword(user, pw)
		u.Path = "/" + name
		return u.String()
	}
	d := &DB{URL: with(runtime, runtimePw), OwnerURL: with(owner, ownerPw)}
	if err := store.Migrate(ctx, d.OwnerURL); err != nil {
		t.Fatal(err)
	}
	if d.Store, err = store.Open(ctx, d.URL); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(d.Store.Close)
	return d
}

// AdminURL is the superuser connection string.
func AdminURL(t *testing.T) string {
	t.Helper()
	u := os.Getenv("WMANAGER_TEST_DATABASE_URL")
	if u == "" {
		t.Fatal("WMANAGER_TEST_DATABASE_URL is not set (see the storetest package)")
	}
	return u
}

// Superuser connects to the test's database as the superuser, for tests that do what someone with the database
// itself could do: row-level security, grants and triggers can all be passed that way.
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
