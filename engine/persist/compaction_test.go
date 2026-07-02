package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// This file verifies startup compaction: after recovery replays a large WAL,
// Open takes a fresh snapshot and truncates the WAL, so the next startup loads
// the snapshot instead of replaying everything again.

// TestShouldCompact_PureLogic unit-tests the compaction decision in isolation,
// covering the cold-start floor, the LSM-style ratio, and the no-compaction
// cases, with no I/O.
func TestShouldCompact_PureLogic(t *testing.T) {
	p := CompactionPolicy{Factor: 1.0, MinFloor: 1000}

	cases := []struct {
		name        string
		replayed    int
		snapshotted int
		want        bool
	}{
		{"below floor, no snapshot", 500, 0, false},
		{"at floor, no snapshot", 1000, 0, true},
		{"above floor, no snapshot", 2000, 0, true},
		{"below floor but ratio exceeded triggers", 600, 500, true}, // floor not met, but 600 > 1.0*500 triggers via ratio
		{"ratio exceeded, above floor", 1200, 500, true},
		{"large snapshot, small replay", 200, 100000, false},
		{"ratio exactly at factor does not trigger", 500, 500, false}, // strictly greater required
	}
	for _, c := range cases {
		got := shouldCompact(c.replayed, c.snapshotted, p)
		if got != c.want {
			t.Errorf("%s: shouldCompact(%d,%d)=%v want %v", c.name, c.replayed, c.snapshotted, got, c.want)
		}
	}
}

// TestCompaction_TriggeredAfterLargeReplay writes more than the compaction
// floor of records, closes, and reopens. The reopen must (a) recover the
// correct state, and (b) leave a snapshot on disk with a truncated WAL, proving
// compaction ran. A second reopen must still see the same state.
func TestCompaction_TriggeredAfterLargeReplay(t *testing.T) {
	const (
		dim  = 8
		seed = 5
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	n := DefaultCompactionPolicy.MinFloor + 500
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

	if _, ok, serr := LoadSnapshot(dir); serr != nil {
		t.Fatalf("pre-reopen load snapshot: %v", serr)
	} else if ok {
		t.Fatalf("did not expect a snapshot before the compacting reopen")
	}

	db2, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen (compacting): %v", err)
	}
	if db2.Len() != beforeLen {
		t.Fatalf("len after compacting recovery: got %d want %d", db2.Len(), beforeLen)
	}

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

	db3, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen 2: %v", err)
	}
	defer func() { _ = db3.Close() }()
	if db3.Len() != beforeLen {
		t.Fatalf("len after second reopen: got %d want %d", db3.Len(), beforeLen)
	}
}

// TestCompaction_SkippedForSmallReplay checks that a small WAL (below the floor)
// does NOT trigger compaction, so no snapshot is created.
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
	for i := 1; i <= 100; i++ {
		if err := db.Upsert(vector.Vector{ID: uint64(i), Data: makeVec(uint64(i), dim).Data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	db2, err := Open(dir, vector.CosineDistance, FsyncNever, seed)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = db2.Close() }()

	if _, ok, serr := LoadSnapshot(dir); serr != nil {
		t.Fatalf("load snapshot: %v", serr)
	} else if ok {
		t.Fatalf("did not expect compaction (and a snapshot) for a small WAL")
	}
}
