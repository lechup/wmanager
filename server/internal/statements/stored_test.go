package statements

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestStoredFiles(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	dir := t.TempDir()
	driver := bytes.Repeat([]byte{0x4d, 0x5a, 0, 1}, 1<<16)
	h := sha256.Sum256(driver)
	if _, err := StoreFile(ctx, e.s, "", e.admin, e.company, h, bytes.NewReader(driver)); !errors.Is(err, ErrNoStore) {
		t.Fatalf("without a folder: %v", err)
	}
	for name, c := range map[string]struct {
		account string
		hash    [32]byte
		want    error
	}{
		"a person":          {e.person, h, ErrNotAdmin},
		"another's company": {e.outside, h, ErrNotMember},
		"another hash":      {e.admin, [32]byte{1}, ErrFileHash},
	} {
		if _, err := StoreFile(ctx, e.s, dir, c.account, e.company, c.hash, bytes.NewReader(driver)); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	if n, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, bytes.NewReader(driver)); err != nil || n != int64(len(driver)) {
		t.Fatalf("StoreFile: %d %v", n, err)
	}
	// Again: kept once.
	if _, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, bytes.NewReader(driver)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(storedPath(dir, e.company, h))
	if err != nil || !bytes.Equal(got, driver) {
		t.Fatalf("the file on disk: %v", err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, e.company, ".upload-*")); len(left) != 0 {
		t.Fatalf("uploads left behind: %v", left)
	}
	fi, _ := os.Stat(filepath.Join(dir, e.company))
	if fi.Mode().Perm()&0o077 != 0 {
		t.Fatalf("the company's folder is %v", fi.Mode().Perm())
	}
	// A state may name it.
	st := e.state(e.key, 1, server, map[string][]byte{"drivers/x.cab": driver}, nil)
	if _, err := SubmitState(ctx, e.s, server, e.admin, e.company, st, "", nil); err != nil {
		t.Fatalf("a state naming a stored file: %v", err)
	}
}
