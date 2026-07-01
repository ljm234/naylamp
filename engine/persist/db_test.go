package persist

import (
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// insertRandom inserts n deterministic random vectors into the db and returns
// the queries and the db's answers, for later comparison after recovery.
func insertRandom(t *testing.T, db *DB, n, dim int, seed uint64) {
	t.Helper()
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	for i := 0; i < n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if err := db.Upsert(vector.Vector{ID: uint64(i + 1), Data: data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
}

// makeQueries builds q deterministic random query vectors.
func makeQueries(q, dim int, seed uint64) [][]float32 {
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	queries := make([][]float32, q)
	for i := range queries {
		query := make([]float32, dim)
		for j := range query {
			query[j] = float32(rng.NormFloat64())
		}
		queries[i] = query
	}
	return queries
}

// TestDB_RecoversAfterReopen is the core durability test for Phase 2: data
// written to a DB survives closing and reopening. It inserts vectors, records
// query answers, closes the DB, reopens it (triggering recovery from the WAL),
// and verifies the recovered DB answers identically and reports the same size.
func TestDB_RecoversAfterReopen(t *testing.T) {
	const (
		n    = 800
		dim  = 32
		k    = 10
		seed = 7
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	insertRandom(t, db, n, dim, seed)

	queries := makeQueries(20, dim, 999)
	want := make([][]vector.Neighbor, len(queries))
	for i, q := range queries {
		want[i] = db.Search(q, k)
	}
	beforeLen := db.Len()

	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: recovery replays the WAL and rebuilds the state.
	db2, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = db2.Close() }()

	if db2.Len() != beforeLen {
		t.Fatalf("len after recovery: got %d want %d", db2.Len(), beforeLen)
	}
	for i, q := range queries {
		got := db2.Search(q, k)
		if len(got) != len(want[i]) {
			t.Fatalf("query %d: len got %d want %d", i, len(got), len(want[i]))
		}
		for j := range want[i] {
			if got[j].ID != want[i][j].ID {
				t.Fatalf("query %d pos %d: id got %d want %d", i, j, got[j].ID, want[i][j].ID)
			}
		}
	}
}

// TestDB_RecoversWithCheckpoint verifies recovery from a snapshot plus WAL tail:
// some vectors are captured by a checkpoint, more are written after it, and the
// reopened DB must contain both sets.
func TestDB_RecoversWithCheckpoint(t *testing.T) {
	const (
		dim  = 16
		k    = 10
		seed = 3
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	// First batch, then checkpoint (snapshot + WAL truncation).
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	const firstBatch = 300
	for i := 1; i <= firstBatch; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if err := db.Upsert(vector.Vector{ID: uint64(i), Data: data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	if err := db.Checkpoint(); err != nil {
		t.Fatalf("checkpoint: %v", err)
	}

	// Second batch after the checkpoint (these live only in the WAL tail).
	const secondBatch = 200
	for i := firstBatch + 1; i <= firstBatch+secondBatch; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if err := db.Upsert(vector.Vector{ID: uint64(i), Data: data}); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	total := firstBatch + secondBatch
	if db.Len() != total {
		t.Fatalf("len before close: got %d want %d", db.Len(), total)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: recovery must combine snapshot (first batch) + WAL tail (second).
	db2, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = db2.Close() }()

	if db2.Len() != total {
		t.Fatalf("len after recovery: got %d want %d", db2.Len(), total)
	}
}

// TestDB_DeleteSurvivesRecovery checks that a delete is durable: a vector
// removed before shutdown stays removed after recovery.
func TestDB_DeleteSurvivesRecovery(t *testing.T) {
	const (
		dim  = 8
		seed = 11
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	// Insert 10 vectors, then delete id 5.
	for i := 1; i <= 10; i++ {
		v := vector.Vector{ID: uint64(i), Data: makeVec(uint64(i), dim).Data}
		if err := db.Upsert(v); err != nil {
			t.Fatalf("upsert %d: %v", i, err)
		}
	}
	if err := db.Delete(5); err != nil {
		t.Fatalf("delete: %v", err)
	}
	beforeLen := db.Len()
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: id 5 must still be gone.
	db2, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = db2.Close() }()

	if db2.Len() != beforeLen {
		t.Fatalf("len after recovery: got %d want %d", db2.Len(), beforeLen)
	}
	if db2.Len() != 9 {
		t.Fatalf("expected 9 vectors after deleting 1 of 10, got %d", db2.Len())
	}
}

// TestDB_Idempotent checks that recovering twice yields the same state (no
// double-application of WAL records).
func TestDB_Idempotent(t *testing.T) {
	const (
		dim  = 8
		seed = 21
	)
	dir := t.TempDir()

	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	insertRandom(t, db, 100, dim, seed)
	beforeLen := db.Len()
	if err := db.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// First recovery.
	db2, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("reopen 1: %v", err)
	}
	len1 := db2.Len()
	if err := db2.Close(); err != nil {
		t.Fatalf("close 2: %v", err)
	}

	// Second recovery: must match the first exactly.
	db3, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("reopen 2: %v", err)
	}
	defer func() { _ = db3.Close() }()

	if len1 != beforeLen || db3.Len() != beforeLen {
		t.Fatalf("idempotency broken: before %d, recovery1 %d, recovery2 %d",
			beforeLen, len1, db3.Len())
	}
}

// TestDB_EmptyDir checks that opening a fresh directory yields an empty,
// functional database.
func TestDB_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	db, err := Open(dir, vector.CosineDistance, FsyncAlways, 1)
	if err != nil {
		t.Fatalf("open empty: %v", err)
	}
	defer func() { _ = db.Close() }()

	if db.Len() != 0 {
		t.Fatalf("expected empty db, got len %d", db.Len())
	}
	// It must accept inserts.
	if err := db.Upsert(vector.Vector{ID: 1, Data: []float32{1, 2, 3, 4}}); err != nil {
		t.Fatalf("upsert into empty: %v", err)
	}
	if db.Len() != 1 {
		t.Fatalf("expected len 1 after insert, got %d", db.Len())
	}
}
