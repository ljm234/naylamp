package persist

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
)

// ReadAllRecords reads every valid record across all WAL segments in dir, in
// order, and returns them. It is the read side of the log, used by recovery to
// replay mutations after a restart.
//
// Segments are read in ascending order. A clean end of a segment continues to
// the next. A torn or corrupt record (the signature of a crash mid-append)
// stops the read at the last valid record and returns everything before it;
// because records are contiguous across segments, a hole means the durable log
// ends there. No segments returns no records (a fresh database).
func ReadAllRecords(dir string) ([]WALRecord, error) {
	nums, err := listSegments(dir)
	if err != nil {
		return nil, err
	}
	if len(nums) == 0 {
		return nil, nil
	}

	var records []WALRecord
	for _, num := range nums {
		done, rerr := readSegmentInto(&records, segmentPath(dir, num))
		if rerr != nil {
			return records, rerr
		}
		if done {
			// A torn or corrupt tail was hit: stop reading further segments.
			break
		}
	}
	return records, nil
}

// readSegmentInto appends every valid record from one segment to records. It
// returns done=true if a torn or corrupt tail was hit (replay must stop
// entirely), or done=false if the segment was read cleanly to its end.
func readSegmentInto(records *[]WALRecord, path string) (done bool, err error) {
	f, oerr := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if oerr != nil {
		if os.IsNotExist(oerr) {
			return false, nil
		}
		return false, fmt.Errorf("persist: open wal segment for read: %w", oerr)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	for {
		typ, payload, rerr := readBlock(r)
		if rerr != nil {
			if errors.Is(rerr, io.EOF) {
				return false, nil // clean end of this segment
			}
			if errors.Is(rerr, ErrShortBlock) || errors.Is(rerr, ErrChecksum) {
				return true, nil // torn/corrupt tail: stop everything
			}
			return false, fmt.Errorf("persist: read wal segment: %w", rerr)
		}
		if typ != BlockWALRecord {
			return false, fmt.Errorf("persist: unexpected block type %d in wal", typ)
		}
		rec, derr := decodeWALRecord(payload)
		if derr != nil {
			return true, nil // framed but undecodable: stop
		}
		*records = append(*records, rec)
	}
}
