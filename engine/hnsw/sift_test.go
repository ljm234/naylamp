package hnsw

import (
	"encoding/binary"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"sync"
	"testing"
	"time"

	"naylamp/engine/vector"
)

// TestHNSW_SIFTScale runs Naylamp's HNSW index over the canonical SIFT1M
// benchmark from the INRIA TexMex corpus: 1,000,000 base vectors of dimension
// 128, 10,000 query vectors, and the exact 100 nearest neighbors per query by
// Euclidean distance. It measures recall@10 and query latency across a sweep of
// efSearch values, reporting single thread percentiles (p50, p95, p99) and both
// single and multi thread QPS, and writes an incremental result file so an
// overnight run leaves readable partial results if it is interrupted.
//
// SIFT is a Euclidean benchmark: its ground truth is computed with L2, so the
// index is built with vector.L2Distance rather than the cosine default. The
// distance is a constructor parameter, so this needs no production change; the
// cosine fast path is bypassed automatically because the metric is not cosine.
//
// The dataset is never committed. Point NAYLAMP_SIFT_DIR at the directory that
// holds sift_base.fvecs, sift_query.fvecs, and sift_groundtruth.ivecs, then run:
//
//	NAYLAMP_SIFT_DIR=/path/to/sift go test -run TestHNSW_SIFTScale ./engine/hnsw/ -timeout 720m -v
func TestHNSW_SIFTScale(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping SIFT1M scale benchmark in -short mode")
	}
	dir := os.Getenv("NAYLAMP_SIFT_DIR")
	if dir == "" {
		t.Skip("NAYLAMP_SIFT_DIR is not set; export it to the directory holding sift_base.fvecs, sift_query.fvecs, and sift_groundtruth.ivecs to run the SIFT1M benchmark")
	}
	basePath := filepath.Join(dir, "sift_base.fvecs")
	queryPath := filepath.Join(dir, "sift_query.fvecs")
	gtPath := filepath.Join(dir, "sift_groundtruth.ivecs")
	for _, p := range []string{basePath, queryPath, gtPath} {
		if _, err := os.Stat(p); err != nil { //nolint:gosec // paths come from NAYLAMP_SIFT_DIR, an operator provided directory, not untrusted input
			t.Skipf("SIFT dataset file missing: %s; NAYLAMP_SIFT_DIR must hold sift_base.fvecs, sift_query.fvecs, and sift_groundtruth.ivecs", p)
		}
	}

	const (
		dim        = 128
		gtWidth    = 100
		baseCount  = 1000000
		queryCount = 10000
		k          = 10
	)
	efValues := []int{100, 300, 600, 1200, 2400}
	params := DefaultParams()

	// The result file is rewritten from an accumulating slice after every recorded
	// line, so a run that dies midway leaves everything written so far on disk.
	const resultFile = "sift_result.txt"
	host, _ := os.Hostname()
	header := fmt.Sprintf(
		"Naylamp SIFT1M benchmark\n"+
			"===============================\n"+
			"dataset=SIFT1M (n=%d, dim=%d, queries=%d, k=%d), metric=L2 euclidean\n"+
			"M=%d, efConstruction=%d, GOMAXPROCS=%d, host=%s\n",
		baseCount, dim, queryCount, k, params.M, params.EfConstruction, runtime.GOMAXPROCS(0), host)
	var lines []string
	record := func(format string, args ...any) {
		line := fmt.Sprintf(format, args...)
		t.Log(line)
		lines = append(lines, line)
		_ = os.WriteFile(resultFile, []byte(header+joinScaleLines(lines)), 0o600)
	}

	// Load the dataset with strict parsing: a misaligned parse would fake recall,
	// so readFvecs and readIvecs fail loudly on any size or dimension mismatch.
	record("loading base vectors from %s", basePath)
	base := readFvecs(t, basePath, dim, baseCount)
	record("loading query vectors from %s", queryPath)
	queries := readFvecs(t, queryPath, dim, queryCount)
	record("loading ground truth from %s", gtPath)
	gt := readIvecs(t, gtPath, gtWidth, queryCount)

	// Each query's truth set: the first k ground truth ids, mapped to our 1-based
	// ids. The ground truth carries 100 neighbors per query; recall@10 uses the
	// first 10, which are the true top 10. Built up front so the pre-flight below
	// and the sweep later both read it.
	truthSets := make([]map[uint64]bool, queryCount)
	for q := 0; q < queryCount; q++ {
		set := make(map[uint64]bool, k)
		for i := 0; i < k; i++ {
			set[uint64(gt[q][i])+1] = true
		}
		truthSets[q] = set
	}

	// (a) Populate the store with all base vectors. This is fast; the index build
	// is the slow part. The index reads vectors from the store through a callback.
	store := vector.NewStore()
	record("populating store with %d vectors ...", baseCount)
	popStart := time.Now()
	for i := 0; i < baseCount; i++ {
		id := uint64(i + 1) // ids are 1-based, so a ground truth index g maps to id g+1
		if err := store.Insert(vector.Vector{ID: id, Data: base[i]}); err != nil {
			t.Fatalf("store insert at %d: %v", i, err)
		}
	}
	record("store populated: %d vectors in %.1fs", baseCount, time.Since(popStart).Seconds())

	// (b) Pre-flight: prove the pipeline reproduces SIFT's official ground truth
	// before spending hours on the index build. Exact brute force from the store
	// (the same L2 the index will use) over the first queries must match the
	// official top 10. SIFT vectors are integers in float32 and each L2 sum of
	// squares fits exactly in float32 (max around 8.3M, below 2^24), so an aligned
	// pipeline matches almost perfectly; 0.99 only tolerates genuine ties. A lower
	// overlap means the parser, the store, or our L2 disagrees with INRIA, and the
	// build must not be spent.
	const preflightQueries = 20
	var overlapSum float64
	for q := 0; q < preflightQueries; q++ {
		got := store.Search(queries[q], k, vector.L2Distance)
		hits := 0
		for _, g := range got {
			if truthSets[q][g.ID] {
				hits++
			}
		}
		overlapSum += float64(hits) / float64(k)
	}
	meanOverlap := overlapSum / float64(preflightQueries)
	record("pre-flight: brute force vs official ground truth over %d queries: mean overlap %.4f", preflightQueries, meanOverlap)
	if meanOverlap < 0.99 {
		t.Fatalf("pre-flight overlap %.4f is below 0.99: the fvecs/ivecs parser, the store, or our L2 metric does not reproduce SIFT's official ground truth, so the multi hour index build is not spent; an aligned pipeline should match almost exactly because SIFT L2 sums fit in float32", meanOverlap)
	}

	// (c) Build the HNSW index over all base vectors. This is the long phase, so
	// the timing below measures only it, not the store population or the pre-flight.
	idx := NewIndex(params, vector.L2Distance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)
	record("building index over %d vectors (L2) ...", baseCount)
	start := time.Now()
	for i := 0; i < baseCount; i++ {
		id := uint64(i + 1)
		if err := idx.Insert(id); err != nil {
			t.Fatalf("index insert at %d: %v", i, err)
		}
		if (i+1)%50000 == 0 {
			el := time.Since(start).Seconds()
			record("  inserted %d / %d (%.1fs, %.0f vec/s cumulative)", i+1, baseCount, el, float64(i+1)/el)
		}
	}
	buildDur := time.Since(start)
	record("build complete: %d vectors in %.1fs (%.0f vec/s)", baseCount, buildDur.Seconds(), float64(baseCount)/buildDur.Seconds())

	runtime.GC()
	var mem runtime.MemStats
	runtime.ReadMemStats(&mem)
	record("live heap after forced GC: %.1f MB", float64(mem.HeapAlloc)/(1024*1024))

	threads := runtime.NumCPU()
	record("sweep over efSearch %v; single thread percentiles plus %d thread QPS", efValues, threads)

	usOf := func(d time.Duration) float64 { return float64(d.Nanoseconds()) / 1000.0 }

	for _, ef := range efValues {
		// Search reads params.EfSearch on every call, so setting it here re-tunes
		// the next queries without rebuilding the index.
		idx.params.EfSearch = ef

		// Single thread pass: recall and per-query latency in one loop.
		durations := make([]time.Duration, queryCount)
		var hitSum float64
		for q := 0; q < queryCount; q++ {
			qStart := time.Now()
			got := idx.Search(queries[q], k)
			durations[q] = time.Since(qStart)
			hits := 0
			for _, g := range got {
				if truthSets[q][g.ID] {
					hits++
				}
			}
			hitSum += float64(hits) / float64(k)
		}
		recall := hitSum / float64(queryCount)

		sort.Slice(durations, func(a, b int) bool { return durations[a] < durations[b] })
		var total time.Duration
		for _, d := range durations {
			total += d
		}
		mean := total / time.Duration(queryCount)
		p50 := durations[pctIndex(queryCount, 0.50)]
		p95 := durations[pctIndex(queryCount, 0.95)]
		p99 := durations[pctIndex(queryCount, 0.99)]
		qps1t := 1.0 / mean.Seconds()

		// Multi thread pass: wall clock of all queries across a pool of one
		// goroutine per cpu, each striding its own shard of the query slice.
		// Search takes a read lock and the store read is read locked too, so the
		// queries run in parallel over the finished index. The first neighbor id
		// feeds a per shard checksum so the calls are not optimized away; recall
		// already came from the single thread pass.
		shardSums := make([]uint64, threads)
		var wg sync.WaitGroup
		mtStart := time.Now()
		for s := 0; s < threads; s++ {
			wg.Add(1)
			go func(shard int) {
				defer wg.Done()
				var sum uint64
				for q := shard; q < queryCount; q += threads {
					got := idx.Search(queries[q], k)
					if len(got) > 0 {
						sum += got[0].ID
					}
				}
				shardSums[shard] = sum
			}(s)
		}
		wg.Wait()
		mtWall := time.Since(mtStart)
		var checksum uint64
		for _, s := range shardSums {
			checksum += s
		}
		qpsMT := float64(queryCount) / mtWall.Seconds()

		record("efSearch=%d: recall@%d=%.4f, mean=%.0fus, p50=%.0fus, p95=%.0fus, p99=%.0fus, QPS_1t=%.0f, QPS_MT=%.0f (%d threads, checksum %d)",
			ef, k, recall, usOf(mean), usOf(p50), usOf(p95), usOf(p99), qps1t, qpsMT, threads, checksum)
	}
	record("DONE.")
}

