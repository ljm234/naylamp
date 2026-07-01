package persist

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"naylamp/engine/vector"
)

// FsyncPolicy controls how aggressively the WAL forces data to physical disk.
type FsyncPolicy uint8

const (
	// FsyncAlways calls fsync after every append: a returned Append means the
	// record is durably on disk. Safest, and the default.
	FsyncAlways FsyncPolicy = iota
	// FsyncNever never fsyncs: fast, but a crash can lose recent appends. For
	// tests and benchmarks only, never for real durability.
	FsyncNever
)

// walFileName is the name of the (single, for now) WAL file inside the data
// directory. Segment rotation, added later, will generalize this.
const walFileName = "wal-000001.log"

// WAL is an append-only write-ahead log. Every mutation is written here and
// forced to disk (per the fsync policy) before it is applied to the in-memory
// engine, so acknowledged writes survive a crash. Appends are serialized by a
// mutex to keep LSNs strictly ordered and the file consistent.
type WAL struct {
	mu     sync.Mutex
	f      *os.File
	w      *bufio.Writer
	policy FsyncPolicy
	lsn    uint64 // last assigned LSN; the next append uses lsn+1
	dir    string
}

// OpenWAL opens (or creates) the write-ahead log in dir. If a log file already
// exists, it is opened for appending and the highest LSN found is used as the
// starting point, so new appends continue the sequence rather than colliding.
func OpenWAL(dir string, policy FsyncPolicy) (*WAL, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("persist: create wal dir: %w", err)
	}
	path := filepath.Join(dir, walFileName)

	// Determine the highest LSN already on disk, if any, by scanning existing
	// records. This lets a reopened WAL continue the LSN sequence.
	lastLSN, err := scanLastLSN(path)
	if err != nil {
		return nil, err
	}

	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return nil, fmt.Errorf("persist: open wal file: %w", err)
	}

	return &WAL{
		f:      f,
		w:      bufio.NewWriter(f),
		policy: policy,
		lsn:    lastLSN,
		dir:    dir,
	}, nil
}

// scanLastLSN reads an existing WAL file and returns the highest LSN present.
// A missing file returns 0 (fresh log). A torn record at the tail stops the
// scan cleanly; whatever valid records precede it still count.
func scanLastLSN(path string) (uint64, error) {
	f, err := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil // no log yet
		}
		return 0, fmt.Errorf("persist: open wal for scan: %w", err)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	var last uint64
	for {
		typ, payload, err := readBlock(r)
		if err != nil {
			// Clean EOF or a torn tail: stop, keeping what we have.
			return last, nil
		}
		if typ != BlockWALRecord {
			return last, fmt.Errorf("persist: unexpected block type %d in wal", typ)
		}
		rec, derr := decodeWALRecord(payload)
		if derr != nil {
			return last, nil // corrupt tail record; stop cleanly
		}
		last = rec.LSN
	}
}

// Append writes a mutation to the log and returns the LSN assigned to it. It
// assigns the next sequence number, frames the record with a CRC via
// writeBlock, flushes the buffer, and (per policy) fsyncs so the record is
// durable before this returns. The mutex serializes appends so LSNs stay
// strictly ordered.
func (wal *WAL) Append(op OpType, v vector.Vector) (uint64, error) {
	wal.mu.Lock()
	defer wal.mu.Unlock()

	wal.lsn++
	rec := WALRecord{LSN: wal.lsn, Op: op, Vector: v}
	payload := encodeWALRecord(rec)

	if _, err := writeBlock(wal.w, BlockWALRecord, payload); err != nil {
		return 0, fmt.Errorf("persist: write wal record: %w", err)
	}
	if err := wal.w.Flush(); err != nil {
		return 0, fmt.Errorf("persist: flush wal: %w", err)
	}
	if wal.policy == FsyncAlways {
		if err := wal.f.Sync(); err != nil {
			return 0, fmt.Errorf("persist: fsync wal: %w", err)
		}
	}

	return wal.lsn, nil
}

// LastLSN returns the most recently assigned LSN (0 if nothing appended yet).
func (wal *WAL) LastLSN() uint64 {
	wal.mu.Lock()
	defer wal.mu.Unlock()
	return wal.lsn
}

// Close flushes and closes the underlying file. After Close the WAL must not be
// used again.
func (wal *WAL) Close() error {
	wal.mu.Lock()
	defer wal.mu.Unlock()
	if err := wal.w.Flush(); err != nil {
		return fmt.Errorf("persist: flush wal on close: %w", err)
	}
	if err := wal.f.Sync(); err != nil {
		return fmt.Errorf("persist: fsync wal on close: %w", err)
	}
	return wal.f.Close()
}
