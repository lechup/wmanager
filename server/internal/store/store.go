// Package store is the server's PostgreSQL: the connection pool, the migrations built into the program, and
// transactions that tell row-level security who is asking.
//
// Two roles reach the database (see migrations/00001_frame.sql): the one that owns the tables runs the
// migrations, and the server runs as a role in the group wmanager_runtime, which can't change or remove audit
// entries or turn row-level security off.
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

// RuntimeGroup is the role the server's own role must be in.
const RuntimeGroup = "wmanager_runtime"

// Store is the database.
type Store struct {
	Pool *pgxpool.Pool
}

func provider(db *sql.DB) (*goose.Provider, error) {
	p, err := goose.NewProvider(goose.DialectPostgres, db, mustSub(migrations, "migrations"))
	if err != nil {
		return nil, fmt.Errorf("store: migrations: %w", err)
	}
	return p, nil
}

// Migrate brings the schema up to date, connected as the role that owns the tables.
func Migrate(ctx context.Context, ownerURL string) error {
	pool, err := pgxpool.New(ctx, ownerURL)
	if err != nil {
		return fmt.Errorf("store: %w", err)
	}
	defer pool.Close()
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	p, err := provider(db)
	if err != nil {
		return err
	}
	if _, err := p.Up(ctx); err != nil {
		return fmt.Errorf("store: migrations: %w", err)
	}
	return nil
}

// Open connects as the server's role. It refuses a role that is a superuser, bypasses row-level security, owns
// the tables or isn't in wmanager_runtime, and a database whose migrations haven't all run.
func Open(ctx context.Context, url string) (*Store, error) {
	pool, err := pgxpool.New(ctx, url)
	if err != nil {
		return nil, fmt.Errorf("store: %w", err)
	}
	s := &Store{Pool: pool}
	if err := s.check(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) check(ctx context.Context) error {
	var super, bypass, member bool
	err := s.Pool.QueryRow(ctx, `SELECT rolsuper, rolbypassrls, pg_has_role(current_user, $1, 'member')
	                             FROM pg_roles WHERE rolname = current_user`, RuntimeGroup).Scan(&super, &bypass, &member)
	if err != nil {
		return fmt.Errorf("store: %w (is the role %s there?)", err, RuntimeGroup)
	}
	if super || bypass {
		return errors.New("store: the server's database role is a superuser or bypasses row-level security; " +
			"give the server a role of its own in " + RuntimeGroup)
	}
	if !member {
		return errors.New("store: the server's database role is not in " + RuntimeGroup)
	}
	// Owning the tables, or being in the role that owns them, would let the server's role turn row-level security
	// and the append-only triggers off.
	var exists, owns, tooMuch bool
	if err := s.Pool.QueryRow(ctx, `SELECT count(*) > 0,
	                                       coalesce(bool_or(pg_has_role(current_user, tableowner, 'MEMBER')), false),
	                                       coalesce(bool_or(has_table_privilege(current_user, 'audit_log', 'UPDATE') OR
	                                                        has_table_privilege(current_user, 'audit_log', 'DELETE') OR
	                                                        has_table_privilege(current_user, 'audit_log', 'TRUNCATE')), false)
	                                FROM pg_tables WHERE schemaname = current_schema() AND tablename = 'audit_log'`).
		Scan(&exists, &owns, &tooMuch); err != nil {
		return fmt.Errorf("store: %w", err)
	}
	if !exists {
		return errors.New("store: the database is not migrated (wmanager-server migrate)")
	}
	if owns || tooMuch {
		return errors.New("store: the server's database role owns the tables, is in the role that does, or may " +
			"change the audit log; run the migrations as another role (WMANAGER_MIGRATE_DATABASE_URL) and the " +
			"server as a role in " + RuntimeGroup + " only")
	}
	db := stdlib.OpenDBFromPool(s.Pool)
	defer db.Close()
	p, err := provider(db)
	if err != nil {
		return err
	}
	pending, err := p.HasPending(ctx)
	if err != nil {
		return fmt.Errorf("store: checking the migrations: %w", err)
	}
	if pending {
		return errors.New("store: the database is not migrated (wmanager-server migrate)")
	}
	return nil
}

// Close closes the pool.
func (s *Store) Close() { s.Pool.Close() }

// Who is asking, for row-level security.
type Who struct {
	Account string // the signed-in account's id, or ""
	System  bool   // the server's own work
}

// System is the server's own work: sign-in, the audit log, background jobs.
var System = Who{System: true}

// Tx runs fn in a transaction that row-level security sees as who. It commits when fn returns nil. The settings
// are local to the transaction, so a pooled connection doesn't carry them to the next one.
func (s *Store) Tx(ctx context.Context, who Who, fn func(pgx.Tx) error) error {
	return s.TxWith(ctx, pgx.TxOptions{}, who, fn)
}

// TxWith is Tx with transaction options, e.g. a snapshot (pgx.RepeatableRead) for reads that must agree.
func (s *Store) TxWith(ctx context.Context, opts pgx.TxOptions, who Who, fn func(pgx.Tx) error) error {
	return pgx.BeginTxFunc(ctx, s.Pool, opts, func(tx pgx.Tx) error {
		if err := SetWho(ctx, tx, who); err != nil {
			return err
		}
		return fn(tx)
	})
}

// SetWho changes, within a transaction, who row-level security sees.
func SetWho(ctx context.Context, tx pgx.Tx, who Who) error {
	system := ""
	if who.System {
		system = "on"
	}
	_, err := tx.Exec(ctx, `SELECT set_config('wmanager.system', $1, true), set_config('wmanager.account', $2, true)`,
		system, who.Account)
	return err
}
