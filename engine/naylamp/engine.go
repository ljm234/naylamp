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
//
// The mutex makes every operation that touches state atomic against the others:
// Upsert and Delete take it for writing, Query, Len and IndexIDs for reading, so
// no caller can observe the half-written state of another call. Outside it, on
// purpose, are Name and Dim and each operation's own argument checking, which
// read nothing but fields fixed at construction. That is what the
// package's "safe for concurrent use" promise rests on, and it is the fix for
// DEFER-058: before it, a Delete landing between the two writes of an Upsert
// left the id in the index and out of the store, with the race detector silent
// because each object was locked on its own. The price, declared in doc.go: a
// running query holds the read lock and delays any writer.
type Collection struct {
	name   string
	dim    int
	store  *vector.Store
	index  *hnsw.Index
	metric vector.MetricFunc
	mu     sync.RWMutex
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
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.store.Len()
}

// IndexIDs returns the ids the HNSW index currently holds, in ascending order.
// It is a read-only audit accessor built on Index.Export(), the same read-locked
// call Node.StateHash makes, and no write path reaches it. The slice is fresh on
// every call, so a caller that sorts it in place cannot reach the graph.
//
// IT READS THE INDEX, AND Len ABOVE READS THE STORE, and the whole reason this
// method exists is that difference. On a healthy collection driven from one
// goroutine the two objects hold the same ids always, so no sequence of Upsert,
// Query and Delete can tell them apart; a check that read the store while
// claiming to speak about the index would therefore pass every seed of the
// simulation and still be pointed at the wrong object. That is the defect this
// accessor was opened to let a checker avoid, so the difference is pinned by a
// defender of its own, TestCollection_IndexIDsReadsTheIndexNotTheStore, which
// says how.
//
// Two limits go here rather than in a note, because both bite a caller that
// assumes otherwise. Reading this together with Len does NOT give an atomic
// pair: each of the two calls takes the collection's read lock on its own, so
// an Upsert or Delete landing BETWEEN the two calls leaves the two answers
// disagreeing. That is a statement about pairs of calls, not about one
// operation: since the fix of DEFER-058 every operation is atomic, and no single
// call can be caught half-written the way an Upsert once could be when a Delete
// landed between its two writes. And the call grows close to quadratically over
// the sizes that matter, because Export sorts with an insertion sort: ten
// times the nodes cost eighty-one times the time,
// 3.82 ms at n=5000 against 311 ms at n=50000, and the endpoints do not show
// this: at a hundred nodes the copy dominates and not the sort.
//
// Every document named here lives OUTSIDE this repository, in the workspace
// directory above it, so a clone carries none of them. What this accessor
// serves is clause (i) of the central property of Phase 1, stated in
// NAYLAMP_PHASE_1.md, which says the index's live set is exactly the set of ids
// upserted and not deleted, in both directions. The item that ordered the
// accessor is DEFER-049, the quadratic cost above is DEFER-063, and the
// atomicity defect the pair note refers to was DEFER-058, fixed by the
// collection lock, all three in NAYLAMP_DEFERRED_BACKLOG.md.
func (c *Collection) IndexIDs() []uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	snap := c.index.Export()
	ids := make([]uint64, 0, len(snap.Nodes))
	for _, n := range snap.Nodes {
		ids = append(ids, n.ID)
	}
	return ids
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
