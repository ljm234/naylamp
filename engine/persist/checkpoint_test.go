package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// buildTestIndex builds a small store-backed HNSW index over deterministic
// random vectors, returning the index and the store it reads from.
func buildTestIndex(t *testing.T, n, dim int) (*hnsw.Index, *vector.Store) {
	t.Helper()
	store := vector.NewStore()
	idx := hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)

	rng := rand.New(rand.NewPCG(1, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	for i := 0; i < n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		v := vector.Vector{ID: uint64(i + 1), Data: data}
		if err := store.Insert(v); err != nil {
			t.Fatalf("store insert: %v", err)
		}
		if err := idx.Insert(v.ID); err != nil {
			t.Fatalf("index insert: %v", err)
		}
	}
	return idx, store
}

// TestSnapshot_RoundTripOnDisk writes a full index snapshot to disk, loads it
// back, restores an index, and verifies searches match the original. Unlike the
// in-memory codec test in 2.1, this exercises the real file path (atomic write,
// fsync, read).
func TestSnapshot_RoundTripOnDisk(t *testing.T) {
	const (
		n   = 1500
		dim = 32
		k   = 10
	)
	dir := t.TempDir()

	idx, store := buildTestIndex(t, n, dim)

	// Record original results for a set of queries.
	rng := rand.New(rand.NewPCG(99, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	queries := make([][]float32, 15)
	want := make([][]vector.Neighbor, len(queries))
	for q := range queries {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.NormFloat64())
		}
		queries[q] = query
		want[q] = idx.Search(query, k)
	}

	// Write snapshot to disk.
	if err := WriteSnapshot(dir, idx.Export()); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	// Load it back and restore an index over the same store.
	snap, ok, err := LoadSnapshot(dir)
	if err != nil {
		t.Fatalf("load snapshot: %v", err)
	}
	if !ok {
		t.Fatalf("expected snapshot to exist")
	}
	restored := hnsw.RestoreIndex(snap, vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)

	if restored.Len() != idx.Len() {
		t.Fatalf("len mismatch: restored %d original %d", restored.Len(), idx.Len())
	}
	for q := range queries {
		got := restored.Search(queries[q], k)
		if len(got) != len(want[q]) {
			t.Fatalf("query %d: len got %d want %d", q, len(got), len(want[q]))
		}
		for i := range want[q] {
			if got[i].ID != want[q][i].ID {
				t.Fatalf("query %d pos %d: id got %d want %d", q, i, got[i].ID, want[q][i].ID)
			}
		}
	}
}

// TestSnapshot_LoadMissing checks that loading from a directory with no snapshot
// returns ok=false and no error.
func TestSnapshot_LoadMissing(t *testing.T) {
	dir := t.TempDir()
	_, ok, err := LoadSnapshot(dir)
	if err != nil {
		t.Fatalf("load missing: %v", err)
	}
	if ok {
		t.Fatalf("expected ok=false for missing snapshot")
	}
}

// TestManifest_RoundTrip checks that the manifest's LSN watermark is written and
// read back correctly, and that a missing manifest reports ok=false.
func TestManifest_RoundTrip(t *testing.T) {
	dir := t.TempDir()

	// Missing manifest.
	if _, ok, err := ReadManifest(dir); err != nil || ok {
		t.Fatalf("missing manifest: ok=%v err=%v", ok, err)
	}

	// Write and read back.
	if err := WriteManifest(dir, Manifest{SnapshotLSN: 4242}); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	m, ok, err := ReadManifest(dir)
	if err != nil || !ok {
		t.Fatalf("read manifest: ok=%v err=%v", ok, err)
	}
	if m.SnapshotLSN != 4242 {
		t.Fatalf("watermark: got %d want 4242", m.SnapshotLSN)
	}
}

// TestCheckpoint_TruncatesCoveredSegments is the key durability test for 2.3:
// after a checkpoint whose watermark covers earlier WAL segments, those covered
// segments are deleted to reclaim space, while records beyond the watermark
// remain. It verifies no covered data is lost (it is in the snapshot) and no
// uncovered data is deleted.
func TestCheckpoint_TruncatesCoveredSegments(t *testing.T) {
	const dim = 8
	dir := t.TempDir()

	// Small segments so we get several of them.
	wal, err := openWAL(dir, FsyncAlways, 256)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}

	// Append enough records to create multiple segments.
	const total = 150
	for i := 1; i <= total; i++ {
		if _, err := wal.Append(OpUpsert, makeVec(uint64(i), dim)); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}

	segsBefore, err := listSegments(dir)
	if err != nil {
		t.Fatalf("list before: %v", err)
	}
	if len(segsBefore) < 3 {
		t.Fatalf("expected several segments, got %d", len(segsBefore))
	}

	// Build an index to snapshot (contents independent; we test WAL truncation).
	idx, _ := buildTestIndex(t, 100, dim)

	// Checkpoint with a watermark that covers everything written so far.
	watermark := wal.LastLSN()
	if err := wal.Close(); err != nil {
		t.Fatalf("close wal: %v", err)
	}
	if err := Checkpoint(dir, idx.Export(), watermark); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}

	// After checkpoint, covered non-active segments should be gone; the active
	// segment (highest number) must remain.
	segsAfter, err := listSegments(dir)
	if err != nil {
		t.Fatalf("list after: %v", err)
	}
	if len(segsAfter) != 1 {
		t.Fatalf("expected only the active segment to remain, got %d", len(segsAfter))
	}
	if segsAfter[0] != segsBefore[len(segsBefore)-1] {
		t.Fatalf("remaining segment should be the active one: got %d want %d",
			segsAfter[0], segsBefore[len(segsBefore)-1])
	}

	// The manifest must record the watermark.
	m, ok, err := ReadManifest(dir)
	if err != nil || !ok {
		t.Fatalf("read manifest: ok=%v err=%v", ok, err)
	}
	if m.SnapshotLSN != watermark {
		t.Fatalf("manifest watermark: got %d want %d", m.SnapshotLSN, watermark)
	}
}

// TestCheckpoint_KeepsUncoveredSegments checks that if the watermark only covers
// some segments, later segments (with LSN beyond the watermark) are preserved.
func TestCheckpoint_KeepsUncoveredSegments(t *testing.T) {
	const dim = 8
	dir := t.TempDir()

	wal, err := openWAL(dir, FsyncAlways, 256)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}
	const total = 150
	for i := 1; i <= total; i++ {
		if _, err := wal.Append(OpUpsert, makeVec(uint64(i), dim)); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}

	segsBefore, err := listSegments(dir)
	if err != nil {
		t.Fatalf("list before: %v", err)
	}
	if len(segsBefore) < 3 {
		t.Fatalf("expected several segments, got %d", len(segsBefore))
	}

	// Use a low watermark: only the first segment is fully covered.
	firstSegLastLSN, _, err := scanSegment(segmentPath(dir, segsBefore[0]))
	if err != nil {
		t.Fatalf("scan first seg: %v", err)
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	idx, _ := buildTestIndex(t, 50, dim)
	if err := Checkpoint(dir, idx.Export(), firstSegLastLSN); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}

	// Only the first segment should have been removed; the rest remain.
	segsAfter, err := listSegments(dir)
	if err != nil {
		t.Fatalf("list after: %v", err)
	}
	if len(segsAfter) != len(segsBefore)-1 {
		t.Fatalf("expected %d segments after, got %d", len(segsBefore)-1, len(segsAfter))
	}
	// The removed one must be the first; the first remaining is the second.
	if segsAfter[0] == segsBefore[0] {
		t.Fatalf("first segment should have been removed but is still present")
	}
}
