package statements

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
)

// MaxStored is the largest file add-file takes.
const MaxStored = 4 << 30

// Errors of stored files.
var (
	ErrNoStore  = errors.New("statements: files added with add-file need WMANAGER_FILES_DIR")
	ErrFileHash = errors.New("statements: the file doesn't match its hash")
)

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// storedPath is where a company's file is kept: under the company's id, by its hash in hex.
func storedPath(dir, companyID string, hash [32]byte) string {
	return filepath.Join(dir, companyID, hex.EncodeToString(hash[:]))
}

// StoreFile keeps a file added with wmanager-sign add-file by one of the company's administrators, read from r and
// checked against its SHA-256: written aside, then put in its place, so a file kept is always whole.
func StoreFile(ctx context.Context, s *store.Store, dir, accountID, companyID string, want [32]byte, r io.Reader) (int64, error) {
	if dir == "" {
		return 0, ErrNoStore
	}
	if !uuidRe.MatchString(companyID) {
		return 0, ErrNotMember
	}
	if err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		return member(ctx, tx, accountID, companyID, true)
	}); err != nil {
		return 0, err
	}
	folder := filepath.Join(dir, companyID)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(folder, ".upload-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(r, MaxStored+1))
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	switch {
	case err != nil:
		return 0, err
	case n > MaxStored:
		return 0, ErrTooLarge
	case [32]byte(h.Sum(nil)) != want:
		return 0, ErrFileHash
	}
	if err := os.Rename(tmp.Name(), storedPath(dir, companyID, want)); err != nil {
		return 0, err
	}
	err = s.Tx(ctx, store.System, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `INSERT INTO stored_files (company_id, hash, size) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`,
			companyID, want[:], n)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		_, err = audit.Append(ctx, tx, audit.CompanyChain(companyID), companyID, "account:"+accountID, "file.added",
			map[string]any{"hash": hex.EncodeToString(want[:]), "size": n})
		return err
	})
	return n, err
}
