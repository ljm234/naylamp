package persist

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// ReadAllRecords opens the WAL in dir and returns every valid record it holds,
// in the order they were written. It is the read side of the log, used by
// recovery to replay mutations after a restart.
//
// A clean end of file ends the read normally. A torn or corrupt record at the
// tail (the signature of a crash mid-append) stops the read at the last valid
// record rather than failing: everything durably written before the crash is
// returned, and the incomplete tail is discarded. A missing log returns no
// records (a fresh, never-written database).
func ReadAllRecords(dir string) ([]WALRecord, error) {
	path := filepath.Join(dir, walFileName)

	f, err := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // no log yet: nothing to replay
		}
		return nil, fmt.Errorf("persist: open wal for read: %w", err)
	}
	defer func() { _ = f.Close() }()

	r := bufio.NewReader(f)
	var records []WALRecord

	for {
		typ, payload, err := readBlock(r)
		if err != nil {
			if errors.Is(err, io.EOF) {
				break // clean end at a block boundary
			}
			if errors.Is(err, ErrShortBlock) || errors.Is(err, ErrChecksum) {
				// Torn or corrupt tail record: a crash interrupted a write.
				// Stop cleanly, keeping every complete record before it.
				break
			}
			return records, fmt.Errorf("persist: read wal: %w", err)
		}

		if typ != BlockWALRecord {
			return records, fmt.Errorf("persist: unexpected block type %d in wal", typ)
		}

		rec, derr := decodeWALRecord(payload)
		if derr != nil {
			// A record that framed correctly (CRC ok) but decodes wrong is a
			// deeper inconsistency; stop and keep what precedes it.
			break
		}
		records = append(records, rec)
	}

	return records, nil
}
