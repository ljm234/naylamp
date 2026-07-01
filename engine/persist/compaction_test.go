package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// This file verifies startup compaction (B1): after recovery replays a large
// WAL, Open takes a fresh snapshot and truncates the WAL, so the next startup
// loads the snapshot instead of replaying everything again. The slow recovery
// from a large WAL happens at most once.

// TestCompaction_TriggeredAfterLargeReplay writes more than the compaction
// threshold of records, closes, and reopens. The reopen must (a) recover the
// correct state, and (b) leave a snapshot on disk with a truncated WAL, proving
// compaction ran. A second reopen must still see the same state.
func TestCompaction_TriggeredAfterLargeReplay(t *testing.T) {
	const (
		dim  = 8
		seed = 5
	)
	dir := t.TempDir()

	// Write enough records to exceed the compaction threshold. Use FsyncNever
	// for speed here; durability is tested elsewhere, this test is about
	// compaction behavior.
	db, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	n := compactionThreshold + 500
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	for i := 1; i <= n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if err := db.Upsert(vector.Vector{ID: uint64(i), Data: data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	beforeLen := db.Len()
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Before reopen: there should be no snapshot yet (we never checkpointed).
	if _, ok, serr := LoadSnapshot(dir); serr != nil {
		t.Fatalf("pre-reopen load snapshot: %v", serr)
	} else if ok {
		t.Fatalf("did not expect a snapshot before the compacting reopen")
	}

	// Reopen: recovery replays the large WAL and should trigger compaction.
	db2, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen (compacting): %v", err)
	}
	if db2.Len() != beforeLen {
		t.Fatalf("len after compacting recovery: got %d want %d", db2.Len(), beforeLen)
	}

	// After the compacting reopen: a snapshot must now exist on disk.
	snap, ok, err := LoadSnapshot(dir)
	if err != nil {
		t.Fatalf("post-reopen load snapshot: %v", err)
	}
	if !ok {
		t.Fatalf("expected a snapshot to exist after startup compaction")
	}
	if len(snap.Nodes) != beforeLen {
		t.Fatalf("snapshot node count: got %d want %d", len(snap.Nodes), beforeLen)
	}

	// The manifest must record a non-zero watermark (the WAL is now covered).
	m, ok, err := ReadManifest(dir)
	if err != nil || !ok {
		t.Fatalf("read manifest after compaction: ok=%v err=%v", ok, err)
	}
	if m.SnapshotLSN == 0 {
		t.Fatalf("expected a non-zero snapshot watermark after compaction")
	}

	if err := db2.Close(); err != nil {
		t.Fatalf("close db2: %v", err)
	}

	// Second reopen: state must still be identical (now served largely from the
	// snapshot plus a short WAL tail).
	db3, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen 2: %v", err)
	}
	defer func() { _ = db3.Close() }()
	if db3.Len() != beforeLen {
		t.Fatalf("len after second reopen: got %d want %d", db3.Len(), beforeLen)
	}
}

// TestCompaction_SkippedForSmallReplay checks the opposite: a small WAL (below
// the threshold) does NOT trigger compaction, so no snapshot is created. This
// avoids paying the snapshot cost when it would not help.
func TestCompaction_SkippedForSmallReplay(t *testing.T) {
	const (
		dim  = 8
		seed = 6
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// Well below the threshold.
	for i := 1; i <= 100; i++ {
		if err := db.Upsert(vector.Vector{ID: uint64(i), Data: makeVec(uint64(i), dim).Data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: small replay, so no compaction.
	db2, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = db2.Close() }()

	// No snapshot should have been created.
	if _, ok, serr := LoadSnapshot(dir); serr != nil {
		t.Fatalf("load snapshot: %v", serr)
	} else if ok {
		t.Fatalf("did not expect compaction (and a snapshot) for a small WAL")
	}
}
