package hnsw

import (
	"runtime"
	"testing"
	"time"

	"naylamp/engine/vector"
)

// TestHNSW_BuildScale measures how the index behaves as the dataset grows large:
// build time, memory use, and query latency. It does NOT compute exact recall
// (brute-force ground truth is infeasible at this size); it only confirms the
// index builds and answers queries. Set the size via the constant below.
//
// Run explicitly, e.g.:
//
//	go test -v -run BuildScale ./hnsw/... -timeout 60m
func TestHNSW_BuildScale(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping build-scale test in -short mode")
	}

	const (
		n   = 500000 // change this to scale up: 500k, 1M, 5M
		dim = 64
		k   = 10
	)

	t.Logf("building index with n=%d, dim=%d ...", n, dim)

	store := vector.NewStore()
	idx := NewIndex(DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)

	rng := newScaleRNG(1)

	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	start := time.Now()
	for i := 0; i < n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.normFloat64())
		}
		id := uint64(i + 1)
		if err := store.Insert(vector.Vector{ID: id, Data: data}); err != nil {
			t.Fatalf("store insert at %d: %v", i, err)
		}
		if err := idx.Insert(id); err != nil {
			t.Fatalf("index insert at %d: %v", i, err)
		}

		if (i+1)%50000 == 0 {
			t.Logf("  inserted %d / %d (%.1fs elapsed)", i+1, n, time.Since(start).Seconds())
		}
	}
	buildDur := time.Since(start)

	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)
	memUsedMB := float64(memAfter.Alloc-memBefore.Alloc) / (1024 * 1024)

	t.Logf("build complete: n=%d in %.1fs (%.0f vectors/sec)",
		n, buildDur.Seconds(), float64(n)/buildDur.Seconds())
	t.Logf("approx memory in use: %.1f MB", memUsedMB)

	// Run a few queries to confirm the index answers at this scale.
	query := make([]float32, dim)
	for j := range query {
		query[j] = float32(rng.normFloat64())
	}
	qStart := time.Now()
	const nQ = 100
	for q := 0; q < nQ; q++ {
		got := idx.Search(query, k)
		if len(got) == 0 {
			t.Fatalf("query returned no results at scale")
		}
	}
	qDur := time.Since(qStart)
	t.Logf("query latency: %.0f microseconds/query (avg over %d queries)",
		float64(qDur.Microseconds())/float64(nQ), nQ)
}

// newScaleRNG returns a small deterministic Gaussian generator without pulling
// in the test data helpers, to keep this scale test self-contained.
func newScaleRNG(seed uint64) *scaleRNG {
	return &scaleRNG{state: seed | 1}
}

type scaleRNG struct {
	state uint64
}

// normFloat64 returns an approximately standard-normal value using a fast
// deterministic generator (sum of uniforms, central limit). Good enough for
// generating spread-out vectors; not for statistical work.
func (r *scaleRNG) normFloat64() float64 {
	var sum float64
	for i := 0; i < 6; i++ {
		r.state = r.state*6364136223846793005 + 1442695040888963407
		u := float64(r.state>>11) / float64(1<<53)
		sum += u
	}
	return (sum - 3.0) * 1.4142135623730951
}