// readFvecs reads an fvecs file: each record is an int32 little endian dimension
// followed by that many float32 components. It fails loudly if the file size is
// not an exact multiple of the record size, if the record count differs from
// wantCount, or if any record's dimension is not wantDim; a misaligned parse
// would produce a false recall, so this fails loudly instead.
func readFvecs(t *testing.T, path string, wantDim, wantCount int) [][]float32 {
	t.Helper()
	raw, err := os.ReadFile(path) //nolint:gosec // path comes from NAYLAMP_SIFT_DIR, an operator provided directory, not untrusted input
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	recSize := 4 + wantDim*4
	if len(raw)%recSize != 0 {
		t.Fatalf("%s: size %d is not a multiple of the record size %d (dim %d); misaligned or wrong dimension", path, len(raw), recSize, wantDim)
	}
	count := len(raw) / recSize
	if count != wantCount {
		t.Fatalf("%s: got %d records, want %d", path, count, wantCount)
	}
	out := make([][]float32, count)
	off := 0
	for i := 0; i < count; i++ {
		d := int(binary.LittleEndian.Uint32(raw[off:]))
		if d != wantDim {
			t.Fatalf("%s: record %d has dimension %d, want %d", path, i, d, wantDim)
		}
		off += 4
		vec := make([]float32, wantDim)
		for j := 0; j < wantDim; j++ {
			vec[j] = math.Float32frombits(binary.LittleEndian.Uint32(raw[off:]))
			off += 4
		}
		out[i] = vec
	}
	return out
}

