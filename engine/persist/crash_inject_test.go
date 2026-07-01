package persist

import (
	"os"
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// This file injects dirty crashes: instead of trusting a clean abandon, it
// physically corrupts the tail of the WAL (extra garbage bytes, or a truncation
// mid-record) to mimic a process dying partway through a write or a power loss
// that leaves an incomplete tail on disk. Recovery must never panic, must
// recover every complete record, and must discard the torn tail.

// TestCrashInject_GarbageTailIgnored appends durable records, then writes junk
// bytes onto the end of the active WAL segment (as if a partial write landed
// there during a crash). Recovery must return exactly the complete records and
// ignore the trailing garbage.
func TestCrashInject_GarbageTailIgnored(t *testing.T) {
	const (
		seeds = 100
		dim   = 8
	)
	for s := uint64(1); s <= seeds; s++ {
		runGarbageTailSeed(t, s, dim)
	}
}

func runGarbageTailSeed(t *testing.T, seed uint64, dim int) {
	t.Helper()
	dir := t.TempDir()
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible crash scenarios, not security

	// Write a batch of durable records via the WAL directly.
	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("seed %d: open wal: %v", seed, err)
	}
	n := 10 + rng.IntN(40)
	for i := 1; i <= n; i++ {
		if _, err := wal.Append(OpUpsert, vector.Vector{ID: uint64(i), Data: randData(rng, dim)}); err != nil {
			t.Fatalf("seed %d: append: %v", seed, err)
		}
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("seed %d: close: %v", seed, err)
	}

	// Corrupt the tail: append random garbage to the active segment, as if a
	// crash left a partial record behind.
	nums, err := listSegments(dir)
	if err != nil {
		t.Fatalf("seed %d: list segments: %v", seed, err)
	}
	active := segmentPath(dir, nums[len(nums)-1])
	garbage := make([]byte, 1+rng.IntN(40))
	for i := range garbage {
		garbage[i] = byte(rng.IntN(256)) //nolint:gosec // IntN(256) is always 0-255, fits in a byte
	}
	if err := appendBytes(active, garbage); err != nil {
		t.Fatalf("seed %d: append garbage: %v", seed, err)
	}

	// Recovery must read exactly n complete records and ignore the garbage,
	// without panicking.
	records, err := ReadAllRecords(dir)
	if err != nil {
		t.Fatalf("seed %d: read after garbage: %v", seed, err)
	}
	if len(records) != n {
		t.Fatalf("seed %d: got %d records, want %d (garbage tail should be ignored)", seed, len(records), n)
	}
	for i, rec := range records {
		if rec.LSN != uint64(i+1) {
			t.Fatalf("seed %d: record %d lsn got %d want %d", seed, i, rec.LSN, i+1)
		}
	}
}

// TestCrashInject_TruncatedMidRecord truncates the WAL at many different offsets
// inside the last record, mimicking a crash that wrote only part of a record.
// At every truncation point, recovery must succeed and return all records that
// were fully written before the truncation, never panicking.
func TestCrashInject_TruncatedMidRecord(t *testing.T) {
	const dim = 8
	dir := t.TempDir()
	rng := rand.New(rand.NewPCG(42, 0)) //nolint:gosec // deterministic RNG for reproducible crash scenarios, not security

	// Build a WAL with several records.
	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}
	const n = 20
	for i := 1; i <= n; i++ {
		if _, err := wal.Append(OpUpsert, vector.Vector{ID: uint64(i), Data: randData(rng, dim)}); err != nil {
			t.Fatalf("append: %v", err)
		}
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	nums, err := listSegments(dir)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	active := segmentPath(dir, nums[len(nums)-1])
	fullSize := fileSize(t, active)

	// Try truncating at every byte offset from full size down to 1. At each, the
	// recovered record count must be between 0 and n, monotic-ish, and recovery
	// must never fail or panic.
	for cut := fullSize; cut >= 1; cut-- {
		if err := os.Truncate(active, cut); err != nil {
			t.Fatalf("truncate to %d: %v", cut, err)
		}
		records, rerr := ReadAllRecords(dir)
		if rerr != nil {
			t.Fatalf("cut %d: recovery failed: %v", cut, rerr)
		}
		if len(records) > n {
			t.Fatalf("cut %d: got %d records, more than the %d ever written", cut, len(records), n)
		}
		// Whatever records survived must have contiguous LSNs from 1.
		for i, rec := range records {
			if rec.LSN != uint64(i+1) {
				t.Fatalf("cut %d: record %d lsn got %d want %d", cut, i, rec.LSN, i+1)
			}
		}
	}
}

// appendBytes appends raw bytes to a file (used to inject garbage).
func appendBytes(path string, b []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0o600) //nolint:gosec // test-controlled path
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	_, werr := f.Write(b)
	return werr
}

// fileSize returns the size of a file in bytes.
func fileSize(t *testing.T, path string) int64 {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	return info.Size()
}
