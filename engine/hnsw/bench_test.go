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
//
// This case is NOT -short skipped, on purpose: it is the only recall floor
// above toy size that CI executes. Measured under the race detector, which is
// what CI runs, it costs 20.6s against a CI run of roughly six minutes.
//
// It is worth that because the other CI-live floor is nearly blind. At n=500,
// in hnsw_test.go, the 0.95 floor holds until efSearch drops under about 20, a
// fifteenfold collapse from the default of 300: ef=18 measures 0.945 and fails,
// ef=20 measures 0.950 and passes. At n=5000 the same floor trips at ef=30 with
// 0.878, which the previous 0.85 threshold accepted.
func TestHNSW_RecallAtScale(t *testing.T) {
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
	// number Phase 1 claims. This assertion read 0.85 until 449d98c.
	// Measured at that point: 1.000 on this seed at n=5000.
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

	// The only 50k recall instrument in the tree. It measures 0.994, and the
	// assertion below read 0.80 until 449d98c, so the tree tolerated losing
	// nineteen points of recall without turning red.
	//
	// What this comment does NOT claim: that 0.994 and the "99.4% a 50k" in
	// NAYLAMP_PHASE_1.md are the same measurement. The sibling figure on that
	// same doc line, 98.9% at 5k, does not reproduce here, since the n=5000 case
	// above measures 1.000 under today's defaults.
	//
	// Nor does it explain the 0.044 margin by size alone. At a fixed efSearch of
	// 300 the corpus matters as much as n: gaussian dim=64 gives 0.994 here and
	// 0.790 at n=1.5M (DEFER-008), while real SIFT1M holds 0.9990 at n=1,000,000
	// (sift_result_2026-07-11.txt). Both axes move it, and this suite measures
	// the synthetic-gaussian arm only. 50k is the largest regime this suite
	// asserts on, not the largest Phase 1 sealed.
	//
	// This one STAYS behind the -short skip, and the number is why: 849.9s under
	// the race detector, against a CI run of roughly six minutes. The n=5000
	// case carries the per-push duty at 20.6s instead.
	//
	// Nothing schedules this one, so today it runs only when someone remembers
	// to, and the assertion below guards nothing on a push. The fix is a
	// scheduled workflow off the push path, running this test by anchored name:
	//
	//	go test ./hnsw/ -run '^TestHNSW_RecallLargeScale$' -race -timeout 30m
	//
	// Not `make test-scale`. That target is -run 'Scale' unanchored against a
	// 60m timeout, which also matches TestHNSW_ScaleRecallSweep, TestHNSW_BuildScale
	// and TestHNSW_SIFTScale; two of those are multi-hour runs, so the target
	// cannot finish inside its own timeout and is the wrong vehicle for a timer.
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
