package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// This file tests crashes around a checkpoint. A checkpoint writes a snapshot,
// then the manifest, then truncates the WAL. A crash between any of these steps
// must still leave a recoverable database: the crash-safe order guarantees that
// at worst recovery replays extra WAL, never losing an acknowledged write.

// TestCrashCheckpoint_PartialCheckpointRecovers simulates the dangerous windows
// of a checkpoint by performing each step manually and stopping partway, then
// recovering and asserting all acknowledged writes survive. It covers three
// crash points: after the snapshot only, after snapshot+manifest, and after the
// full checkpoint, each followed by more writes.
func TestCrashCheckpoint_PartialCheckpointRecovers(t *testing.T) {
	const (
		seeds = 60
		dim   = 8
	)
	for s := uint64(1); s <= seeds; s++ {
		runPartialCheckpointSeed(t, s, dim)
	}
}

func runPartialCheckpointSeed(t *testing.T, seed uint64, dim int) {
	t.Helper()
	dir := t.TempDir()
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible crash scenarios, not security

	oracle := newCrashOracle()

	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}

	// First batch of durable writes.
	nextID := uint64(1)
	firstBatch := 15 + rng.IntN(25)
	for i := 0; i < firstBatch; i++ {
		v := vector.Vector{ID: nextID, Data: randData(rng, dim)}
		nextID++
		if err := db.Upsert(v); err != nil {
			t.Fatalf("seed %d: upsert: %v", seed, err)
		}
		oracle.upsert(v)
	}

	// Choose a crash point within the checkpoint: 0 = after snapshot only,
	// 1 = after snapshot + manifest, 2 = full checkpoint completes.
	crashPoint := int(seed % 3)
	snap := db.index.Export()
	watermark := db.wal.LastLSN()

	// Step 1: always write the snapshot.
	if err := WriteSnapshot(dir, snap); err != nil {
		t.Fatalf("seed %d: write snapshot: %v", seed, err)
	}
	if crashPoint >= 1 {
		// Step 2: write the manifest.
		if err := WriteManifest(dir, Manifest{SnapshotLSN: watermark}); err != nil {
			t.Fatalf("seed %d: write manifest: %v", seed, err)
		}
	}
	if crashPoint >= 2 {
		// Step 3: truncate the WAL.
		if err := truncateWALSegments(dir, watermark); err != nil {
			t.Fatalf("seed %d: truncate: %v", seed, err)
		}
	}

	// Simulate a crash: abandon the DB (its WAL writes were all fsynced).
	_ = db

	// Second batch: reopen (recovery), write more, to ensure the DB is usable
	// after a partial-checkpoint crash, then crash again.
	db2, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("seed %d: reopen after partial checkpoint: %v", seed, err)
	}
	secondBatch := 10 + rng.IntN(20)
	for i := 0; i < secondBatch; i++ {
		v := vector.Vector{ID: nextID, Data: randData(rng, dim)}
		nextID++
		if err := db2.Upsert(v); err != nil {
			t.Fatalf("seed %d: upsert after reopen: %v", seed, err)
		}
		oracle.upsert(v)
	}
	_ = db2

	// Final recovery: every acknowledged write from both batches must survive.
	state, err := Recover(dir, vector.CosineDistance, seed)
	if err != nil {
		t.Fatalf("seed %d: final recover: %v", seed, err)
	}
	for id, want := range oracle.live {
		got, gerr := state.Store.Get(id)
		if gerr != nil {
			t.Fatalf("seed %d (crashPoint %d): acknowledged id %d lost: %v", seed, crashPoint, id, gerr)
		}
		for j := range want.Data {
			if got.Data[j] != want.Data[j] {
				t.Fatalf("seed %d: id %d data mismatch at %d", seed, id, j)
			}
		}
	}
}
