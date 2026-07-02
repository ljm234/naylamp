package persist

import (
	"testing"
	"time"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// Sweeps the compaction Factor to gather evidence for choosing it. The MinFloor
// exists only for cold start (no snapshot yet); in steady state the ratio
// drives compaction. To measure the ratio in isolation, the sweep seeds an
// initial snapshot (so snapshotted > 0) and disables the floor, letting each
// Factor produce its own geometric compaction schedule: lower Factor compacts
// more often. A compaction is detected by the snapshot watermark advancing
// across a reopen.
//
// Predicted outcome (falsifiable, from the ratio arithmetic with base=500,
// perBatch=150, 60 batches): about 6 compactions at f=0.5, 3 at f=1.0 and 2 at
// f=2.0. Equal counts across factors mean the experiment has no signal.
//
// LIMITATIONS (declared): Go microbenchmark, one machine, synthetic workload;
// the optimum is empirical for this hardware and workload, not universal.
// FsyncNever keeps runtime reasonable and slightly favors aggressive Factor.

type sweepResult struct {
	factor          float64
	compactions     int
	totalRecoveryNS int64
	totalCompactNS  int64
}

func TestCompactionSweep(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping compaction sweep in -short mode")
	}

	const (
		dim      = 32
		base     = 500 // seeded into an initial snapshot so the ratio can act
		batches  = 60
		perBatch = 150
		seed     = 1234
	)
	factors := []float64{0.5, 1.0, 2.0}

	results := make([]sweepResult, 0, len(factors))
	for _, f := range factors {
		results = append(results, runSweepForFactor(t, f, dim, base, batches, perBatch, seed))
	}

	t.Log("=== COMPACTION FACTOR SWEEP (ratio-driven, floor disabled) ===")
	t.Logf("workload: base=%d + %d batches x %d = %d total, dim=%d, seed=%d",
		base, batches, perBatch, base+batches*perBatch, dim, seed)
	t.Log("factor | compactions | total_recovery_ms | total_compact_ms | combined_ms")
	for _, r := range results {
		recMS := float64(r.totalRecoveryNS) / 1e6
		compMS := float64(r.totalCompactNS) / 1e6
		t.Logf("%.1f    | %d           | %.1f              | %.1f             | %.1f",
			r.factor, r.compactions, recMS, compMS, recMS+compMS)
	}

	allSame := true
	for i := 1; i < len(results); i++ {
		if results[i].compactions != results[0].compactions {
			allSame = false
			break
		}
	}
	if allSame {
		t.Fatalf("sweep has no discriminating power: all factors triggered %d compactions", results[0].compactions)
	}
}

func runSweepForFactor(t *testing.T, factor float64, dim, base, batches, perBatch int, seed uint64) sweepResult {
	t.Helper()
	dir := t.TempDir()
	// Floor effectively disabled: the sweep measures the ratio in steady state.
	policy := CompactionPolicy{Factor: factor, MinFloor: 1 << 30}

	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible sweep, not security
	res := sweepResult{factor: factor}
	nextID := uint64(1)

	// Seed phase: write the base and checkpoint manually so a snapshot exists
	// (in steady state a snapshot always exists; the floor only covers cold
	// start, which is not what this experiment measures).
	db0, err := OpenWithPolicy(dir, vector.CosineDistance, FsyncNever, seed, policy)
	if err != nil {
		t.Fatalf("factor %.1f: seed open: %v", factor, err)
	}
	for i := 0; i < base; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if uerr := db0.Upsert(vector.Vector{ID: nextID, Data: data}); uerr != nil {
			t.Fatalf("factor %.1f: seed upsert: %v", factor, uerr)
		}
		nextID++
	}
	if cerr := db0.Checkpoint(); cerr != nil {
		t.Fatalf("factor %.1f: seed checkpoint: %v", factor, cerr)
	}
	if cerr := db0.Close(); cerr != nil {
		t.Fatalf("factor %.1f: seed close: %v", factor, cerr)
	}

	for b := 0; b < batches; b++ {
		wmBefore := manifestWatermark(t, dir)
		start := time.Now()
		db, err := OpenWithPolicy(dir, vector.CosineDistance, FsyncNever, seed, policy)
		if err != nil {
			t.Fatalf("factor %.1f batch %d: open: %v", factor, b, err)
		}
		elapsed := time.Since(start).Nanoseconds()

		wmAfter := manifestWatermark(t, dir)
		if wmAfter > wmBefore {
			res.compactions++
			res.totalCompactNS += elapsed
		} else {
			res.totalRecoveryNS += elapsed
		}

		for i := 0; i < perBatch; i++ {
			data := make([]float32, dim)
			for j := range data {
				data[j] = float32(rng.NormFloat64())
			}
			if uerr := db.Upsert(vector.Vector{ID: nextID, Data: data}); uerr != nil {
				t.Fatalf("factor %.1f batch %d: upsert: %v", factor, b, uerr)
			}
			nextID++
		}
		if cerr := db.Close(); cerr != nil {
			t.Fatalf("factor %.1f batch %d: close: %v", factor, b, cerr)
		}
	}
	return res
}

// manifestWatermark returns the snapshot watermark on disk, or 0 if none.
func manifestWatermark(t *testing.T, dir string) uint64 {
	t.Helper()
	m, ok, err := ReadManifest(dir)
	if err != nil || !ok {
		return 0
	}
	return m.SnapshotLSN
}
