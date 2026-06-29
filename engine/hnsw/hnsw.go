// Package hnsw implements a Hierarchical Navigable Small World index for
// approximate nearest-neighbor search over vectors held in a vector.Store.
package hnsw

import (
	"math"
	"math/rand/v2"
	"sync"

	"naylamp/engine/vector"
)

// Default index parameters. These are the well-established starting values
// from the HNSW paper and are good for most datasets.
const (
	// DefaultM is how many neighbor connections each node keeps per layer.
	// Higher M means better search quality but more memory per node.
	DefaultM = 16

	// DefaultEfConstruction is how many candidate neighbors the builder
	// considers when inserting a node. Higher means a better-quality graph
	// but slower construction.
	DefaultEfConstruction = 200
)

// Params configures an HNSW index.
type Params struct {
	// M is the number of bidirectional connections per node per layer.
	M int
	// EfConstruction is the size of the candidate list during insertion.
	EfConstruction int
}

// DefaultParams returns Params populated with the standard values.
func DefaultParams() Params {
	return Params{
		M:              DefaultM,
		EfConstruction: DefaultEfConstruction,
	}
}

// Index is an HNSW graph: the full "album" of nodes plus the bookkeeping
// needed to navigate it. It stores graph structure (who links to whom); the
// actual vector data lives in the vector.Store, which the index queries
// through the provided metric. An RWMutex guards the graph so reads can run
// in parallel while writes (insertions) are exclusive.
type Index struct {
	mu sync.RWMutex

	params Params
	metric vector.MetricFunc

	// vectorData returns the raw components for a given id, sourced from the
	// vector store. The index needs these to measure distances during search.
	vectorData func(id uint64) ([]float32, bool)

	nodes      map[uint64]*node
	entryPoint uint64 // id of the node where every search starts
	maxLayer   int    // highest layer currently in the graph
	hasEntry   bool   // false until the first node is inserted
	levelMult  float64
	rng        *rand.Rand
}

// NewIndex creates an empty HNSW index. The metric chooses how similarity is
// measured; vectorData lets the index read vector components (typically backed
// by a vector.Store). A seed makes graph construction deterministic, which is
// essential for the reproducible testing we add later.
func NewIndex(params Params, metric vector.MetricFunc, vectorData func(id uint64) ([]float32, bool), seed uint64) *Index {
	return &Index{
		params:     params,
		metric:     metric,
		vectorData: vectorData,
		nodes:      make(map[uint64]*node),
		levelMult:  1.0 / math.Log(float64(params.M)),
		rng:        rand.New(rand.NewPCG(seed, 0)), //nolint:gosec // deterministic RNG for reproducible graph construction, not security
	}
}

// Len returns how many nodes are in the index.
func (idx *Index) Len() int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return len(idx.nodes)
}
