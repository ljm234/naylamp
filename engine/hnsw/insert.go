package hnsw

import (
	"math"

	"naylamp/engine/vector"
)

// randomLayer draws the top layer for a new node. Most draws return 0 (the
// node lives only on the bottom layer); occasionally a higher layer is drawn,
// making that node a long-range "shortcut" on the upper maps. This is the
// exponentially-decaying level assignment from the HNSW paper.
func (idx *Index) randomLayer() int {
	r := idx.rng.Float64()
	if r == 0 {
		r = 1e-9 // avoid log(0)
	}
	return int(-math.Log(r) * idx.levelMult)
}

// Insert adds the vector with the given id to the index and wires it into the
// graph. If the id already exists, it is removed first so the update does not
// leave stale connections pointing at an outdated node (an upsert is therefore
// a clean delete-then-insert). On each layer it selects up to M diverse
// neighbors and links to them; existing neighbors that grow past their cap are
// pruned, but the new node is not (it already chose its best M).
func (idx *Index) Insert(id uint64) error {
	data, ok := idx.vectorData(id)
	if !ok {
		return vector.ErrNotFound
	}

	idx.mu.Lock()
	defer idx.mu.Unlock()

	// If this id is already in the graph (an update), remove the old node and
	// all its connections first. Otherwise stale edges would linger and corrupt
	// search results. deleteLocked assumes the lock is already held.
	if _, exists := idx.nodes[id]; exists {
		idx.deleteLocked(id)
	}

	topLayer := idx.randomLayer()
	n := newNode(id, data, topLayer)
	idx.nodes[id] = n

	// The new vector's norm, computed once and reused for the layer searches
	// below (matching the query-norm optimization used during queries).
	dataNorm := n.norm

	// First node ever: it becomes the entry point, no neighbors to connect.
	if !idx.hasEntry {
		idx.entryPoint = id
		idx.maxLayer = topLayer
		idx.hasEntry = true
		return nil
	}

	// Descend from the current top down to just above the new node's top
	// layer, greedily moving to the closest node (ef = 1) to get a good entry.
	entry := []uint64{idx.entryPoint}
	for layer := idx.maxLayer; layer > topLayer; layer-- {
		found := idx.searchLayer(data, dataNorm, entry, 1, layer)
		if len(found) > 0 {
			entry = []uint64{found[0].id}
		}
	}

	// From the new node's top layer down to 0, select a diverse set of M
	// neighbors and link to them. The new node's own list is built exactly from
	// these M (already optimal), so it is never shrunk. Each existing neighbor
	// gains one edge and is shrunk only if it now exceeds its cap.
	for layer := min(topLayer, idx.maxLayer); layer >= 0; layer-- {
		found := idx.searchLayer(data, dataNorm, entry, idx.params.EfConstruction, layer)
		selected := idx.selectNeighbors(found, idx.params.M)

		maxConn := idx.maxConnections(layer)
		for _, c := range selected {
			nbr, ok := idx.nodes[c.id]
			if !ok || layer > nbr.layer() {
				continue
			}
			// Link both directions.
			n.neighbors[layer] = append(n.neighbors[layer], c.id)
			nbr.neighbors[layer] = append(nbr.neighbors[layer], id)
			// Only the existing neighbor may have overflowed; prune it if so.
			idx.shrinkNeighbors(c.id, layer, maxConn)
		}

		if len(found) > 0 {
			entry = []uint64{found[0].id}
		}
	}

	// If the new node is taller than everything else, it is the new entry.
	if topLayer > idx.maxLayer {
		idx.maxLayer = topLayer
		idx.entryPoint = id
	}
	return nil
}

// maxConnections returns the maximum number of neighbors a node may keep on the
// given layer. Following the HNSW paper, layer 0 allows 2*M (it is the densest,
// most-traversed layer) while upper layers allow M.
func (idx *Index) maxConnections(layer int) int {
	if layer == 0 {
		return 2 * idx.params.M
	}
	return idx.params.M
}
