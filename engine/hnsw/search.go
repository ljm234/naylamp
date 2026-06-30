package hnsw

import (
	"container/heap"

	"naylamp/engine/vector"
)

// candidate is a node id paired with its distance to the query. The search
// uses these to always know which node is currently closest.
type candidate struct {
	id   uint64
	dist float32
}

// minHeap is a priority queue that pops the SMALLEST distance first. We use it
// for the frontier of nodes to explore: always expand the closest one next.
type minHeap []candidate

func (h minHeap) Len() int           { return len(h) }
func (h minHeap) Less(i, j int) bool { return h[i].dist < h[j].dist }
func (h minHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x any)        { *h = append(*h, x.(candidate)) }
func (h *minHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}

// maxHeap pops the LARGEST distance first. We use it to hold the best results
// found so far: when it is full and we find something closer, we drop the
// current farthest (the top of this heap).
type maxHeap []candidate

func (h maxHeap) Len() int           { return len(h) }
func (h maxHeap) Less(i, j int) bool { return h[i].dist > h[j].dist }
func (h maxHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *maxHeap) Push(x any)        { *h = append(*h, x.(candidate)) }
func (h *maxHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}

// ensure the heaps satisfy the heap.Interface.
var _ heap.Interface = (*minHeap)(nil)
var _ heap.Interface = (*maxHeap)(nil)

// queryDistance returns the distance from the query to a node. When the cosine
// fast path is active it uses the query's precomputed norm together with the
// node's cached norm; otherwise it falls back to the generic metric. queryNorm
// is computed once per search and reused for every comparison.
func (idx *Index) queryDistance(query []float32, queryNorm float32, n *node) float32 {
	if idx.useCosineFast {
		return cosineDistanceWithNorms(query, n.data, queryNorm, n.norm)
	}
	return idx.metric(query, n.data)
}

// searchLayer explores a single layer of the graph starting from the given
// entry points and returns the ef closest nodes to the query found on that
// layer. It is the core navigation step: from each candidate it walks to
// neighbors that get closer, keeping the best ef results.
//
// Distances use cached node norms (and a query norm computed once here) via the
// cosine fast path when available, removing repeated norm computation from this
// hot loop. The visited set and both heaps are pre-sized from ef.
func (idx *Index) searchLayer(query []float32, queryNorm float32, entryPoints []uint64, ef, layer int) []candidate {
	visited := make(map[uint64]struct{}, ef*8)

	candidates := make(minHeap, 0, ef*2)
	cHeap := &candidates

	results := make(maxHeap, 0, ef+1)
	rHeap := &results

	// Seed both heaps with the entry points.
	for _, id := range entryPoints {
		n, ok := idx.nodes[id]
		if !ok {
			continue
		}
		d := idx.queryDistance(query, queryNorm, n)
		heap.Push(cHeap, candidate{id: id, dist: d})
		heap.Push(rHeap, candidate{id: id, dist: d})
		visited[id] = struct{}{}
	}

	for cHeap.Len() > 0 {
		current := heap.Pop(cHeap).(candidate)

		if rHeap.Len() >= ef && current.dist > results[0].dist {
			break
		}

		node, ok := idx.nodes[current.id]
		if !ok || layer > node.layer() {
			continue
		}
		for _, neighborID := range node.neighbors[layer] {
			if _, seen := visited[neighborID]; seen {
				continue
			}
			visited[neighborID] = struct{}{}

			neighbor, ok := idx.nodes[neighborID]
			if !ok {
				continue
			}
			d := idx.queryDistance(query, queryNorm, neighbor)

			if rHeap.Len() < ef {
				heap.Push(cHeap, candidate{id: neighborID, dist: d})
				heap.Push(rHeap, candidate{id: neighborID, dist: d})
			} else if d < results[0].dist {
				heap.Push(cHeap, candidate{id: neighborID, dist: d})
				heap.Push(rHeap, candidate{id: neighborID, dist: d})
				heap.Pop(rHeap)
			}
		}
	}

	out := make([]candidate, rHeap.Len())
	for i := len(out) - 1; i >= 0; i-- {
		out[i] = heap.Pop(rHeap).(candidate)
	}
	return out
}

// Search returns the k nearest neighbors to the query, as ids paired with
// distances, sorted nearest-first. It performs the full descent: from the entry
// point on the top layer it greedily moves closer on each layer, then does a
// thorough search on layer 0 to collect the final results. The query's norm is
// computed once up front and threaded through the layer searches.
func (idx *Index) Search(query []float32, k int) []vector.Neighbor {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	if !idx.hasEntry {
		return nil // empty index
	}

	queryNorm := computeNorm(query)
	entry := []uint64{idx.entryPoint}

	for layer := idx.maxLayer; layer >= 1; layer-- {
		found := idx.searchLayer(query, queryNorm, entry, 1, layer)
		if len(found) > 0 {
			entry = []uint64{found[0].id}
		}
	}

	ef := idx.params.EfSearch
	if k > ef {
		ef = k
	}
	found := idx.searchLayer(query, queryNorm, entry, ef, 0)

	if k < len(found) {
		found = found[:k]
	}
	out := make([]vector.Neighbor, len(found))
	for i, c := range found {
		out[i] = vector.Neighbor{ID: c.id, Distance: c.dist}
	}
	return out
}
