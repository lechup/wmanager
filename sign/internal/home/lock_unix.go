//go:build unix

package home

import (
	"os"
	"path/filepath"
	"syscall"
)

// Lock keeps a second wmanager-sign from changing the folder at the same time; it doesn't wait for one.
func (h *Home) Lock() (unlock func(), err error) {
	f, err := os.OpenFile(filepath.Join(h.Dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}
