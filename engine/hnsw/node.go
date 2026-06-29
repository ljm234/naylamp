package hnsw

// node is one element in the HNSW graph. A node can live on several layers
// at once; on each layer it keeps its own list of neighbor ids. Think of the
// layers as the airplane/road/street maps: on the top (airplane) layer a node
// has a few far-reaching links, and on the bottom (street) layer it has many
// close ones.
type node struct {
	// id is the identifier of the stored vector this node represents.
	id uint64

	// neighbors[layer] holds the ids this node is connected to on that layer.
	// neighbors[0] is the bottom (densest) layer.
	neighbors [][]uint64
}

// newNode creates a node that occupies layers 0..topLayer (inclusive), with
// an empty neighbor list ready on each of those layers.
func newNode(id uint64, topLayer int) *node {
	neighbors := make([][]uint64, topLayer+1)
	for i := range neighbors {
		neighbors[i] = make([]uint64, 0)
	}
	return &node{
		id:        id,
		neighbors: neighbors,
	}
}

// layer returns the highest layer this node lives on.
func (n *node) layer() int {
	return len(n.neighbors) - 1
}
