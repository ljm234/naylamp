package naylamp

import (
	"container/heap"

	"naylamp/engine/vector"
)

// mergeTopK folds per-shard nearest-neighbor lists into one global top k.
// Each input list must already be sorted by ascending distance, which is how
// a shard answers a search, and shard contents are disjoint by routing (one
// id lives on exactly one shard), so the merge never needs to deduplicate.
//
// The walk is a k-way merge over a min-heap of list heads, ordered by
// distance with ties broken by ascending id. The tie-break is what makes the
// output canonical: equal distances are common (orthogonal vectors all sit at
// the same cosine distance), and both the seeded simulation and an exact
// oracle comparison need the same inputs to produce the same output, byte for
// byte.
//
// The correctness this leans on is the standard equivalence for distributed
// top-k over disjoint shards: merging the per-shard top k and keeping the
// best k equals the top k of one index over the union, so the only
// approximation left in the pipeline is each shard's own index.
func mergeTopK(lists [][]vector.Neighbor, k int) []vector.Neighbor {
	if k <= 0 {
		return nil
	}
	h := &mergeHeap{lists: lists}
	for i, l := range lists {
		if len(l) > 0 {
			h.cursors = append(h.cursors, mergeCursor{list: i})
		}
	}
	heap.Init(h)
	out := make([]vector.Neighbor, 0, k)
	for h.Len() > 0 && len(out) < k {
		c := h.cursors[0]
		out = append(out, h.lists[c.list][c.pos])
		if c.pos+1 < len(h.lists[c.list]) {
			h.cursors[0].pos++
			heap.Fix(h, 0)
		} else {
			heap.Pop(h)
		}
	}
	return out
}

// mergeCursor points at the next unconsumed neighbor of one input list.
type mergeCursor struct {
	list int
	pos  int
}

// mergeHeap is the min-heap of list heads mergeTopK walks. Less orders by
// distance and breaks ties by ascending id, which keeps the merged output
// canonical for identical inputs.
type mergeHeap struct {
	lists   [][]vector.Neighbor
	cursors []mergeCursor
}

func (h *mergeHeap) head(i int) vector.Neighbor {
	c := h.cursors[i]
	return h.lists[c.list][c.pos]
}

func (h *mergeHeap) Len() int { return len(h.cursors) }

func (h *mergeHeap) Less(i, j int) bool {
	a, b := h.head(i), h.head(j)
	if a.Distance != b.Distance {
		return a.Distance < b.Distance
	}
	return a.ID < b.ID
}

func (h *mergeHeap) Swap(i, j int) { h.cursors[i], h.cursors[j] = h.cursors[j], h.cursors[i] }

func (h *mergeHeap) Push(x any) { h.cursors = append(h.cursors, x.(mergeCursor)) }

func (h *mergeHeap) Pop() any {
	old := h.cursors
	n := len(old)
	x := old[n-1]
	h.cursors = old[:n-1]
	return x
}
