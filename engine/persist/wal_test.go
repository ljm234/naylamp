package persist

import (
	"os"
	"path/filepath"
	"testing"

	"naylamp/engine/vector"
)

// makeVec builds a small deterministic vector for tests.
func makeVec(id uint64, dim int) vector.Vector {
	data := make([]float32, dim)
	for i := range data {
		data[i] = float32(id) + float32(i)*0.5
	}
	return vector.Vector{ID: id, Data: data}
}

// TestWAL_AppendReopenReplay checks the core durability property: records
// written and fsynced survive closing and reopening the log, and read back
// exactly (same LSN, op, and vector data).
func TestWAL_AppendReopenReplay(t *testing.T) {
	dir := t.TempDir()

	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}

	const count = 500
	const dim = 16
	for i := 1; i <= count; i++ {
		if _, err := wal.Append(OpUpsert, makeVec(uint64(i), dim)); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close wal: %v", err)
	}

	// Reopen and read everything back.
	records, err := ReadAllRecords(dir)
	if err != nil {
		t.Fatalf("read records: %v", err)
	}
	if len(records) != count {
		t.Fatalf("record count: got %d want %d", len(records), count)
	}
	for i, rec := range records {
		wantID := uint64(i + 1)
		if rec.LSN != wantID {
			t.Fatalf("record %d: lsn got %d want %d", i, rec.LSN, wantID)
		}
		if rec.Op != OpUpsert {
			t.Fatalf("record %d: op got %d want OpUpsert", i, rec.Op)
		}
		if rec.Vector.ID != wantID {
			t.Fatalf("record %d: vector id got %d want %d", i, rec.Vector.ID, wantID)
		}
		want := makeVec(wantID, dim)
		for j := range want.Data {
			if rec.Vector.Data[j] != want.Data[j] {
				t.Fatalf("record %d data idx %d: got %v want %v", i, j, rec.Vector.Data[j], want.Data[j])
			}
		}
	}
}

// TestWAL_DeleteRecords checks that delete records round-trip with just their id.
func TestWAL_DeleteRecords(t *testing.T) {
	dir := t.TempDir()
	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}

	// Mix upserts and deletes.
	if _, err := wal.Append(OpUpsert, makeVec(1, 8)); err != nil {
		t.Fatalf("append upsert: %v", err)
	}
	if _, err := wal.Append(OpDelete, vector.Vector{ID: 1}); err != nil {
		t.Fatalf("append delete: %v", err)
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	records, err := ReadAllRecords(dir)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("count: got %d want 2", len(records))
	}
	if records[1].Op != OpDelete || records[1].Vector.ID != 1 {
		t.Fatalf("delete record wrong: %+v", records[1])
	}
}

// TestWAL_DetectsTornTail simulates a crash mid-append by truncating the log
// partway through the last record. The reader must return every complete record
// before the torn one and discard the partial tail, without a fatal error. This
// is the crash-safety guarantee of the WAL.
func TestWAL_DetectsTornTail(t *testing.T) {
	dir := t.TempDir()
	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("open wal: %v", err)
	}

	const count = 10
	for i := 1; i <= count; i++ {
		if _, err := wal.Append(OpUpsert, makeVec(uint64(i), 8)); err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Truncate the file by a few bytes to tear the last record.
	path := filepath.Join(dir, walFileName)
	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if err := os.Truncate(path, info.Size()-5); err != nil {
		t.Fatalf("truncate: %v", err)
	}

	records, err := ReadAllRecords(dir)
	if err != nil {
		t.Fatalf("read after truncate: %v", err)
	}
	// The last record is torn, so we expect count-1 clean records.
	if len(records) != count-1 {
		t.Fatalf("torn tail: got %d records, want %d", len(records), count-1)
	}
	for i, rec := range records {
		if rec.LSN != uint64(i+1) {
			t.Fatalf("record %d: lsn got %d want %d", i, rec.LSN, i+1)
		}
	}
}

// TestWAL_MonotonicLSN checks that LSNs are assigned strictly increasing with
// no gaps, both within a session and across a reopen.
func TestWAL_MonotonicLSN(t *testing.T) {
	dir := t.TempDir()

	wal, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	for i := 1; i <= 5; i++ {
		lsn, err := wal.Append(OpUpsert, makeVec(uint64(i), 4))
		if err != nil {
			t.Fatalf("append %d: %v", i, err)
		}
		if lsn != uint64(i) {
			t.Fatalf("lsn: got %d want %d", lsn, i)
		}
	}
	if err := wal.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Reopen: the next LSN must continue from 6, not restart at 1.
	wal2, err := OpenWAL(dir, FsyncAlways)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = wal2.Close() }()

	lsn, err := wal2.Append(OpUpsert, makeVec(6, 4))
	if err != nil {
		t.Fatalf("append after reopen: %v", err)
	}
	if lsn != 6 {
		t.Fatalf("lsn after reopen: got %d want 6", lsn)
	}
}

// TestWAL_EmptyDir checks that reading a directory with no log yields zero
// records and no error (a fresh database).
func TestWAL_EmptyDir(t *testing.T) {
	dir := t.TempDir()
	records, err := ReadAllRecords(dir)
	if err != nil {
		t.Fatalf("read empty dir: %v", err)
	}
	if len(records) != 0 {
		t.Fatalf("expected 0 records, got %d", len(records))
	}
}
