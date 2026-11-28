//go:build unix

package statements

import "syscall"

// freeSpace is the room left on the disk of dir, for an unprivileged user.
func freeSpace(dir string) (int64, bool) {
	var st syscall.Statfs_t
	if syscall.Statfs(dir, &st) != nil {
		return 0, false
	}
	return int64(st.Bavail) * int64(st.Bsize), true
}
