// Package hnsw implements a Hierarchical Navigable Small World index for
// approximate nearest-neighbor search over vectors held in a vector.Store.
package hnsw

import (
	"math"
	"math/rand/v2"
	"reflect"
	"sync"

	"naylamp/engine/vector"
)

// Default index parameters. These favor recall at larger scale (tens of
// thousands of vectors and up), at the cost of more memory per node and
// somewhat slower search. For small datasets, smaller values would be faster
// with comparable recall.
const (
	// DefaultM is how many neighbor connections each node keeps per layer.
	// Higher M sustains recall as the dataset grows, at the cost of memory.
	DefaultM = 32

	// DefaultEfConstruction is how many candidate neighbors the builder
	// considers when inserting a node. Higher means a better-quality graph
	// but slower construction.
	DefaultEfConstruction = 400

	// DefaultEfSearch is how many candidates the search explores on layer 0.
	// Higher sustains recall at scale, at the cost of slower queries. It must
	// be >= k for a given query; Search raises it if not.
	DefaultEfSearch = 300
)

// Params configures an HNSW index.
type Params struct {
	// M is the number of bidirectional connections per node per layer.
	M int
	// EfConstruction is the size of the candidate list during insertion.
	EfConstruction int
	// EfSearch is the size of the candidate list during a query on layer 0.
	EfSearch int
}

// DefaultParams returns Params populated with the standard values.
func DefaultParams() Params {
	return Params{
		M:              DefaultM,
		EfConstruction: DefaultEfConstruction,
		EfSearch:       DefaultEfSearch,
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

	// useCosineFast is true when metric is vector.CosineDistance, enabling an
	// internal fast path that reuses each node's precomputed norm instead of
	// recomputing norms on every distance call.
	useCosineFast bool

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
		params:        params,
		metric:        metric,
		useCosineFast: sameFunc(metric, vector.CosineDistance),
		vectorData:    vectorData,
		nodes:         make(map[uint64]*node),
		levelMult:     1.0 / math.Log(float64(params.M)),
		rng:           rand.New(rand.NewPCG(seed, 0)), //nolint:gosec // deterministic RNG for reproducible graph construction, not security
	}
}

// sameFunc reports whether two metric functions are the same underlying
// function, used to detect when the cosine fast path applies. Go cannot compare
// funcs with ==, so we compare their code pointers via reflect.
func sameFunc(a, b vector.MetricFunc) bool {
	return reflect.ValueOf(a).Pointer() == reflect.ValueOf(b).Pointer()
}

// Len returns how many nodes are in the index.
func (idx *Index) Len() int {
	idx.mu.RLock()
	defer idx.mu.RUnlock()
	return len(idx.nodes)
}
