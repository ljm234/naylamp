package faultio

import (
	"os"
	"path/filepath"
	"testing"
)

// The cost of a barrier is the only thing about it this machine can measure.
// Whether the drive committed the bytes needs a power cut and an observer
// outside the box; what a benchmark can show is that the two barriers are not
// the same operation, which is the observable consequence of one of them
// reaching further than the other.
//
// Read the pair together, never either alone. A run where they cost the same is
// not proof the strong barrier is a no-op, since a drive is free to have
// nothing in its cache to flush. A run where the strong one costs plainly more
// is what a real cache flush looks like.

func benchmarkBarrier(b *testing.B, mode SyncMode) {
	b.Helper()
	path := filepath.Join(b.TempDir(), "barrier")
	f, err := OSOpenerMode(mode)(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		b.Fatalf("open: %v", err)
	}
	defer func() { _ = f.Close() }()

	record := make([]byte, 64) // about the size of one small WAL record
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, werr := f.Write(record); werr != nil {
			b.Fatalf("write: %v", werr)
		}
		if serr := f.Sync(); serr != nil {
			b.Fatalf("sync: %v", serr)
		}
	}
}

// BenchmarkBarrier_Fsync is what FsyncAlways pays per acknowledged write today.
func BenchmarkBarrier_Fsync(b *testing.B) { benchmarkBarrier(b, SyncFsync) }

// BenchmarkBarrier_Full is what FsyncFull would pay instead.
func BenchmarkBarrier_Full(b *testing.B) { benchmarkBarrier(b, SyncFull) }
