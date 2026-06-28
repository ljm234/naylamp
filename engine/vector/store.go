package vector

import (
	"errors"
	"sort"
	"sync"
)

// ErrNotFound is returned when a lookup or delete targets an id the store
// does not contain.
var ErrNotFound = errors.New("vector: id not found")

// Store is an in-memory, concurrency-safe collection of vectors keyed by ID.
// It is the substrate the HNSW index will build its graph over. An RWMutex
// guards the map so many reads can proceed in parallel while writes are
// exclusive.
type Store struct {
	mu      sync.RWMutex
	vectors map[uint64]Vector
}

// NewStore returns an empty, ready-to-use store.
func NewStore() *Store {
	return &Store{
		vectors: make(map[uint64]Vector),
	}
}

// Len returns how many vectors the store currently holds.
func (s *Store) Len() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.vectors)
}

// Insert validates the vector and stores it, overwriting any existing vector
// with the same ID.
func (s *Store) Insert(v Vector) error {
	if err := v.Validate(); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.vectors[v.ID] = v
	return nil
}

// Get returns the vector with the given id, or ErrNotFound.
func (s *Store) Get(id uint64) (Vector, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.vectors[id]
	if !ok {
		return Vector{}, ErrNotFound
	}
	return v, nil
}

// Delete removes the vector with the given id, or returns ErrNotFound.
func (s *Store) Delete(id uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.vectors[id]; !ok {
		return ErrNotFound
	}
	delete(s.vectors, id)
	return nil
}

// Neighbor is one search result: the id of a stored vector and how far it is
// from the query. Smaller Distance means more similar.
type Neighbor struct {
	ID       uint64
	Distance float32
}

// MetricFunc is any of our distance functions (DotProduct, L2Distance,
// CosineDistance). Search takes one so the caller chooses how "similar" is
// measured.
type MetricFunc func(a, b []float32) float32

// Search compares the query against every stored vector using the given
// metric and returns the k closest, sorted nearest-first. This is the exact,
// brute-force answer: slow on huge datasets, but always correct, so it serves
// as the ground truth for checking the faster HNSW index later.
func (s *Store) Search(query []float32, k int, metric MetricFunc) []Neighbor {
	s.mu.RLock()
	defer s.mu.RUnlock()

	results := make([]Neighbor, 0, len(s.vectors))
	for id, v := range s.vectors {
		results = append(results, Neighbor{
			ID:       id,
			Distance: metric(query, v.Data),
		})
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].Distance < results[j].Distance
	})

	if k < len(results) {
		results = results[:k]
	}
	return results
}