// readIvecs reads an ivecs file: each record is an int32 little endian dimension
// followed by that many int32 values. The values are non-negative base indices,
// read as uint32 so they map straight to the store's ids. Same strict validation
// as readFvecs.
func readIvecs(t *testing.T, path string, wantDim, wantCount int) [][]uint32 {
	t.Helper()
	raw, err := os.ReadFile(path) //nolint:gosec // path comes from NAYLAMP_SIFT_DIR, an operator provided directory, not untrusted input
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	recSize := 4 + wantDim*4
	if len(raw)%recSize != 0 {
		t.Fatalf("%s: size %d is not a multiple of the record size %d (dim %d); misaligned or wrong dimension", path, len(raw), recSize, wantDim)
	}
	count := len(raw) / recSize
	if count != wantCount {
		t.Fatalf("%s: got %d records, want %d", path, count, wantCount)
	}
	out := make([][]uint32, count)
	off := 0
	for i := 0; i < count; i++ {
		d := int(binary.LittleEndian.Uint32(raw[off:]))
		if d != wantDim {
			t.Fatalf("%s: record %d has dimension %d, want %d", path, i, d, wantDim)
		}
		off += 4
		row := make([]uint32, wantDim)
		for j := 0; j < wantDim; j++ {
			row[j] = binary.LittleEndian.Uint32(raw[off:])
			off += 4
		}
		out[i] = row
	}
	return out
}

// pctIndex returns the index into a sorted slice of length n for percentile p in
// the range [0,1], clamped to the last element.
func pctIndex(n int, p float64) int {
	idx := int(float64(n) * p)
	if idx >= n {
		idx = n - 1
	}
	return idx
}
