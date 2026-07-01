package hnsw

import (
	"fmt"
	"os"
	"runtime"
	"testing"
	"time"

	"naylamp/engine/vector"
)

// TestHNSW_BuildScale builds a large index and records build time, memory,
// query latency, and an estimated recall. Progress is written to a result file
// every 50k inserts, so an unattended (overnight) run leaves readable partial
// results even if it is interrupted or runs out of memory. Exact recall is
// infeasible at this size, so recall is estimated against a sampled subset and
// labeled as an estimate.
//
// Run explicitly, e.g.:
//
//	go test -v -run BuildScale ./hnsw/... -timeout 720m
func TestHNSW_BuildScale(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping build-scale test in -short mode")
	}

	const (
		n   = 1500000 // dataset size for this run
		dim = 64
		k   = 10
	)

	const resultFile = "scale_result.txt"

	// writeResults dumps the accumulated lines to the result file. Called
	// periodically so partial progress survives an interruption.
	var lines []string
	writeResults := func() {
		content := fmt.Sprintf("Naylamp scale run (n=%d, dim=%d)\n===============================\n%s",
			n, dim, joinScaleLines(lines))
		_ = os.WriteFile(resultFile, []byte(content), 0o600)
	}
	record := func(format string, args ...any) {
		line := fmt.Sprintf(format, args...)
		t.Log(line)
		lines = append(lines, line)
		writeResults() // persist after every recorded line
	}

	record("building index with n=%d, dim=%d ...", n, dim)

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
			record("  inserted %d / %d (%.1fs elapsed)", i+1, n, time.Since(start).Seconds())
		}
	}
	buildDur := time.Since(start)

	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)
	memUsedMB := float64(memAfter.Alloc-memBefore.Alloc) / (1024 * 1024)

	record("build complete: n=%d in %.1fs (%.0f vectors/sec)",
		n, buildDur.Seconds(), float64(n)/buildDur.Seconds())
	record("approx memory in use: %.1f MB", memUsedMB)

	// Query latency over a set of random queries; keep the queries for recall.
	const nQ = 100
	queries := make([][]float32, nQ)
	qStart := time.Now()
	for q := 0; q < nQ; q++ {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.normFloat64())
		}
		queries[q] = query
		got := idx.Search(query, k)
		if len(got) == 0 {
			t.Fatalf("query returned no results at scale")
		}
	}
	qDur := time.Since(qStart)
	record("query latency: %.0f microseconds/query (avg over %d queries)",
		float64(qDur.Microseconds())/float64(nQ), nQ)

	// Estimated recall@k against a sampled ground truth. For each query we scan
	// a uniform sample of ids and take the k closest among them, then measure
	// overlap with the index result. This is an ESTIMATE, biased slightly high.
	const recallQueries = 50
	const sampleStride = 15 // scan every 15th id as sampled ground truth
	var hitSum float64
	for q := 0; q < recallQueries; q++ {
		query := queries[q%nQ]

		var sampled []vector.Neighbor
		for id := uint64(1); id <= uint64(n); id += sampleStride {
			v, err := store.Get(id)
			if err != nil {
				continue
			}
			d := vector.CosineDistance(query, v.Data)
			sampled = append(sampled, vector.Neighbor{ID: id, Distance: d})
		}
		// Select the k smallest by a simple partial selection.
		truthSet := make(map[uint64]bool, k)
		for i := 0; i < k && i < len(sampled); i++ {
			minIdx := i
			for j := i + 1; j < len(sampled); j++ {
				if sampled[j].Distance < sampled[minIdx].Distance {
					minIdx = j
				}
			}
			sampled[i], sampled[minIdx] = sampled[minIdx], sampled[i]
			truthSet[sampled[i].ID] = true
		}

		got := idx.Search(query, k)
		hits := 0
		for _, g := range got {
			if truthSet[g.ID] {
				hits++
			}
		}
		hitSum += float64(hits) / float64(k)
	}
	estRecall := hitSum / float64(recallQueries)
	record("ESTIMATED recall@%d (sampled ground truth, biased high) = %.3f", k, estRecall)
	record("DONE.")
}

// joinScaleLines joins result lines with newlines for the result file.
func joinScaleLines(lines []string) string {
	s := ""
	for _, l := range lines {
		s += l + "\n"
	}
	return s
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
