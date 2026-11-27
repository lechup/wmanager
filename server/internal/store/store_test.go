package store_test

import (
	"context"
	"strings"
	"testing"

	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func TestRefusesWrongRoles(t *testing.T) {
	db := storetest.NewDB(t)
	ctx := context.Background()
	for name, c := range map[string]struct{ url, says string }{
		"a superuser":             {storetest.AdminURL(t), "superuser"},
		"the owner of the tables": {db.OwnerURL, "not in wmanager_runtime"},
	} {
		if _, err := store.Open(ctx, c.url); err == nil || !strings.Contains(err.Error(), c.says) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestMigrateTwice(t *testing.T) {
	db := storetest.NewDB(t)
	if err := store.Migrate(context.Background(), db.OwnerURL); err != nil {
		t.Fatalf("migrating an up-to-date database: %v", err)
	}
}

// What the server's role can't do to the audit log, whatever the settings of row-level security say.
func TestRuntimeRoleLimits(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	if _, err := s.Pool.Exec(ctx, `INSERT INTO companies (name) VALUES ('Acme')`); err != nil {
		t.Fatal(err)
	}
	for name, q := range map[string]string{
		"truncate":         `TRUNCATE audit_log`,
		"turn off RLS":     `ALTER TABLE audit_log NO FORCE ROW LEVEL SECURITY`,
		"drop the trigger": `DROP TRIGGER audit_log_no_update ON audit_log`,
		"update":           `UPDATE audit_log SET entry = 'x'`,
		"delete":           `DELETE FROM audit_log`,
		"drop a table":     `DROP TABLE sessions`,
	} {
		_, err := s.Pool.Exec(ctx, `SELECT set_config('wmanager.system', 'on', false); `+q)
		if err == nil {
			t.Errorf("%s: allowed", name)
		}
	}
}
