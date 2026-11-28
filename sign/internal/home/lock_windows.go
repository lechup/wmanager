package home

import (
	"os"
	"path/filepath"

	"golang.org/x/sys/windows"
)

// Lock keeps a second wmanager-sign from changing the folder at the same time; it doesn't wait for one.
func (h *Home) Lock() (unlock func(), err error) {
	f, err := os.OpenFile(filepath.Join(h.Dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	ol := new(windows.Overlapped)
	if err := windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY,
		0, 1, 0, ol); err != nil {
		f.Close()
		return nil, err
	}
	return func() { windows.UnlockFileEx(windows.Handle(f.Fd()), 0, 1, 0, ol); f.Close() }, nil
}
