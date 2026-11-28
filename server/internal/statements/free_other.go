//go:build !unix

package statements

// freeSpace isn't known here: the server runs on Linux.
func freeSpace(string) (int64, bool) { return 0, false }
