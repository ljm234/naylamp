package naylamp

import (
	"fmt"

	"naylamp/engine/vector"
)

// Upsert adds or replaces a vector in the collection. It validates the
// dimensionality, writes the data to the store (ground truth), and inserts the
// id into the HNSW index (fast search). After this call the vector is findable
// by Query.
func (c *Collection) Upsert(id uint64, data []float32) error {
	if len(data) != c.dim {
		return fmt.Errorf("naylamp: vector has dim %d, collection requires %d", len(data), c.dim)
	}

	v := vector.Vector{ID: id, Data: data}
	if err := c.store.Insert(v); err != nil {
		return err
	}
	return c.index.Insert(id)
}

// Query returns the k nearest neighbors to the given vector, sorted
// nearest-first. It validates the query dimensionality and delegates the search
// to the HNSW index.
func (c *Collection) Query(data []float32, k int) ([]vector.Neighbor, error) {
	if len(data) != c.dim {
		return nil, fmt.Errorf("naylamp: query has dim %d, collection requires %d", len(data), c.dim)
	}
	if k <= 0 {
		return nil, fmt.Errorf("naylamp: k must be positive, got %d", k)
	}
	return c.index.Search(data, k), nil
}

// Delete removes a vector from the collection: it is dropped from both the
// store (ground-truth data) and the HNSW index (graph structure). Removing it
// from the index is essential, otherwise the graph would keep a "ghost" node
// pointing at data that no longer exists. Returns vector.ErrNotFound if the id
// is unknown to the store.
func (c *Collection) Delete(id uint64) error {
	if err := c.store.Delete(id); err != nil {
		return err
	}
	c.index.Delete(id)
	return nil
}
