package hnsw

import (
	"math/rand/v2"
	"testing"

	"naylamp/engine/vector"
)

// buildStoreAndIndex creates a store and an HNSW index wired together, both
// using cosine distance, and inserts the given vectors into both.
func buildStoreAndIndex(t *testing.T, vecs []vector.Vector, seed uint64) (*vector.Store, *Index) {
	t.Helper()
	store := vector.NewStore()
	idx := NewIndex(DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, seed)

	for _, v := range vecs {
		if err := store.Insert(v); err != nil {
			t.Fatalf("store insert: %v", err)
		}
		if err := idx.Insert(v.ID); err != nil {
			t.Fatalf("index insert: %v", err)
		}
	}
	return store, idx
}

// TestHNSW_FindsObviousNeighbor: a query identical to one stored vector should
// return that vector as the closest.
func TestHNSW_FindsObviousNeighbor(t *testing.T) {
	vecs := []vector.Vector{
		{ID: 1, Data: []float32{1, 0, 0}},
		{ID: 2, Data: []float32{0, 1, 0}},
		{ID: 3, Data: []float32{0, 0, 1}},
	}
	_, idx := buildStoreAndIndex(t, vecs, 42)

	got := idx.Search([]float32{1, 0, 0}, 1)
	if len(got) != 1 {
		t.Fatalf("got %d results, want 1", len(got))
	}
	if got[0].ID != 1 {
		t.Errorf("closest = id %d, want id 1", got[0].ID)
	}
}

// TestHNSW_RecallVsBruteForce: the heart of the test. Insert many random
// vectors, then for several queries compare HNSW's top-10 against the exact
// brute-force top-10. We measure recall: the fraction of true neighbors HNSW
// finds. HNSW is approximate, so we expect high (but not necessarily perfect)
// recall.
func TestHNSW_RecallVsBruteForce(t *testing.T) {
	const (
		n      = 500
		dim    = 32
		k      = 10
		nQuery = 20
	)
	rng := rand.New(rand.NewPCG(1, 2)) //nolint:gosec // deterministic RNG for test data

	// Generate random vectors.
	vecs := make([]vector.Vector, n)
	for i := range vecs {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		vecs[i] = vector.Vector{ID: uint64(i + 1), Data: data}
	}

	store, idx := buildStoreAndIndex(t, vecs, 7)

	var totalHits int
	for q := 0; q < nQuery; q++ {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.NormFloat64())
		}

		// Ground truth: exact top-k from the brute-force store.
		truth := store.Search(query, k, vector.CosineDistance)
		truthSet := make(map[uint64]bool)
		for _, tn := range truth {
			truthSet[tn.ID] = true
		}

		// HNSW's answer.
		got := idx.Search(query, k)
		for _, gn := range got {
			if truthSet[gn.ID] {
				totalHits++
			}
		}
	}

	recall := float64(totalHits) / float64(nQuery*k)
	t.Logf("recall@%d over %d queries = %.3f", k, nQuery, recall)

	// 0.95 is the recall@10-versus-brute-force floor Phase 1 claims as its
	// central property, and until 449d98c no test in the tree
	// enforced it: this assertion read 0.90 while the two scale tests read 0.85
	// and 0.80, so the claim rested on figures in a document rather than on a
	// gate. Measured on this seed at the time the floor was raised, this case
	// returns 1.000, so the margin is the whole of the approximation error the
	// index is allowed to have here. The floor is deliberately the claimed
	// number and not the measured one: a threshold pinned to today's output
	// turns any change at all into a failure, while this one falsifies exactly
	// what the phase promised.
	if recall < 0.95 {
		t.Errorf("recall = %.3f, want >= 0.95", recall)
	}
}
