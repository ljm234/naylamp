package naylamp

import (
	"fmt"

	"naylamp/engine/vector"
)

// Upsert adds or replaces a vector in the collection. It validates the
// dimensionality, writes the data to the store (ground truth), and inserts the
// id into the HNSW index (fast search). After this call the vector is findable
// by Query.
//
// The two writes run under the collection's write lock, so no concurrent
// operation can observe one of them without the other. Before that lock existed
// (DEFER-058), a Delete landing between them left the id in the index with the
// store already rid of it. The lock does not make the pair a transaction, and
// that limit is worth stating rather than implying: if index.Insert fails, the
// store keeps the vector and this call returns the error without undoing it.
// What the lock buys is atomicity against other operations, not against the
// second write failing.
//
// The dimension check stays OUTSIDE the lock on purpose: dim is fixed at
// construction and never written, so the check needs no lock, and a caller
// passing the wrong width would otherwise delay every reader and writer just to
// be told so. It is the shape vector.Store.Insert already uses for its own
// validation.
func (c *Collection) Upsert(id uint64, data []float32) error {
	if len(data) != c.dim {
		return fmt.Errorf("naylamp: vector has dim %d, collection requires %d", len(data), c.dim)
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	v := vector.Vector{ID: id, Data: data}
	if err := c.store.Insert(v); err != nil {
		return err
	}
	return c.index.Insert(id)
}

// Query returns the k nearest neighbors to the given vector, sorted
// nearest-first. It validates the query dimensionality and delegates the search
// to the HNSW index.
//
// The search runs under the collection's read lock, so queries proceed
// concurrently with each other and stay atomic against writers: a running
// Query delays any Upsert or Delete until it returns. The two argument checks
// are outside the lock for the reason given in the comment on Upsert. The price
// of that atomicity is declared in doc.go.
func (c *Collection) Query(data []float32, k int) ([]vector.Neighbor, error) {
	if len(data) != c.dim {
		return nil, fmt.Errorf("naylamp: query has dim %d, collection requires %d", len(data), c.dim)
	}
	if k <= 0 {
		return nil, fmt.Errorf("naylamp: k must be positive, got %d", k)
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.index.Search(data, k), nil
}

// Delete removes a vector from the collection: it is dropped from both the
// store (ground-truth data) and the HNSW index (graph structure). Removing it
// from the index is essential, otherwise the graph would keep a "ghost" node
// pointing at data that no longer exists. Returns vector.ErrNotFound if the id
// is unknown to the store.
//
// Like Upsert, the writes run under the collection's write lock; here that is
// the whole body, because there is no argument check to keep outside it.
func (c *Collection) Delete(id uint64) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.store.Delete(id); err != nil {
		return err
	}
	c.index.Delete(id)
	return nil
}
