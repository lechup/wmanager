package store_test

import (
	"context"
	"strings"
	"testing"

	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func TestRefusesSuperuser(t *testing.T) {
	_, err := store.Open(context.Background(), storetest.AdminURL(t))
	if err == nil || !strings.Contains(err.Error(), "superuser") {
		t.Fatalf("a superuser role: %v", err)
	}
}

func TestMigrateTwice(t *testing.T) {
	s := storetest.New(t)
	if err := s.Migrate(context.Background()); err != nil {
		t.Fatalf("migrating an up-to-date database: %v", err)
	}
}
