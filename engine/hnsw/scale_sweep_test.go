package hnsw

import (
	"fmt"
	"os"
	"runtime"
	"testing"
	"time"

	"naylamp/engine/vector"
)

// TestHNSW_ScaleRecallSweep builds one large index and measures recall@10 and
// query latency at several efSearch values against a single exact ground
// truth. Recall at one efSearch is a single point on a curve; the operating
// point should come from the measured trade-off, not from an assumption. The
// dataset, seed and query generation match TestHNSW_BuildScale, so the
// efSearch=300 row must reproduce that run's recall exactly, which doubles as
// a determinism check of the sweep itself.
//
// Run explicitly, e.g.:
//
//	go test -v -run ScaleRecallSweep ./hnsw/ -timeout 720m
func TestHNSW_ScaleRecallSweep(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping scale sweep in -short mode")
	}

	const (
		n   = 1500000
		dim = 64
		k   = 10
		nQ  = 50
	)
	efValues := []int{100, 300, 600, 1200, 2400}

	const resultFile = "scale_sweep_result.txt"
	var lines []string
	writeResults := func() {
		content := fmt.Sprintf("Naylamp efSearch sweep (n=%d, dim=%d, k=%d, queries=%d)\n===============================\n%s",
			n, dim, k, nQ, joinScaleLines(lines))
		_ = os.WriteFile(resultFile, []byte(content), 0o600)
	}
	record := func(format string, args ...any) {
		line := fmt.Sprintf(format, args...)
		t.Log(line)
		lines = append(lines, line)
		writeResults()
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
	record("build complete: n=%d in %.1fs", n, time.Since(start).Seconds())

	runtime.GC()
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	record("live heap after forced GC: %.1f MB", float64(mem.HeapAlloc)/(1024*1024))

	// Queries and their exact ground truth, computed once and reused across
	// every efSearch value.
	queries := make([][]float32, nQ)
	truthSets := make([]map[uint64]bool, nQ)
	for q := 0; q < nQ; q++ {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.normFloat64())
		}
		queries[q] = query

		truth := make([]vector.Neighbor, 0, k)
		for id := uint64(1); id <= uint64(n); id++ {
			v, err := store.Get(id)
			if err != nil {
				continue
			}
			d := vector.CosineDistance(query, v.Data)
			if len(truth) < k {
				truth = append(truth, vector.Neighbor{ID: id, Distance: d})
				if len(truth) == k {
					sortNeighbors(truth)
				}
				continue
			}
			if d >= truth[k-1].Distance {
				continue
			}
			pos := k - 1
			for pos > 0 && truth[pos-1].Distance > d {
				truth[pos] = truth[pos-1]
				pos--
			}
			truth[pos] = vector.Neighbor{ID: id, Distance: d}
		}
		set := make(map[uint64]bool, k)
		for _, tn := range truth {
			set[tn.ID] = true
		}
		truthSets[q] = set
	}
	record("exact ground truth ready for %d queries", nQ)

	for _, ef := range efValues {
		idx.params.EfSearch = ef // Search reads params.EfSearch on every call, so this re-tunes the next queries.

		var hitSum float64
		qStart := time.Now()
		for q := 0; q < nQ; q++ {
			got := idx.Search(queries[q], k)
			hits := 0
			for _, g := range got {
				if truthSets[q][g.ID] {
					hits++
				}
			}
			hitSum += float64(hits) / float64(k)
		}
		elapsed := time.Since(qStart)
		record("efSearch=%d: recall@%d = %.3f, latency = %.0f microseconds/query",
			ef, k, hitSum/float64(nQ), float64(elapsed.Microseconds())/float64(nQ))
	}
	record("DONE.")
}
