// Package naylamp is the public API of the Naylamp vector database engine.
// It ties together the vector store and the HNSW index into collections:
// named, self-contained groups of vectors you can insert into and query.
package naylamp

import (
	"errors"
	"fmt"
	"sync"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// Collection is a named group of vectors with its own store and index, using a
// single distance metric. Think of it as a labeled box: vectors of one kind
// (say, medical documents) live in one collection, separate from another kind
// (say, images) in a different collection. Inserting into a Collection writes
// to both the store (ground-truth data) and the HNSW index (fast search).
type Collection struct {
	name   string
	dim    int
	store  *vector.Store
	index  *hnsw.Index
	metric vector.MetricFunc
}

// Name returns the collection's name.
func (c *Collection) Name() string {
	return c.name
}

// Dim returns the dimensionality every vector in this collection must have.
func (c *Collection) Dim() int {
	return c.dim
}

// Len returns how many vectors the collection currently holds.
func (c *Collection) Len() int {
	return c.store.Len()
}

// Engine is the top-level handle that owns all collections. Think of it as the
// warehouse that holds the labeled boxes: you create collections through it and
// look them up by name. It is safe for concurrent use.
type Engine struct {
	mu          sync.RWMutex
	collections map[string]*Collection
}

// New creates an empty engine with no collections.
func New() *Engine {
	return &Engine{
		collections: make(map[string]*Collection),
	}
}

// Engine-level errors.
var (
	// ErrCollectionExists is returned when creating a collection whose name is
	// already taken.
	ErrCollectionExists = errors.New("naylamp: collection already exists")
	// ErrCollectionNotFound is returned when looking up a collection that does
	// not exist.
	ErrCollectionNotFound = errors.New("naylamp: collection not found")
)

// CreateCollection builds a new collection: it wires a fresh store to a fresh
// HNSW index that reads vector data from that store, then registers it under
// the given name. dim is the required dimensionality; metric is how similarity
// is measured; seed makes index construction reproducible.
func (e *Engine) CreateCollection(name string, dim int, metric vector.MetricFunc, seed uint64) (*Collection, error) {
	if dim <= 0 {
		return nil, fmt.Errorf("naylamp: dim must be positive, got %d", dim)
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	if _, exists := e.collections[name]; exists {
		return nil, ErrCollectionExists
	}

	store := vector.NewStore()
	// The index reads vector components from the store via this closure. This
	// is the bridge that lets HNSW measure distances without owning the data.
	index := hnsw.NewIndex(hnsw.DefaultParams(), metric, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, seed)

	c := &Collection{
		name:   name,
		dim:    dim,
		store:  store,
		index:  index,
		metric: metric,
	}
	e.collections[name] = c
	return c, nil
}

// Collection returns the collection with the given name, or ErrCollectionNotFound.
func (e *Engine) Collection(name string) (*Collection, error) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	c, ok := e.collections[name]
	if !ok {
		return nil, ErrCollectionNotFound
	}
	return c, nil
}
