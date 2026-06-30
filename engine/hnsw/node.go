package hnsw

import "math"

// node is one element in the HNSW graph. A node can live on several layers
// at once; on each layer it keeps its own list of neighbor ids. Think of the
// layers as the airplane/road/street maps: on the top (airplane) layer a node
// has a few far-reaching links, and on the bottom (street) layer it has many
// close ones.
//
// The node caches the vector's data and its precomputed L2 norm directly.
// Keeping these next to the node (rather than recomputing on every distance
// call) is a major optimization: cosine distance needs each vector's norm, and
// for stored vectors that norm never changes, so computing it once at insert
// time removes a large amount of repeated work from the search hot loop.
type node struct {
	// id is the identifier of the stored vector this node represents.
	id uint64

	// data is the vector's components, cached here for fast distance math.
	data []float32

	// norm is the precomputed Euclidean (L2) norm of data, used to make cosine
	// distance cheap. It is sqrt(sum(data[i]^2)).
	norm float32

	// neighbors[layer] holds the ids this node is connected to on that layer.
	// neighbors[0] is the bottom (densest) layer.
	neighbors [][]uint64
}

// newNode creates a node that occupies layers 0..topLayer (inclusive), with an
// empty neighbor list ready on each of those layers, and caches its data and
// precomputed norm.
func newNode(id uint64, data []float32, topLayer int) *node {
	neighbors := make([][]uint64, topLayer+1)
	for i := range neighbors {
		neighbors[i] = make([]uint64, 0)
	}
	return &node{
		id:        id,
		data:      data,
		norm:      computeNorm(data),
		neighbors: neighbors,
	}
}

// computeNorm returns the Euclidean (L2) norm of a vector: the square root of
// the sum of its squared components. Accumulated in float64 to limit rounding
// error, then returned as float32.
func computeNorm(data []float32) float32 {
	var sum float64
	for _, x := range data {
		sum += float64(x) * float64(x)
	}
	return float32(math.Sqrt(sum))
}

// layer returns the highest layer this node lives on.
func (n *node) layer() int {
	return len(n.neighbors) - 1
}
