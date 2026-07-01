package persist

import (
	"bufio"
	"fmt"
	"os"
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

// WAL is an append-only, segmented write-ahead log. Mutations are appended to
// the active segment and forced to disk (per policy) before being applied to
// the engine, so acknowledged writes survive a crash. When the active segment
// reaches the size threshold it is rotated: closed, and a new higher-numbered
// segment is started. Splitting the log into segments lets a checkpoint reclaim
// space by deleting whole segments a snapshot already covers. Appends are
// serialized by a mutex to keep LSNs strictly ordered.
type WAL struct {
	mu           sync.Mutex
	dir          string
	policy       FsyncPolicy
	segmentBytes int64

	f          *os.File
	w          *bufio.Writer
	activeNum  uint64
	activeSize int64
	lsn        uint64
}

// OpenWAL opens (or creates) a segmented WAL in dir using the default segment
// size. Existing segments are discovered; the highest-numbered one becomes the
// active segment, a torn tail (from a crash mid-append) is truncated away, and
// the LSN sequence continues from the highest LSN found.
func OpenWAL(dir string, policy FsyncPolicy) (*WAL, error) {
	return openWAL(dir, policy, defaultSegmentBytes)
}

// openWAL is the full constructor with a configurable segment size, used by
// tests to force rotation at small sizes.
func openWAL(dir string, policy FsyncPolicy, segmentBytes int64) (*WAL, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("persist: create wal dir: %w", err)
	}

	nums, err := listSegments(dir)
	if err != nil {
		return nil, err
	}

	wal := &WAL{
		dir:          dir,
		policy:       policy,
		segmentBytes: segmentBytes,
	}

	if len(nums) == 0 {
		// Fresh log: start at segment 1.
		if err := wal.openActiveSegment(1, 0); err != nil {
			return nil, err
		}
		return wal, nil
	}

	// Scan every segment for the global max LSN, and the valid end offset of the
	// highest (active) segment so a torn tail can be truncated.
	activeN := nums[len(nums)-1]
	var maxLSN uint64
	var activeValidEnd int64
	for _, num := range nums {
		lastLSN, validEnd, serr := scanSegment(segmentPath(dir, num))
		if serr != nil {
			return nil, serr
		}
		if lastLSN > maxLSN {
			maxLSN = lastLSN
		}
		if num == activeN {
			activeValidEnd = validEnd
		}
	}

	// Truncate a torn tail on the active segment so appends continue cleanly.
	path := segmentPath(dir, activeN)
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("persist: stat active segment: %w", err)
	}
	if info.Size() > activeValidEnd {
		if err := os.Truncate(path, activeValidEnd); err != nil {
			return nil, fmt.Errorf("persist: truncate torn tail: %w", err)
		}
	}

	wal.lsn = maxLSN
	if err := wal.openActiveSegment(activeN, activeValidEnd); err != nil {
		return nil, err
	}
	return wal, nil
}

// openActiveSegment opens the given segment number for appending and sets it as
// the active segment starting at the given size.
func (wal *WAL) openActiveSegment(num uint64, size int64) error {
	f, err := os.OpenFile(segmentPath(wal.dir, num), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("persist: open wal segment: %w", err)
	}
	wal.f = f
	wal.w = bufio.NewWriter(f)
	wal.activeNum = num
	wal.activeSize = size
	return nil
}

// Append writes a mutation to the log and returns its LSN. If the active
// segment has reached the size threshold, it is rotated first. The record is
// framed with a CRC, flushed, and (per policy) fsynced before returning, so an
// acknowledged write is durable. The mutex serializes appends so LSNs stay
// strictly ordered.
func (wal *WAL) Append(op OpType, v vector.Vector) (uint64, error) {
	wal.mu.Lock()
	defer wal.mu.Unlock()

	// Rotate if the active segment is full.
	if wal.activeSize >= wal.segmentBytes {
		if err := wal.rotate(); err != nil {
			return 0, err
		}
	}

	wal.lsn++
	rec := WALRecord{LSN: wal.lsn, Op: op, Vector: v}
	payload := encodeWALRecord(rec)

	n, err := writeBlock(wal.w, BlockWALRecord, payload)
	if err != nil {
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
	wal.activeSize += int64(n)

	return wal.lsn, nil
}

// rotate closes the active segment and opens the next-numbered one as the new
// active segment. Called when the active segment reaches the size threshold.
func (wal *WAL) rotate() error {
	if err := wal.w.Flush(); err != nil {
		return fmt.Errorf("persist: flush before rotate: %w", err)
	}
	if err := wal.f.Sync(); err != nil {
		return fmt.Errorf("persist: fsync before rotate: %w", err)
	}
	if err := wal.f.Close(); err != nil {
		return fmt.Errorf("persist: close before rotate: %w", err)
	}
	return wal.openActiveSegment(wal.activeNum+1, 0)
}

// LastLSN returns the most recently assigned LSN (0 if nothing appended yet).
func (wal *WAL) LastLSN() uint64 {
	wal.mu.Lock()
	defer wal.mu.Unlock()
	return wal.lsn
}

// Close flushes and closes the active segment. After Close the WAL must not be
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

// scanSegment reads a WAL segment and returns the highest LSN it contains and
// the byte offset just past the last valid record. A torn or corrupt tail (from
// a crash mid-append) ends the scan; validEnd marks where clean data stops, so
// callers can truncate the torn bytes. A missing file returns zero.
func scanSegment(path string) (lastLSN uint64, validEnd int64, err error) {
	f, oerr := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if oerr != nil {
		if os.IsNotExist(oerr) {
			return 0, 0, nil
		}
		return 0, 0, fmt.Errorf("persist: open segment for scan: %w", oerr)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	for {
		typ, payload, rerr := readBlock(r)
		if rerr != nil {
			// EOF or torn/corrupt tail: stop; validEnd is the last good offset.
			return lastLSN, validEnd, nil
		}
		if typ != BlockWALRecord {
			return lastLSN, validEnd, fmt.Errorf("persist: unexpected block type %d in wal segment", typ)
		}
		rec, derr := decodeWALRecord(payload)
		if derr != nil {
			return lastLSN, validEnd, nil
		}
		lastLSN = rec.LSN
		validEnd += int64(headerSize + len(payload) + 4)
	}
}
