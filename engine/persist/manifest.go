package persist

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"

	"naylamp/engine/faultio"
)

// manifestFileName is the name of the manifest inside the data directory. The
// manifest is a tiny file that records which snapshot is current and, crucially,
// the LSN watermark: the highest WAL LSN that the snapshot already includes.
// Recovery replays only WAL records with an LSN greater than this watermark.
const manifestFileName = "MANIFEST"

// tempManifestName is the scratch file the manifest is written to before being
// atomically renamed into place, so a crash mid-write cannot corrupt it.
const tempManifestName = "MANIFEST.tmp"

// manifestMagic identifies a Naylamp manifest and guards against reading an
// unrelated file. It reuses the block magic for consistency.
const manifestMagic = magic

// Manifest records the durable state pointers: the snapshot's LSN watermark.
// It is deliberately tiny and rewritten atomically on each checkpoint.
type Manifest struct {
	// SnapshotLSN is the highest WAL LSN included in the current snapshot. A
	// value of 0 means there is no snapshot yet (replay the WAL from the start).
	SnapshotLSN uint64
}

// WriteManifest writes the manifest to dir atomically (temp file, fsync, rename,
// fsync dir). It is written after a snapshot is safely in place, so the pointer
// never references a snapshot that is not fully on disk.
//
// Layout, little-endian: magic uint32, then SnapshotLSN uint64.
func WriteManifest(dir string, m Manifest) error {
	return writeManifestWith(dir, m, faultio.OSOpener)
}

// writeManifestWith takes the opener as an argument. A crash test needs it so
// an unsynced manifest is lost the same way an unsynced WAL record is.
func writeManifestWith(dir string, m Manifest, open faultio.Opener) error {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("persist: create manifest dir: %w", err)
	}

	tmpPath := filepath.Join(dir, tempManifestName)
	finalPath := filepath.Join(dir, manifestFileName)

	buf := make([]byte, 4+8)
	binary.LittleEndian.PutUint32(buf[0:], manifestMagic)
	binary.LittleEndian.PutUint64(buf[4:], m.SnapshotLSN)

	if err := writeManifestFile(tmpPath, buf, open); err != nil {
		return err
	}
	if err := os.Rename(tmpPath, finalPath); err != nil {
		return fmt.Errorf("persist: rename manifest into place: %w", err)
	}
	return fsyncDir(dir)
}

// writeManifestFile writes the manifest bytes to a file and fsyncs it.
func writeManifestFile(path string, buf []byte, open faultio.Opener) error {
	f, err := open(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("persist: create temp manifest: %w", err)
	}
	w := bufio.NewWriter(f)
	if _, err := w.Write(buf); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: write manifest: %w", err)
	}
	if err := w.Flush(); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: flush manifest: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("persist: fsync manifest: %w", err)
	}
	return f.Close()
}

// ReadManifest reads the manifest from dir. A missing manifest returns a
// zero-value Manifest (SnapshotLSN 0) with ok=false, meaning there is no
// snapshot yet and the WAL should be replayed from the beginning.
func ReadManifest(dir string) (m Manifest, ok bool, err error) {
	path := filepath.Join(dir, manifestFileName)

	data, rerr := os.ReadFile(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if rerr != nil {
		if os.IsNotExist(rerr) {
			return Manifest{}, false, nil // no manifest yet
		}
		return Manifest{}, false, fmt.Errorf("persist: read manifest: %w", rerr)
	}
	if len(data) < 12 {
		return Manifest{}, false, fmt.Errorf("%w: manifest too short (%d bytes)", ErrShortBlock, len(data))
	}
	if got := binary.LittleEndian.Uint32(data[0:]); got != manifestMagic {
		return Manifest{}, false, fmt.Errorf("%w: manifest magic %#x", ErrBadMagic, got)
	}
	m.SnapshotLSN = binary.LittleEndian.Uint64(data[4:])
	return m, true, nil
}
