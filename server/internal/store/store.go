// Package store is the server's PostgreSQL: the connection pool, the migrations built into the program, and
// transactions that tell row-level security who is asking.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

// Store is the database.
type Store struct {
	Pool *pgxpool.Pool
}

// Open connects and refuses a superuser role: row-level security doesn't apply to one, so the second barrier
// between companies would be gone.
func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("store: %w", err)
	}
	var super, bypass bool
	err = pool.QueryRow(ctx,
		`SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user`).Scan(&super, &bypass)
	if err != nil {
		pool.Close()
		return nil, fmt.Errorf("store: %w", err)
	}
	if super || bypass {
		pool.Close()
		return nil, errors.New("store: the database role is a superuser or bypasses row-level security; " +
			"give the server a role of its own (see examples/selfhosted)")
	}
	return &Store{Pool: pool}, nil
}

// Close closes the pool.
func (s *Store) Close() { s.Pool.Close() }

// Migrate brings the schema up to date.
func (s *Store) Migrate(ctx context.Context) error {
	db := stdlib.OpenDBFromPool(s.Pool)
	defer db.Close()
	return migrate(ctx, db)
}

func migrate(ctx context.Context, db *sql.DB) error {
	provider, err := goose.NewProvider(goose.DialectPostgres, db, mustSub(migrations, "migrations"))
	if err != nil {
		return fmt.Errorf("store: migrations: %w", err)
	}
	if _, err := provider.Up(ctx); err != nil {
		return fmt.Errorf("store: migrations: %w", err)
	}
	return nil
}

// Who is asking, for row-level security.
type Who struct {
	Account string // the signed-in account's id, or ""
	System  bool   // the server's own work
}

// System is the server's own work: sign-in, the audit log, background jobs.
var System = Who{System: true}

// Tx runs fn in a transaction that row-level security sees as who. It commits when fn returns nil.
func (s *Store) Tx(ctx context.Context, who Who, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		system := ""
		if who.System {
			system = "on"
		}
		if _, err := tx.Exec(ctx, `SELECT set_config('wmanager.system', $1, true),
		                                  set_config('wmanager.account', $2, true)`, system, who.Account); err != nil {
			return err
		}
		return fn(tx)
	})
}
