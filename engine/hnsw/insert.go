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
// graph. It assigns a random top layer, then on each layer finds the nearest
// existing nodes and connects to them bidirectionally, so future searches can
// navigate to and through the new node.
func (idx *Index) Insert(id uint64) error {
	data, ok := idx.vectorData(id)
	if !ok {
		return vector.ErrNotFound
	}

	idx.mu.Lock()
	defer idx.mu.Unlock()

	topLayer := idx.randomLayer()
	n := newNode(id, topLayer)
	idx.nodes[id] = n

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
		found := idx.searchLayer(data, entry, 1, layer)
		if len(found) > 0 {
			entry = []uint64{found[0].id}
		}
	}

	// From the new node's top layer down to 0, find nearby nodes and connect.
	for layer := min(topLayer, idx.maxLayer); layer >= 0; layer-- {
		found := idx.searchLayer(data, entry, idx.params.EfConstruction, layer)

		// Connect to the closest M neighbors on this layer, both directions.
		count := 0
		for _, c := range found {
			if count >= idx.params.M {
				break
			}
			idx.connect(id, c.id, layer)
			count++
		}

		// Carry the closest found node forward as the entry for the next layer.
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

// connect adds a bidirectional link between two nodes on the given layer.
// "Bidirectional" means each node lists the other as a neighbor, so the graph
// can be traversed from either side.
func (idx *Index) connect(a, b uint64, layer int) {
	nodeA, okA := idx.nodes[a]
	nodeB, okB := idx.nodes[b]
	if !okA || !okB {
		return
	}
	if layer <= nodeA.layer() {
		nodeA.neighbors[layer] = append(nodeA.neighbors[layer], b)
	}
	if layer <= nodeB.layer() {
		nodeB.neighbors[layer] = append(nodeB.neighbors[layer], a)
	}
}
