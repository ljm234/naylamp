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

// searchLayer explores a single layer of the graph starting from the given
// entry points and returns the ef closest nodes to the query found on that
// layer. It is the core navigation step: from each candidate it walks to
// neighbors that get closer, keeping the best ef results. ef controls how
// thorough the search is (bigger ef = more accurate, slower).
//
// This is used both during insertion (to find where to connect a new node)
// and during the final query (to collect the nearest neighbors on layer 0).
func (idx *Index) searchLayer(query []float32, entryPoints []uint64, ef, layer int) []candidate {
	visited := make(map[uint64]bool)

	// candidates: the frontier to explore, closest-first (minHeap).
	candidates := &minHeap{}
	heap.Init(candidates)

	// results: the best nodes found so far, farthest-first (maxHeap) so we can
	// cheaply drop the worst when we find something better.
	results := &maxHeap{}
	heap.Init(results)

	// Seed both heaps with the entry points.
	for _, id := range entryPoints {
		data, ok := idx.vectorData(id)
		if !ok {
			continue
		}
		d := idx.metric(query, data)
		heap.Push(candidates, candidate{id: id, dist: d})
		heap.Push(results, candidate{id: id, dist: d})
		visited[id] = true
	}

	for candidates.Len() > 0 {
		// Take the closest unexplored candidate.
		current := heap.Pop(candidates).(candidate)

		// If the closest candidate is farther than our worst result and we
		// already have ef results, we can stop: nothing better remains.
		if results.Len() >= ef && current.dist > (*results)[0].dist {
			break
		}

		// Look at the current node's neighbors on this layer.
		node, ok := idx.nodes[current.id]
		if !ok || layer > node.layer() {
			continue
		}
		for _, neighborID := range node.neighbors[layer] {
			if visited[neighborID] {
				continue
			}
			visited[neighborID] = true

			data, ok := idx.vectorData(neighborID)
			if !ok {
				continue
			}
			d := idx.metric(query, data)

			// Add the neighbor if we have room, or if it beats our worst result.
			if results.Len() < ef {
				heap.Push(candidates, candidate{id: neighborID, dist: d})
				heap.Push(results, candidate{id: neighborID, dist: d})
			} else if d < (*results)[0].dist {
				heap.Push(candidates, candidate{id: neighborID, dist: d})
				heap.Push(results, candidate{id: neighborID, dist: d})
				heap.Pop(results) // drop the current farthest
			}
		}
	}

	// Drain the results heap into a slice.
	out := make([]candidate, results.Len())
	for i := len(out) - 1; i >= 0; i-- {
		out[i] = heap.Pop(results).(candidate)
	}
	return out
}

// Search returns the k nearest neighbors to the query, as ids paired with
// distances, sorted nearest-first. It performs the full descent: from the
// entry point on the top layer it greedily moves closer on each layer, then
// does a thorough search on layer 0 to collect the final results. This is the
// airplane -> road -> street descent from the analogy.
func (idx *Index) Search(query []float32, k int) []vector.Neighbor {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	if !idx.hasEntry {
		return nil // empty index
	}

	// Start at the entry point on the highest layer.
	entry := []uint64{idx.entryPoint}

	// Descend from the top layer down to layer 1, moving closer each time.
	// On these upper layers we only need the single closest node (ef = 1) to
	// carry forward as the entry point for the next layer down.
	for layer := idx.maxLayer; layer >= 1; layer-- {
		found := idx.searchLayer(query, entry, 1, layer)
		if len(found) > 0 {
			entry = []uint64{found[0].id}
		}
	}

	// On layer 0, search thoroughly: use ef = max(k, EfConstruction) so we
	// gather enough candidates to return a high-quality top-k.
	ef := idx.params.EfConstruction
	if k > ef {
		ef = k
	}
	found := idx.searchLayer(query, entry, ef, 0)

	// Convert the closest k into the public Neighbor type.
	if k < len(found) {
		found = found[:k]
	}
	out := make([]vector.Neighbor, len(found))
	for i, c := range found {
		out[i] = vector.Neighbor{ID: c.id, Distance: c.dist}
	}
	return out
}
