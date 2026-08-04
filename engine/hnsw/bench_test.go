package hnsw

import (
	"math/rand/v2"
	"testing"

	"naylamp/engine/vector"
)

// makeRandomVectors builds n deterministic random vectors of the given
// dimension, for use in benchmarks and scale tests.
func makeRandomVectors(n, dim int, seed uint64) []vector.Vector {
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for test data
	vecs := make([]vector.Vector, n)
	for i := range vecs {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		vecs[i] = vector.Vector{ID: uint64(i + 1), Data: data}
	}
	return vecs
}

// buildIndex inserts the given vectors into a fresh HNSW index backed by a
// store, and returns both. Used by scale and latency benchmarks.
func buildIndex(tb testing.TB, vecs []vector.Vector, seed uint64) (*vector.Store, *Index) {
	tb.Helper()
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
			tb.Fatalf("store insert: %v", err)
		}
		if err := idx.Insert(v.ID); err != nil {
			tb.Fatalf("index insert: %v", err)
		}
	}
	return store, idx
}

// measureRecall runs nQuery random queries against both the index and the
// brute-force store, and returns recall@k: the fraction of true neighbors the
// index found.
func measureRecall(t *testing.T, store *vector.Store, idx *Index, dim, k, nQuery int, querySeed uint64) float64 {
	t.Helper()
	qRng := rand.New(rand.NewPCG(querySeed, 0)) //nolint:gosec // deterministic RNG for test data
	var totalHits int
	for q := 0; q < nQuery; q++ {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(qRng.NormFloat64())
		}
		truth := store.Search(query, k, vector.CosineDistance)
		truthSet := make(map[uint64]bool, k)
		for _, tn := range truth {
			truthSet[tn.ID] = true
		}
		got := idx.Search(query, k)
		for _, gn := range got {
			if truthSet[gn.ID] {
				totalHits++
			}
		}
	}
	return float64(totalHits) / float64(nQuery*k)
}

// TestHNSW_RecallAtScale measures recall@10 on a larger dataset (5000 vectors)
// than the basic correctness test. HNSW is approximate, so recall at this scale
// is expected to be high but may dip below 100%. This documents the real
// quality of the index, not just that it works on toy inputs.
func TestHNSW_RecallAtScale(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scale test in -short mode")
	}
	const (
		n      = 5000
		dim    = 64
		k      = 10
		nQuery = 100
	)
	vecs := makeRandomVectors(n, dim, 1)
	store, idx := buildIndex(t, vecs, 2)

	recall := measureRecall(t, store, idx, dim, k, nQuery, 99)
	t.Logf("recall@%d at scale (n=%d, dim=%d, %d queries) = %.3f", k, n, dim, nQuery, recall)

	// Same 0.95 floor as the basic case, and for the same reason: it is the
	// number Phase 1 claims. This assertion read 0.85 until 3 de agosto de 2026.
	// Measured at that point: 1.000 on this seed at n=5000.
	//
	// THIS FLOOR DOES NOT RUN IN CI, and the caveat belongs next to the number
	// rather than in a report nobody reads. The -short skip at the top of this
	// function is taken by `go test -short -race ./...`, which is what the CI
	// workflow runs and what `make test` runs, so this assertion fires only
	// under `make test-scale` or an explicit -run. The one recall floor that CI
	// does execute is the n=500 case in hnsw_test.go, which has no -short skip.
	if recall < 0.95 {
		t.Errorf("recall at scale = %.3f, want >= 0.95", recall)
	}
}

// TestHNSW_RecallLargeScale measures recall on a much larger dataset (50000
// vectors). It is skipped in -short mode and is meant to be run explicitly to
// observe how recall and build time behave at a larger size. Brute-force ground
// truth makes this O(n) per query, so it is intentionally heavy.
func TestHNSW_RecallLargeScale(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping large-scale test in -short mode")
	}
	const (
		n      = 50000
		dim    = 64
		k      = 10
		nQuery = 50
	)
	vecs := makeRandomVectors(n, dim, 1)
	store, idx := buildIndex(t, vecs, 2)

	recall := measureRecall(t, store, idx, dim, k, nQuery, 99)
	t.Logf("recall@%d at LARGE scale (n=%d, dim=%d, %d queries) = %.3f", k, n, dim, nQuery, recall)

	// This is the only 50k recall instrument in the tree, and it measures 0.994,
	// the same figure NAYLAMP_PHASE_1.md records as "recall 99.4% a 50k" when it
	// cites evidence for its 0.95 claim. The assertion nonetheless read 0.80
	// until 3 de agosto de 2026, so the tree tolerated losing nineteen points of
	// recall without turning red while the document went on claiming 0.95.
	//
	// Two things this comment deliberately does NOT say. It does not claim the
	// two numbers are the same measurement: the sibling figure on that same doc
	// line, 98.9% at 5k, does not reproduce here, since the n=5000 case above
	// measures 1.000 under today's defaults. And it does not explain the 0.044
	// margin by saying recall falls as the graph grows, which the project's own
	// evidence contradicts: efSearch=300 gives 0.9990 at n=1,000,000 on real
	// SIFT1M (sift_result_2026-07-11.txt) and 0.790 at n=1.5M on synthetic
	// gaussian (DEFER-008). Both cannot be a size effect. What moves recall at a
	// fixed efSearch is the data distribution, and this suite measures the
	// synthetic-gaussian arm only. 50k is the largest regime this suite asserts
	// on, not the largest Phase 1 sealed.
	//
	// Like the case above, this floor is behind the -short skip and so does not
	// run in CI.
	if recall < 0.95 {
		t.Errorf("recall at large scale = %.3f, want >= 0.95", recall)
	}
}

// BenchmarkHNSWSearch measures the latency of a single HNSW query on a
// moderately large index. Go runs the loop many times and reports ns/op.
func BenchmarkHNSWSearch(b *testing.B) {
	const (
		n   = 5000
		dim = 64
		k   = 10
	)
	vecs := makeRandomVectors(n, dim, 1)
	_, idx := buildIndex(b, vecs, 2)

	qRng := rand.New(rand.NewPCG(99, 0)) //nolint:gosec // deterministic RNG for test data
	query := make([]float32, dim)
	for j := range query {
		query[j] = float32(qRng.NormFloat64())
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = idx.Search(query, k)
	}
}

// BenchmarkBruteForceSearch measures the latency of a single exact brute-force
// query on the same dataset, for comparison. The ratio between this and
// BenchmarkHNSWSearch is the speedup HNSW provides.
func BenchmarkBruteForceSearch(b *testing.B) {
	const (
		n   = 5000
		dim = 64
		k   = 10
	)
	vecs := makeRandomVectors(n, dim, 1)
	store, _ := buildIndex(b, vecs, 2)

	qRng := rand.New(rand.NewPCG(99, 0)) //nolint:gosec // deterministic RNG for test data
	query := make([]float32, dim)
	for j := range query {
		query[j] = float32(qRng.NormFloat64())
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = store.Search(query, k, vector.CosineDistance)
	}
}
