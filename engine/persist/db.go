package persist

import (
	"fmt"

	"naylamp/engine/faultio"
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
	// open is where every file this database writes comes from: the WAL's
	// segments, and the snapshot and manifest a checkpoint replaces. See
	// raft.Storage.open for why it is injectable at all.
	open faultio.Opener
}

// Open opens a durable database rooted at dir using the default compaction
// policy. It recovers any existing state (snapshot plus WAL replay), then opens
// the WAL for appending. See OpenWithPolicy to control startup compaction.
func Open(dir string, metric vector.MetricFunc, policy FsyncPolicy, seed uint64) (*DB, error) {
	return OpenWithPolicy(dir, metric, policy, seed, DefaultCompactionPolicy)
}

// OpenWithPolicy opens a durable database with an explicit compaction policy.
//
// Startup compaction: if recovery replayed enough of the WAL (per the
// compaction policy), Open takes a fresh snapshot and truncates the WAL before
// returning, so the next startup loads the snapshot instead of replaying the
// whole WAL again. A slow recovery from a large WAL therefore happens at most
// once. The metric must match the data on disk; seed is used only when there is
// no prior snapshot to restore.
func OpenWithPolicy(dir string, metric vector.MetricFunc, policy FsyncPolicy, seed uint64, compaction CompactionPolicy) (*DB, error) {
	return openWith(dir, metric, policy, seed, compaction, openerFor(policy))
}

// openWith takes the opener as an argument, which is how a durability test puts
// this database on a simulated disk that can lose power. Every production caller
// goes through Open or OpenWithPolicy.
func openWith(dir string, metric vector.MetricFunc, policy FsyncPolicy, seed uint64, compaction CompactionPolicy, open faultio.Opener) (*DB, error) {
	state, err := Recover(dir, metric, seed)
	if err != nil {
		return nil, fmt.Errorf("persist: open recover: %w", err)
	}

	if shouldCompact(state.ReplayedRecords, state.SnapshotRecords, compaction) {
		lastLSN, lerr := lastLSNOnDisk(dir)
		if lerr != nil {
			return nil, fmt.Errorf("persist: open compaction lsn: %w", lerr)
		}
		if cerr := checkpointWith(dir, state.Index.Export(), lastLSN, open); cerr != nil {
			return nil, fmt.Errorf("persist: open startup compaction: %w", cerr)
		}
	}

	wal, err := openWALWith(dir, policy, defaultSegmentBytes, open)
	if err != nil {
		return nil, fmt.Errorf("persist: open wal: %w", err)
	}

	return &DB{
		dir:    dir,
		store:  state.Store,
		index:  state.Index,
		wal:    wal,
		metric: metric,
		open:   open,
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

	if _, err := db.wal.Append(OpUpsert, v); err != nil {
		return fmt.Errorf("persist: upsert wal: %w", err)
	}

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
	if err := checkpointWith(db.dir, snap, watermark, db.open); err != nil {
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
