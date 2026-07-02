package persist

import (
	"fmt"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// RecoveredState is the result of recovering a database from disk: a rebuilt
// vector store and the HNSW index that reads from it. Together they are the
// engine state as of the last acknowledged write before shutdown or crash.
type RecoveredState struct {
	Store *vector.Store
	Index *hnsw.Index

	// ReplayedRecords is how many WAL records were applied during recovery.
	// SnapshotRecords is how many records the loaded snapshot held (0 if none).
	// Together they let a caller apply a compaction policy to decide whether a
	// startup compaction is worth taking to speed up the next startup.
	ReplayedRecords int
	SnapshotRecords int
}

// Recover reconstructs engine state from the data directory. It loads the
// latest snapshot (if any), then replays every WAL record whose LSN is beyond
// the snapshot's watermark, applying each mutation to a freshly rebuilt store
// and index. The result is identical to the state at the last durable write.
//
// The three inputs on disk combine cleanly: the snapshot provides the bulk of
// the state at a known LSN, the manifest says how far that snapshot reaches, and
// the WAL supplies everything appended since. A missing snapshot means replay
// the whole WAL from the start; a missing WAL and snapshot means an empty
// database.
//
// metric selects the distance function (must match how the index was built);
// seed initializes the index's random layer generator for replayed inserts.
func Recover(dir string, metric vector.MetricFunc, seed uint64) (*RecoveredState, error) {
	store := vector.NewStore()

	vectorData := func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}

	// Step 1: load the snapshot, if present, to seed the store and index.
	snap, hasSnapshot, err := LoadSnapshot(dir)
	if err != nil {
		return nil, fmt.Errorf("persist: recover load snapshot: %w", err)
	}

	var idx *hnsw.Index
	snapshotRecords := 0
	if hasSnapshot {
		for _, n := range snap.Nodes {
			if serr := store.Insert(vector.Vector{ID: n.ID, Data: n.Data}); serr != nil {
				return nil, fmt.Errorf("persist: recover seed store from snapshot: %w", serr)
			}
		}
		snapshotRecords = len(snap.Nodes)
		idx = hnsw.RestoreIndex(snap, metric, vectorData, seed)
	} else {
		idx = hnsw.NewIndex(hnsw.DefaultParams(), metric, vectorData, seed)
	}

	// Step 2: read the manifest to learn the snapshot's LSN watermark. Records
	// at or below this LSN are already in the snapshot and must be skipped.
	manifest, _, err := ReadManifest(dir)
	if err != nil {
		return nil, fmt.Errorf("persist: recover read manifest: %w", err)
	}
	watermark := manifest.SnapshotLSN

	// Step 3: replay WAL records beyond the watermark, applying each to the
	// store and index so the final state matches the last durable write.
	records, err := ReadAllRecords(dir)
	if err != nil {
		return nil, fmt.Errorf("persist: recover read wal: %w", err)
	}
	replayed := 0
	for _, rec := range records {
		if rec.LSN <= watermark {
			continue
		}
		if aerr := applyRecord(store, idx, rec); aerr != nil {
			return nil, fmt.Errorf("persist: recover apply lsn %d: %w", rec.LSN, aerr)
		}
		replayed++
	}

	return &RecoveredState{
		Store:           store,
		Index:           idx,
		ReplayedRecords: replayed,
		SnapshotRecords: snapshotRecords,
	}, nil
}

// applyRecord applies a single WAL record to the store and index during replay.
// An upsert inserts or replaces the vector; a delete removes it. Replaying is
// deterministic, so applying the same records twice yields the same state.
func applyRecord(store *vector.Store, idx *hnsw.Index, rec WALRecord) error {
	switch rec.Op {
	case OpUpsert:
		if _, err := store.Get(rec.Vector.ID); err == nil {
			if derr := store.Delete(rec.Vector.ID); derr != nil {
				return fmt.Errorf("update delete-old: %w", derr)
			}
			idx.Delete(rec.Vector.ID)
		}
		if ierr := store.Insert(rec.Vector); ierr != nil {
			return fmt.Errorf("insert store: %w", ierr)
		}
		if ierr := idx.Insert(rec.Vector.ID); ierr != nil {
			return fmt.Errorf("insert index: %w", ierr)
		}
	case OpDelete:
		if derr := store.Delete(rec.Vector.ID); derr != nil {
			return nil //nolint:nilerr // deleting an absent id is a no-op during replay
		}
		idx.Delete(rec.Vector.ID)
	default:
		return fmt.Errorf("unknown wal op %d", rec.Op)
	}
	return nil
}
