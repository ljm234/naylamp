package persist

import (
	"fmt"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// DB is a durable vector database: an in-memory store and HNSW index whose
// mutations are written to a write-ahead log before being applied, so
// acknowledged writes survive a crash. It is opened from a data directory,
// recovering any prior state, and every Upsert or Delete is logged and fsynced
// (per policy) before it touches memory.
type DB struct {
	dir    string
	store  *vector.Store
	index  *hnsw.Index
	wal    *WAL
	metric vector.MetricFunc
}

// Open opens a durable database rooted at dir. It recovers any existing state
// (snapshot plus WAL replay), then opens the WAL for appending so new mutations
// are logged. A fresh dir yields an empty, ready database. The metric must match
// the one the data was written with; seed is used only when there is no prior
// snapshot to restore.
//
// Startup compaction: if recovery had to replay a large number of WAL records,
// Open takes a fresh snapshot and truncates the WAL before returning. This makes
// the next startup fast (it will load the snapshot instead of replaying the
// whole WAL again), so a slow recovery from a large WAL happens at most once.
func Open(dir string, metric vector.MetricFunc, policy FsyncPolicy, seed uint64) (*DB, error) {
	state, err := Recover(dir, metric, seed)
	if err != nil {
		return nil, fmt.Errorf("persist: open recover: %w", err)
	}

	// Startup compaction: if the replay was large, snapshot now so the next
	// startup is fast. Done before opening the WAL for appending, using the
	// recovered index and the current on-disk WAL position.
	if state.ReplayedRecords >= compactionThreshold {
		lastLSN, lerr := lastLSNOnDisk(dir)
		if lerr != nil {
			return nil, fmt.Errorf("persist: open compaction lsn: %w", lerr)
		}
		if cerr := Checkpoint(dir, state.Index.Export(), lastLSN); cerr != nil {
			return nil, fmt.Errorf("persist: open startup compaction: %w", cerr)
		}
	}

	wal, err := OpenWAL(dir, policy)
	if err != nil {
		return nil, fmt.Errorf("persist: open wal: %w", err)
	}

	return &DB{
		dir:    dir,
		store:  state.Store,
		index:  state.Index,
		wal:    wal,
		metric: metric,
	}, nil
}

// lastLSNOnDisk returns the highest LSN currently present in the WAL on disk, by
// scanning all segments. Used during startup compaction to set the snapshot's
// watermark to exactly what the WAL covers.
func lastLSNOnDisk(dir string) (uint64, error) {
	nums, err := listSegments(dir)
	if err != nil {
		return 0, err
	}
	var maxLSN uint64
	for _, num := range nums {
		lastLSN, _, serr := scanSegment(segmentPath(dir, num))
		if serr != nil {
			return 0, serr
		}
		if lastLSN > maxLSN {
			maxLSN = lastLSN
		}
	}
	return maxLSN, nil
}

// Upsert durably inserts or updates a vector. The mutation is written to the WAL
// and made durable (per policy) before it is applied to the store and index, so
// a returned Upsert means the write survives a crash.
func (db *DB) Upsert(v vector.Vector) error {
	if err := v.Validate(); err != nil {
		return fmt.Errorf("persist: upsert validate: %w", err)
	}

	// Log first (durability), then apply to memory.
	if _, err := db.wal.Append(OpUpsert, v); err != nil {
		return fmt.Errorf("persist: upsert wal: %w", err)
	}

	// Apply: replace any existing vector, then insert into store and index.
	if _, gerr := db.store.Get(v.ID); gerr == nil {
		if derr := db.store.Delete(v.ID); derr != nil {
			return fmt.Errorf("persist: upsert delete-old: %w", derr)
		}
		db.index.Delete(v.ID)
	}
	if err := db.store.Insert(v); err != nil {
		return fmt.Errorf("persist: upsert store: %w", err)
	}
	if err := db.index.Insert(v.ID); err != nil {
		return fmt.Errorf("persist: upsert index: %w", err)
	}
	return nil
}

// Delete durably removes a vector by id. The delete is logged and made durable
// before it is applied. Deleting an id that is not present is a no-op.
func (db *DB) Delete(id uint64) error {
	if _, err := db.wal.Append(OpDelete, vector.Vector{ID: id}); err != nil {
		return fmt.Errorf("persist: delete wal: %w", err)
	}
	if err := db.store.Delete(id); err != nil {
		return nil //nolint:nilerr // deleting an absent id is a no-op
	}
	db.index.Delete(id)
	return nil
}

// Search returns the k nearest neighbors to the query vector. Reads do not touch
// the WAL.
func (db *DB) Search(query []float32, k int) []vector.Neighbor {
	return db.index.Search(query, k)
}

// Len returns how many vectors are currently in the database.
func (db *DB) Len() int {
	return db.index.Len()
}

// Checkpoint snapshots the current state and truncates the WAL, reclaiming
// space. It captures the index and the current WAL position together so the
// snapshot's watermark is consistent.
func (db *DB) Checkpoint() error {
	snap := db.index.Export()
	watermark := db.wal.LastLSN()
	if err := Checkpoint(db.dir, snap, watermark); err != nil {
		return fmt.Errorf("persist: db checkpoint: %w", err)
	}
	return nil
}

// Close flushes and closes the WAL. After Close the database must not be used.
func (db *DB) Close() error {
	if err := db.wal.Close(); err != nil {
		return fmt.Errorf("persist: db close: %w", err)
	}
	return nil
}
