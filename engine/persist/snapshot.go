package persist

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"

	"naylamp/engine/hnsw"
)

// snapshotFileName is the canonical name of the current snapshot inside the
// data directory. A snapshot captures the full index state at a known LSN.
const snapshotFileName = "snapshot.snap"

// tempSnapshotName is the scratch file a snapshot is written to before it is
// atomically renamed into place. Writing to a temp file and renaming means a
// crash mid-write leaves the previous snapshot intact rather than a corrupt one.
const tempSnapshotName = "snapshot.snap.tmp"

// WriteSnapshot writes a full index snapshot to dir atomically. It serializes
// the snapshot to a temp file, fsyncs the file and its directory, then renames
// the temp file onto the canonical snapshot path. Because rename is atomic, a
// reader always sees either the old complete snapshot or the new complete one,
// never a half-written file.
//
// The snapshot is self-contained: it holds the full graph and the metadata
// needed to rebuild the index. The LSN watermark (how far the WAL is covered)
// is recorded separately in the manifest, written after this succeeds.
func WriteSnapshot(dir string, snap hnsw.IndexSnapshot) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("persist: create snapshot dir: %w", err)
	}

	tmpPath := filepath.Join(dir, tempSnapshotName)
	finalPath := filepath.Join(dir, snapshotFileName)

	// Write the snapshot to the temp file.
	if err := writeSnapshotFile(tmpPath, snap); err != nil {
		return err
	}

	// Atomically move the temp file onto the canonical path.
	if err := os.Rename(tmpPath, finalPath); err != nil {
		return fmt.Errorf("persist: rename snapshot into place: %w", err)
	}

	// Fsync the directory so the rename itself is durable (otherwise a crash
	// could lose the rename even though the file contents are on disk).
	return fsyncDir(dir)
}

// writeSnapshotFile serializes the snapshot to a single file and fsyncs it.
func writeSnapshotFile(path string, snap hnsw.IndexSnapshot) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("persist: create temp snapshot: %w", err)
	}

	w := bufio.NewWriter(f)
	if err := EncodeIndex(w, snap); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: encode snapshot: %w", err)
	}
	if err := w.Flush(); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: flush snapshot: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: fsync snapshot: %w", err)
	}
	return f.Close()
}

// fsyncDir opens a directory and fsyncs it, so that metadata operations like a
// rename are persisted. On most filesystems a rename is not durable until the
// containing directory is synced.
func fsyncDir(dir string) error {
	d, err := os.Open(dir) //nolint:gosec // dir is caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("persist: open dir for fsync: %w", err)
	}
	defer func() { _ = d.Close() }()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("persist: fsync dir: %w", err)
	}
	return nil
}

// LoadSnapshot reads the snapshot in dir and returns the decoded index
// snapshot. A missing snapshot returns ok=false with no error (a database that
// has a WAL but no snapshot yet, or a brand-new one). A corrupt snapshot
// returns an error.
func LoadSnapshot(dir string) (snap hnsw.IndexSnapshot, ok bool, err error) {
	path := filepath.Join(dir, snapshotFileName)

	f, oerr := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if oerr != nil {
		if os.IsNotExist(oerr) {
			return hnsw.IndexSnapshot{}, false, nil // no snapshot yet
		}
		return hnsw.IndexSnapshot{}, false, fmt.Errorf("persist: open snapshot: %w", oerr)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	decoded, derr := DecodeIndex(r)
	if derr != nil {
		return hnsw.IndexSnapshot{}, false, fmt.Errorf("persist: decode snapshot: %w", derr)
	}

	return decoded, true, nil
}
