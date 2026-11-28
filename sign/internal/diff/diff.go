// Package diff finds what changes from one text to another, line by line (Myers' algorithm), for wmanager-sign to
// show a file of a state as the difference from the last state it verified.
package diff

// Op is what happens to a line.
type Op byte

const (
	Same   Op = ' '
	Add    Op = '+'
	Remove Op = '-'
)

// Edit is one line of the difference, with its number in the old text (Remove, Same) or the new one (Add).
type Edit struct {
	Op   Op
	Line string
	Num  int // from 1
}

// MaxEdits bounds the search (its memory grows with their square): past it, the difference is given as every old
// line removed and every new one added, which is still exactly what changes, only longer to read.
const MaxEdits = 2000

// Lines is a shortest edit from a to b.
func Lines(a, b []string) []Edit {
	n, m := len(a), len(b)
	if n+m == 0 {
		return nil
	}
	maxD := min(n+m, MaxEdits)
	off := n + m + 1
	v := make([]int, 2*(n+m)+3)
	// trace[d] is v as round d found it, for the diagonals -d-1..d+1 only.
	var trace [][]int
	for d := 0; d <= maxD; d++ {
		trace = append(trace, append([]int(nil), v[off-d-1:off+d+2]...))
		for k := -d; k <= d; k += 2 {
			var x int
			if k == -d || (k != d && v[off+k-1] < v[off+k+1]) {
				x = v[off+k+1] // down: an addition
			} else {
				x = v[off+k-1] + 1 // right: a removal
			}
			y := x - k
			for x < n && y < m && a[x] == b[y] {
				x++
				y++
			}
			v[off+k] = x
			if x >= n && y >= m {
				return backtrack(a, b, trace, d)
			}
		}
	}
	out := make([]Edit, 0, n+m)
	for i, l := range a {
		out = append(out, Edit{Remove, l, i + 1})
	}
	for i, l := range b {
		out = append(out, Edit{Add, l, i + 1})
	}
	return out
}

func backtrack(a, b []string, trace [][]int, d int) []Edit {
	x, y := len(a), len(b)
	var rev []Edit
	for ; d > 0; d-- {
		v := trace[d]
		at := func(k int) int { return v[k+d+1] }
		k := x - y
		var prevK int
		if k == -d || (k != d && at(k-1) < at(k+1)) {
			prevK = k + 1
		} else {
			prevK = k - 1
		}
		prevX := at(prevK)
		prevY := prevX - prevK
		for x > prevX && y > prevY {
			x--
			y--
			rev = append(rev, Edit{Same, a[x], x + 1})
		}
		if x == prevX {
			y--
			rev = append(rev, Edit{Add, b[y], y + 1})
		} else {
			x--
			rev = append(rev, Edit{Remove, a[x], x + 1})
		}
	}
	for x > 0 && y > 0 {
		x--
		y--
		rev = append(rev, Edit{Same, a[x], x + 1})
	}
	out := make([]Edit, len(rev))
	for i, e := range rev {
		out[len(rev)-1-i] = e
	}
	return out
}

// Hunks groups the changes, each with up to context unchanged lines before and after it; unchanged lines further
// from any change are left out.
func Hunks(edits []Edit, context int) [][]Edit {
	keep := make([]bool, len(edits))
	for i, e := range edits {
		if e.Op != Same {
			for j := max(0, i-context); j <= min(len(edits)-1, i+context); j++ {
				keep[j] = true
			}
		}
	}
	var out [][]Edit
	var cur []Edit
	for i, e := range edits {
		if keep[i] {
			cur = append(cur, e)
		} else if cur != nil {
			out = append(out, cur)
			cur = nil
		}
	}
	if cur != nil {
		out = append(out, cur)
	}
	return out
}

// Count is how many lines are added and removed.
func Count(edits []Edit) (added, removed int) {
	for _, e := range edits {
		switch e.Op {
		case Add:
			added++
		case Remove:
			removed++
		}
	}
	return added, removed
}
