package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// TestIndex_RoundTripSearchMatches is the integration test for Subphase 2.1: it
// builds a real HNSW index, serializes it whole, restores it, and verifies the
// restored index answers searches identically to the original. This proves the
// graph survives a full encode/decode cycle with no behavioral change, which is
// the foundation snapshots and recovery depend on.
func TestIndex_RoundTripSearchMatches(t *testing.T) {
	const (
		n   = 2000
		dim = 64
		k   = 10
	)

	// Build a store and index over deterministic random vectors.
	store := vector.NewStore()
	idx := hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)

	rng := rand.New(rand.NewPCG(1, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	for i := 0; i < n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		v := vector.Vector{ID: uint64(i + 1), Data: data}
		if err := store.Insert(v); err != nil {
			t.Fatalf("store insert: %v", err)
		}
		if err := idx.Insert(v.ID); err != nil {
			t.Fatalf("index insert: %v", err)
		}
	}

	// Run a set of queries on the original index and record the results.
	queries := make([][]float32, 20)
	originalResults := make([][]vector.Neighbor, len(queries))
	for q := range queries {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.NormFloat64())
		}
		queries[q] = query
		originalResults[q] = idx.Search(query, k)
	}

	// Serialize the whole index to bytes and back.
	snap := idx.Export()
	encoded, err := EncodeIndexToBytes(snap)
	if err != nil {
		t.Fatalf("encode index: %v", err)
	}
	decodedSnap, err := DecodeIndexFromBytes(encoded)
	if err != nil {
		t.Fatalf("decode index: %v", err)
	}

	// Rebuild the store-backed closure for the restored index. The restored
	// index must read the same vector data, so we reuse the same store.
	restored := hnsw.RestoreIndex(decodedSnap, vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	})

	// The restored index must report the same size.
	if restored.Len() != idx.Len() {
		t.Fatalf("len mismatch: restored %d, original %d", restored.Len(), idx.Len())
	}

	// The restored index must answer every query identically (same ids, order).
	for q := range queries {
		got := restored.Search(queries[q], k)
		want := originalResults[q]
		if len(got) != len(want) {
			t.Fatalf("query %d: result len mismatch: got %d want %d", q, len(got), len(want))
		}
		for i := range want {
			if got[i].ID != want[i].ID {
				t.Fatalf("query %d pos %d: id mismatch: got %d want %d", q, i, got[i].ID, want[i].ID)
			}
		}
	}
}

// TestIndex_EmptyRoundTrip checks that an empty index round-trips cleanly (no
// nodes, no entry point).
func TestIndex_EmptyRoundTrip(t *testing.T) {
	idx := hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, func(_ uint64) ([]float32, bool) {
		return nil, false
	}, 1)

	snap := idx.Export()
	encoded, err := EncodeIndexToBytes(snap)
	if err != nil {
		t.Fatalf("encode empty index: %v", err)
	}
	decoded, err := DecodeIndexFromBytes(encoded)
	if err != nil {
		t.Fatalf("decode empty index: %v", err)
	}
	if len(decoded.Nodes) != 0 {
		t.Fatalf("expected 0 nodes, got %d", len(decoded.Nodes))
	}
	if decoded.HasEntry {
		t.Fatalf("expected HasEntry=false for empty index")
	}
}
