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

// Limits of the files add-file adds: one file, a company's together, the room left on the disk after one, and
// how many arrive at once on the whole server.
const (
	MaxStored        = 4 << 30
	MaxStoredCompany = 64 << 30
	MinFree          = 2 << 30
	MaxUploads       = 4
)

// Errors of stored files.
var (
	ErrNoStore  = errors.New("statements: files added with add-file need WMANAGER_FILES_DIR")
	ErrFileHash = errors.New("statements: the file doesn't match its hash")
	ErrQuota    = errors.New("statements: the company's files added with add-file would take more than 64 GB, or the disk would be nearly full")
	ErrBusy     = errors.New("statements: too many files are arriving at once: try again in a moment")
)

// uploads are the uploads under way, at most MaxUploads.
var uploads = make(chan struct{}, MaxUploads)

// uploadsDir is where files arrive before they are checked: cleaned when the server starts, so an upload cut
// short by a crash doesn't stay.
func uploadsDir(dir string) string { return filepath.Join(dir, ".uploads") }

// CleanUploads removes what uploads cut short left behind.
func CleanUploads(dir string) error {
	if dir == "" {
		return nil
	}
	if err := os.RemoveAll(uploadsDir(dir)); err != nil {
		return err
	}
	return os.MkdirAll(uploadsDir(dir), 0o700)
}

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// storedPath is where a company's file is kept: under the company's id, by its hash in hex.
func storedPath(dir, companyID string, hash [32]byte) string {
	return filepath.Join(dir, companyID, hex.EncodeToString(hash[:]))
}

// StoreFile keeps a file added with wmanager-sign add-file by one of the company's administrators, read from r and
// checked against its SHA-256: written aside, then put in its place, so a file kept is always whole. size is the
// size announced (-1 when unknown), refused at once when over a limit.
func StoreFile(ctx context.Context, s *store.Store, dir, accountID, companyID string, want [32]byte, size int64, r io.Reader) (int64, error) {
	if dir == "" {
		return 0, ErrNoStore
	}
	if !uuidRe.MatchString(companyID) {
		return 0, ErrNotMember
	}
	if size > MaxStored {
		return 0, ErrTooLarge
	}
	var used int64
	if err := s.Tx(ctx, store.Who{Account: accountID}, func(tx pgx.Tx) error {
		if err := member(ctx, tx, accountID, companyID, true); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT coalesce(sum(size), 0) FROM stored_files WHERE company_id = $1`, companyID).Scan(&used)
	}); err != nil {
		return 0, err
	}
	limit := min(int64(MaxStored), MaxStoredCompany-used)
	if free, ok := freeSpace(dir); ok {
		limit = min(limit, free-MinFree)
	}
	if limit <= 0 || size > limit {
		return 0, ErrQuota
	}
	select {
	case uploads <- struct{}{}:
		defer func() { <-uploads }()
	default:
		return 0, ErrBusy
	}
	if err := os.MkdirAll(uploadsDir(dir), 0o700); err != nil {
		return 0, err
	}
	folder := filepath.Join(dir, companyID)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return 0, err
	}
	tmp, err := os.CreateTemp(uploadsDir(dir), "upload-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), io.LimitReader(r, limit+1))
	if err == nil {
		err = tmp.Sync()
	}
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	switch {
	case err != nil:
		return 0, err
	case n > limit && limit == MaxStored:
		return 0, ErrTooLarge
	case n > limit:
		return 0, ErrQuota
	case [32]byte(h.Sum(nil)) != want:
		return 0, ErrFileHash
	}
	if err := os.Rename(tmp.Name(), storedPath(dir, companyID, want)); err != nil {
		return 0, err
	}
	// The rename kept, before the row says the file is here.
	if d, err := os.Open(folder); err == nil {
		d.Sync()
		d.Close()
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
