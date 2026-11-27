package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func TestCommands(t *testing.T) {
	db := storetest.NewDB(t)
	env := func(k string) string {
		switch k {
		case "WMANAGER_DATABASE_URL":
			return db.URL
		case "WMANAGER_MIGRATE_DATABASE_URL":
			return db.OwnerURL
		}
		return ""
	}
	ctx := context.Background()
	cmd := func(stdin string, args ...string) (string, error) {
		var out, errOut bytes.Buffer
		err := run(ctx, args, strings.NewReader(stdin), &out, &errOut, env)
		return out.String(), err
	}
	if out, err := cmd("", "migrate"); err != nil || !strings.Contains(out, "up to date") {
		t.Fatalf("migrate: %q %v", out, err)
	}
	if _, err := cmd("short\n", "create-owner", "owner@example.com"); err == nil {
		t.Fatal("a short password accepted")
	}
	if _, err := cmd("", "create-owner", "owner@example.com"); err == nil {
		t.Fatal("no password accepted")
	}
	if out, err := cmd("a long enough password\n", "create-owner", "owner@example.com"); err != nil || !strings.Contains(out, "owner owner@example.com made") {
		t.Fatalf("create-owner: %q %v", out, err)
	}
	out, err := cmd("", "audit", "verify", "server")
	if err != nil || !strings.Contains(out, "the chain is whole; its head: 1:") {
		t.Fatalf("audit verify: %q %v", out, err)
	}
	head := strings.TrimSpace(out[strings.LastIndex(out, " ")+1:])
	if _, err := cmd("", "audit", "verify", "server", head); err != nil {
		t.Fatalf("audit verify with the head just seen: %v", err)
	}
	wrong := head[:len(head)-1] + map[bool]string{true: "1", false: "0"}[head[len(head)-1] == '0']
	if _, err := cmd("", "audit", "verify", "server", wrong); err == nil {
		t.Fatal("a wrong head accepted")
	}
	if out, err := cmd("", "audit", "export", "server", "json"); err != nil || !strings.Contains(out, `"action":"account.create"`) {
		t.Fatalf("audit export: %q %v", out, err)
	}
	if out, err := cmd("", "audit", "export", "server", "csv"); err != nil || !strings.HasPrefix(out, "seq,at,actor,action,details,hash") {
		t.Fatalf("audit export csv: %q %v", out, err)
	}
	for _, args := range [][]string{{}, {"nope"}, {"audit", "export", "server", "xml"}, {"create-owner"}} {
		if _, err := cmd("", args...); err == nil {
			t.Errorf("%q accepted", args)
		}
	}
}
