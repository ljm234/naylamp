package persist

// This file defines when startup compaction runs. Rather than a fixed record
// count (not portable across hardware, since recovery cost per record depends
// on the machine), compaction is triggered by an amortization rule inspired by
// log-structured merge (LSM) tree compaction: compact when the volume replayed
// from the write-ahead log grows large relative to what is already consolidated
// in the snapshot. Two conditions cover the two regimes: an absolute floor for
// the cold-start case (no snapshot yet), and a relative ratio for steady state.

// CompactionPolicy controls startup compaction. Factor is the LSM-style ratio:
// compact when replayed records exceed Factor times the snapshot's record
// count. MinFloor is an absolute lower bound so a cold start (empty snapshot)
// still compacts once the replayed WAL is non-trivial, avoiding the degenerate
// ratio when nothing is consolidated yet.
type CompactionPolicy struct {
	Factor   float64
	MinFloor int
}

// DefaultCompactionPolicy is the default policy. Factor 0.5 was chosen from a
// factor sweep (see compaction_sweep_test.go) over {0.5, 1.0, 2.0} on an
// identical seeded workload (base 500 plus 60 batches of 150, dim 32, Apple M4,
// FsyncNever): compaction counts 6/3/2 matched the ratio arithmetic exactly,
// and combined recovery-plus-compaction time was 43.1s / 79.8s / 88.3s, so the
// aggressive factor wins in this regime because HNSW replay cost is
// super-linear while snapshot writes are comparatively cheap. Scope of that
// evidence: this hardware and synthetic workload, factors below 0.5 untested;
// snapshot cost grows with index size, so the optimum should be revalidated at
// large scale (Phase 5). MinFloor is anchored to the lowest measured recovery
// point (about 1000 records, roughly 0.4s), below which compaction is not
// worth its cost.
var DefaultCompactionPolicy = CompactionPolicy{
	Factor:   0.5,
	MinFloor: 1000,
}

// shouldCompact reports whether startup compaction should run given how many
// records recovery replayed and how many records the loaded snapshot held. It
// is a pure function of its inputs so it can be unit-tested in isolation and
// swept over Factor values without any I/O.
//
// Rule: compact if replayed reaches the absolute floor, OR if replayed exceeds
// Factor times the snapshotted count. The floor dominates when snapshotted is
// small (cold start); the ratio dominates once a substantial snapshot exists.
func shouldCompact(replayed, snapshotted int, p CompactionPolicy) bool {
	if replayed >= p.MinFloor {
		return true
	}
	if snapshotted > 0 && float64(replayed) > p.Factor*float64(snapshotted) {
		return true
	}
	return false
}
