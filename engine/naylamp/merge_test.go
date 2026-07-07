package naylamp

import (
	"sort"
	"testing"

	"naylamp/engine/vector"
)

// sortReference is the merge's own oracle: concatenate every list, sort by
// distance with ties broken by id, keep the best k. mergeTopK must match it
// exactly on every input.
func sortReference(lists [][]vector.Neighbor, k int) []vector.Neighbor {
	if k <= 0 {
		return nil
	}
	var all []vector.Neighbor
	for _, l := range lists {
		all = append(all, l...)
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].Distance != all[j].Distance {
			return all[i].Distance < all[j].Distance
		}
		return all[i].ID < all[j].ID
	})
	if len(all) > k {
		all = all[:k]
	}
	return all
}

// equalNeighbors compares element by element, treating nil and empty as the
// same absence of results.
func equalNeighbors(a, b []vector.Neighbor) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestMergeTopK_MatchesSortReference(t *testing.T) {
	l := func(ns ...vector.Neighbor) []vector.Neighbor { return ns }
	n := func(id uint64, d float32) vector.Neighbor { return vector.Neighbor{ID: id, Distance: d} }

	cases := []struct {
		name  string
		lists [][]vector.Neighbor
		k     int
	}{
		{"three interleaved lists", [][]vector.Neighbor{
			l(n(1, 0.1), n(4, 0.4), n(7, 0.9)),
			l(n(2, 0.2), n(5, 0.5)),
			l(n(3, 0.3), n(6, 0.6), n(8, 1.2), n(9, 1.5)),
		}, 5},
		{"k beyond the union returns everything", [][]vector.Neighbor{
			l(n(1, 0.1)), l(n(2, 0.2)),
		}, 10},
		{"k zero returns nothing", [][]vector.Neighbor{
			l(n(1, 0.1)),
		}, 0},
		{"an empty list among full ones", [][]vector.Neighbor{
			l(n(1, 0.3)), nil, l(n(2, 0.1), n(3, 0.2)),
		}, 3},
		{"all lists empty", [][]vector.Neighbor{nil, {}, nil}, 4},
		{"single list passthrough", [][]vector.Neighbor{
			l(n(5, 0.5), n(6, 0.6), n(7, 0.7)),
		}, 2},
		{"no lists at all", nil, 3},
	}
	for _, c := range cases {
		got := mergeTopK(c.lists, c.k)
		want := sortReference(c.lists, c.k)
		if !equalNeighbors(got, want) {
			t.Fatalf("%s: merge %+v, reference %+v", c.name, got, want)
		}
	}
}

func TestMergeTopK_TieBreaksByAscendingID(t *testing.T) {
	// Every neighbor sits at the same distance, the common case for
	// orthogonal vectors under cosine. The merged order must be by id, no
	// matter which list each id came from.
	lists := [][]vector.Neighbor{
		{{ID: 9, Distance: 1}, {ID: 12, Distance: 1}},
		{{ID: 3, Distance: 1}, {ID: 10, Distance: 1}},
		{{ID: 7, Distance: 1}},
	}
	got := mergeTopK(lists, 4)
	want := []vector.Neighbor{{ID: 3, Distance: 1}, {ID: 7, Distance: 1}, {ID: 9, Distance: 1}, {ID: 10, Distance: 1}}
	if !equalNeighbors(got, want) {
		t.Fatalf("tie-break order wrong: %+v, want %+v", got, want)
	}
}

func TestMergeTopK_SweepAgainstReference(t *testing.T) {
	// A deterministic sweep over list shapes and k values, no randomness:
	// four lists whose sizes and distances follow arithmetic patterns,
	// including cross-list ties, checked against the reference at every k.
	var lists [][]vector.Neighbor
	id := uint64(1)
	for li := 0; li < 4; li++ {
		var list []vector.Neighbor
		for p := 0; p <= li*2; p++ {
			d := float32(li+p) * 0.25 // collides across lists on purpose
			list = append(list, vector.Neighbor{ID: id, Distance: d})
			id++
		}
		sort.Slice(list, func(i, j int) bool {
			if list[i].Distance != list[j].Distance {
				return list[i].Distance < list[j].Distance
			}
			return list[i].ID < list[j].ID
		})
		lists = append(lists, list)
	}
	total := 0
	for _, l := range lists {
		total += len(l)
	}
	for k := 0; k <= total+2; k++ {
		got := mergeTopK(lists, k)
		want := sortReference(lists, k)
		if !equalNeighbors(got, want) {
			t.Fatalf("k=%d: merge %+v, reference %+v", k, got, want)
		}
	}
}
