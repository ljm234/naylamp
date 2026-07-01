package persist

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// WAL segments are individual append-only files named wal-NNNNNN.log, where
// NNNNNN is a zero-padded, monotonically increasing segment number. Splitting
// the log into fixed-size segments lets a checkpoint reclaim space by deleting
// whole segments that a snapshot already covers, instead of rewriting one huge
// file.

const (
	// walSegmentPrefix and walSegmentSuffix bracket the segment number in a
	// segment's file name.
	walSegmentPrefix = "wal-"
	walSegmentSuffix = ".log"

	// segmentNumberWidth is the zero-padding width of the segment number, so
	// lexical sort order matches numeric order (wal-000002 before wal-000010).
	segmentNumberWidth = 6

	// defaultSegmentBytes is the size threshold at which the active segment is
	// rotated and a new one started. 64 MiB balances file count against the
	// cost of keeping many open.
	defaultSegmentBytes int64 = 64 * 1024 * 1024
)

// segmentName builds the file name for a given segment number.
func segmentName(num uint64) string {
	return fmt.Sprintf("%s%0*d%s", walSegmentPrefix, segmentNumberWidth, num, walSegmentSuffix)
}

// segmentPath builds the full path for a given segment number in dir.
func segmentPath(dir string, num uint64) string {
	return filepath.Join(dir, segmentName(num))
}

// parseSegmentNumber extracts the segment number from a file name, returning
// ok=false if the name is not a WAL segment. Used when scanning a data dir to
// discover existing segments.
func parseSegmentNumber(name string) (uint64, bool) {
	if !strings.HasPrefix(name, walSegmentPrefix) || !strings.HasSuffix(name, walSegmentSuffix) {
		return 0, false
	}
	mid := strings.TrimSuffix(strings.TrimPrefix(name, walSegmentPrefix), walSegmentSuffix)
	num, err := strconv.ParseUint(mid, 10, 64)
	if err != nil {
		return 0, false
	}
	return num, true
}

// listSegments scans dir and returns the numbers of all WAL segments present,
// sorted ascending. A dir with no segments returns an empty slice.
func listSegments(dir string) ([]uint64, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("persist: read wal dir: %w", err)
	}

	var nums []uint64
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if num, ok := parseSegmentNumber(e.Name()); ok {
			nums = append(nums, num)
		}
	}
	sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
	return nums, nil
}
