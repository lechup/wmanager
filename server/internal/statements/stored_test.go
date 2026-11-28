package statements

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func TestStoredFiles(t *testing.T) {
	e := setup(t)
	ctx := context.Background()
	dir := t.TempDir()
	driver := bytes.Repeat([]byte{0x4d, 0x5a, 0, 1}, 1<<16)
	h := sha256.Sum256(driver)
	if _, err := StoreFile(ctx, e.s, "", e.admin, e.company, h, -1, bytes.NewReader(driver)); !errors.Is(err, ErrNoStore) {
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
		if _, err := StoreFile(ctx, e.s, dir, c.account, e.company, c.hash, -1, bytes.NewReader(driver)); !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", name, err, c.want)
		}
	}
	if n, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, -1, bytes.NewReader(driver)); err != nil || n != int64(len(driver)) {
		t.Fatalf("StoreFile: %d %v", n, err)
	}
	// Again: kept once.
	if _, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, -1, bytes.NewReader(driver)); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(storedPath(dir, e.company, h))
	if err != nil || !bytes.Equal(got, driver) {
		t.Fatalf("the file on disk: %v", err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".uploads", "*")); len(left) != 0 {
		t.Fatalf("uploads left behind: %v", left)
	}
	fi, _ := os.Stat(filepath.Join(dir, e.company))
	if fi.Mode().Perm()&0o077 != 0 {
		t.Fatalf("the company's folder is %v", fi.Mode().Perm())
	}
	// One upload a company at a time: a second waits for the first.
	pr, pw := io.Pipe()
	done := make(chan error)
	slow := []byte("slow")
	go func() {
		_, err := StoreFile(ctx, e.s, dir, e.admin, e.company, sha256.Sum256(slow), -1, pr)
		done <- err
	}()
	pw.Write(slow[:1])
	for range 500 {
		uploading.Lock()
		busy := uploading.company[e.company]
		uploading.Unlock()
		if busy {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, -1, bytes.NewReader(driver)); !errors.Is(err, ErrBusy) {
		t.Fatalf("a second upload of the company at once: %v", err)
	}
	pw.Write(slow[1:])
	pw.Close()
	if err := <-done; err != nil && !errors.Is(err, ErrQuota) {
		t.Fatalf("the first upload: %v", err)
	}
	// Over the limits, refused before anything is read.
	if _, err := StoreFile(ctx, e.s, dir, e.admin, e.company, h, MaxStored+1, bytes.NewReader(driver)); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("a file announced too large: %v", err)
	}
	db := storetest.Superuser(t, e.s)
	if _, err := db.Exec(ctx, `INSERT INTO stored_files (company_id, hash, size) VALUES ($1, $2, $3)`,
		e.company, bytes.Repeat([]byte{7}, 32), int64(MaxStoredCompany-1000)); err != nil {
		t.Fatal(err)
	}
	other := bytes.Repeat([]byte{9}, 2000)
	if _, err := StoreFile(ctx, e.s, dir, e.admin, e.company, sha256.Sum256(other), -1, bytes.NewReader(other)); !errors.Is(err, ErrQuota) {
		t.Fatalf("over the company's quota: %v", err)
	}
	// An upload cut short leaves nothing after the next start.
	os.WriteFile(filepath.Join(dir, ".uploads", "upload-1"), []byte("half"), 0o600)
	if err := CleanUploads(dir); err != nil {
		t.Fatal(err)
	}
	if left, _ := filepath.Glob(filepath.Join(dir, ".uploads", "*")); len(left) != 0 {
		t.Fatalf("left after a start: %v", left)
	}
	// A state may name it.
	st := e.state(e.key, 1, server, map[string][]byte{"drivers/x.cab": driver}, nil)
	if _, err := SubmitState(ctx, e.s, server, e.admin, e.company, st, "", nil); err != nil {
		t.Fatalf("a state naming a stored file: %v", err)
	}
}
