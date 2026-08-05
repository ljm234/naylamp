package persist

import (
	"fmt"
	"os"

	"naylamp/engine/faultio"
	"naylamp/engine/hnsw"
)

// Checkpoint captures the engine state durably and reclaims WAL space. It runs
// three steps in a crash-safe order:
//
//  1. Write a full snapshot of the index (atomic temp-file + rename).
//  2. Write the manifest recording the snapshot's LSN watermark (atomic).
//  3. Truncate the WAL: delete segments the snapshot already covers.
//
// The order matters. The snapshot is made durable before the manifest points at
// it, and the WAL is trimmed only after both are safe. A crash at any point is
// recoverable: at worst recovery replays some extra WAL, never losing data.
//
// snapshotLSN is the highest WAL LSN included in the snapshot: the caller takes
// the snapshot and reads the WAL's LastLSN under the same lock so the two agree.
func Checkpoint(dir string, snap hnsw.IndexSnapshot, snapshotLSN uint64) error {
	return checkpointWith(dir, snap, snapshotLSN, faultio.OSOpener)
}

// checkpointWith is Checkpoint over an explicit opener, so a crash landing
// inside a checkpoint loses whatever the checkpoint had not fsynced yet.
func checkpointWith(dir string, snap hnsw.IndexSnapshot, snapshotLSN uint64, open faultio.Opener) error {
	// Step 1: snapshot to disk, atomically.
	if err := writeSnapshotWith(dir, snap, open); err != nil {
		return fmt.Errorf("persist: checkpoint snapshot: %w", err)
	}

	// Step 2: point the manifest at the snapshot's watermark, atomically.
	if err := writeManifestWith(dir, Manifest{SnapshotLSN: snapshotLSN}, open); err != nil {
		return fmt.Errorf("persist: checkpoint manifest: %w", err)
	}

	// Step 3: reclaim space by deleting fully-covered WAL segments.
	if err := truncateWALSegments(dir, snapshotLSN); err != nil {
		return fmt.Errorf("persist: checkpoint wal truncation: %w", err)
	}

	return nil
}

// truncateWALSegments deletes WAL segments whose records are all at or below the
// watermark (fully covered by the snapshot). A segment is only removed if its
// highest LSN is <= watermark; the active (highest-numbered) segment is never
// removed, since new appends go there.
func truncateWALSegments(dir string, watermark uint64) error {
	nums, err := listSegments(dir)
	if err != nil {
		return err
	}
	if len(nums) <= 1 {
		return nil // nothing to reclaim (only the active segment, or none)
	}

	activeNum := nums[len(nums)-1]
	for _, num := range nums {
		if num == activeNum {
			continue // never delete the active segment
		}
		lastLSN, _, serr := scanSegment(segmentPath(dir, num))
		if serr != nil {
			return serr
		}
		// Delete only if the whole segment is covered by the snapshot.
		if lastLSN <= watermark && lastLSN != 0 {
			if rerr := os.Remove(segmentPath(dir, num)); rerr != nil {
				return fmt.Errorf("persist: remove covered segment: %w", rerr)
			}
		}
	}

	return fsyncDir(dir)
}
