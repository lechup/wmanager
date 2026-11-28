package diff

import (
	"math/rand/v2"
	"slices"
	"strconv"
	"testing"
)

// apply checks that the edits turn a into b, with the right line numbers.
func apply(t *testing.T, a, b []string, edits []Edit) {
	t.Helper()
	var gotA, gotB []string
	for _, e := range edits {
		switch e.Op {
		case Same:
			gotA, gotB = append(gotA, e.Line), append(gotB, e.Line)
			if e.Num != len(gotA) {
				t.Fatalf("a same line numbered %d, at %d", e.Num, len(gotA))
			}
		case Remove:
			gotA = append(gotA, e.Line)
			if e.Num != len(gotA) {
				t.Fatalf("a removed line numbered %d, at %d", e.Num, len(gotA))
			}
		case Add:
			gotB = append(gotB, e.Line)
			if e.Num != len(gotB) {
				t.Fatalf("an added line numbered %d, at %d", e.Num, len(gotB))
			}
		}
	}
	if !slices.Equal(gotA, a) || !slices.Equal(gotB, b) {
		t.Fatalf("edits of %q to %q give %q and %q", a, b, gotA, gotB)
	}
}

func lcs(a, b []string) int {
	dp := make([][]int, len(a)+1)
	for i := range dp {
		dp[i] = make([]int, len(b)+1)
	}
	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				dp[i][j] = dp[i+1][j+1] + 1
			} else {
				dp[i][j] = max(dp[i+1][j], dp[i][j+1])
			}
		}
	}
	return dp[0][0]
}

func TestShortest(t *testing.T) {
	r := rand.New(rand.NewPCG(1, 2))
	for i := 0; i < 2000; i++ {
		a, b := make([]string, r.IntN(12)), make([]string, r.IntN(12))
		for j := range a {
			a[j] = strconv.Itoa(r.IntN(4))
		}
		for j := range b {
			b[j] = strconv.Itoa(r.IntN(4))
		}
		edits := Lines(a, b)
		apply(t, a, b, edits)
		added, removed := Count(edits)
		if want := len(a) + len(b) - 2*lcs(a, b); added+removed != want {
			t.Fatalf("%q to %q: %d edits, the shortest is %d", a, b, added+removed, want)
		}
	}
}

func TestTooManyEdits(t *testing.T) {
	a, b := make([]string, MaxEdits), make([]string, MaxEdits)
	for i := range a {
		a[i], b[i] = "a"+strconv.Itoa(i), "b"+strconv.Itoa(i)
	}
	edits := Lines(a, b)
	apply(t, a, b, edits)
	if added, removed := Count(edits); added != MaxEdits || removed != MaxEdits {
		t.Fatalf("%d added, %d removed", added, removed)
	}
}

func TestHunks(t *testing.T) {
	a := []string{"1", "2", "3", "4", "5", "6", "7", "8", "9", "10"}
	b := []string{"1", "2", "x", "4", "5", "6", "7", "8", "9", "10", "11"}
	h := Hunks(Lines(a, b), 1)
	if len(h) != 2 || len(h[0]) != 4 || h[0][0].Line != "2" || h[1][len(h[1])-1].Line != "11" {
		t.Fatalf("hunks: %+v", h)
	}
	if Hunks(Lines(a, a), 3) != nil {
		t.Fatal("hunks of no change")
	}
}
