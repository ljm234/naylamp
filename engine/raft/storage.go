package raft

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"

	"naylamp/engine/cluster"
	"naylamp/engine/persist"
)

// Snapshot is the durable image of the applied state machine at a log
// position: everything at or below Index is folded into Data. The bytes are
// opaque to the storage layer; the node above owns their meaning.
type Snapshot struct {
	Index uint64
	Term  uint64
	Data  []byte
}

// Storage is the durable side of a Raft node: the hard state file and the
// segmented entry log. The entry log is append-only in the etcd style: a
// follower resolving a conflict does not surgically truncate files, it
// appends the new entry under the same index and replay discards the
// superseded suffix. Only uncommitted entries can ever be superseded, since
// committed entries are immutable, so replay-by-supersession is correct by
// construction. The hard state is a separate atomically-replaced file
// because it changes on a different cadence (votes, term bumps) than the
// log, and because an unreadable hard state must be a fatal error, never a
// silent zero: a node that forgets its vote can vote twice in one term.
type Storage struct {
	mu          sync.Mutex
	dir         string
	maxSegBytes int64

	active     *os.File
	activeNum  uint64
	activeSize int64

	lastIndex uint64
	// snapIndex is the position of the durable snapshot; entries at or
	// below it are committed, immutable and folded into the snapshot.
	snapIndex uint64
	segMax    map[uint64]uint64 // segment number -> highest entry index in it
	segNums   []uint64          // sorted segment numbers, activeNum last
	closed    bool
}

const (
	hardStateFile = "raft-hardstate"
	segPrefix     = "raft-"
	segSuffix     = ".log"
	snapshotFile  = "raft-snapshot"

	// DefaultMaxSegmentBytes rotates the entry log like the Phase 2 WAL.
	DefaultMaxSegmentBytes = 64 << 20

	hardStatePayload = 24 // term(8) + vote(8) + commit(8)
	entryHeader      = 16 // index(8) + term(8), data follows
	snapHeader       = 16 // index(8) + term(8), data follows

	// maxEntryData bounds one entry on disk, mirroring the wire cap so a
	// replicated entry can always be stored and vice versa.
	maxEntryData = 1 << 24
)

var (
	// ErrCorruptHardState reports an unreadable hard state file. Fatal by
	// design: defaulting to zero would forget a vote.
	ErrCorruptHardState = errors.New("raft: corrupt hard state file")
	// ErrCorruptLog reports damage before the final segment tail, where
	// torn writes cannot explain it.
	ErrCorruptLog = errors.New("raft: corrupt entry log")
	// ErrCorruptSnapshot reports an unreadable snapshot file. Fatal by
	// design: a snapshot is committed state, and silently dropping it
	// would resurrect a pre-snapshot world.
	ErrCorruptSnapshot = errors.New("raft: corrupt snapshot file")
	// ErrStorageClosed rejects use after Close.
	ErrStorageClosed = errors.New("raft: storage is closed")
	// ErrEntryTooLarge rejects an entry above the on-disk bound.
	ErrEntryTooLarge = errors.New("raft: entry data exceeds limit")
)

// OpenStorage opens (or initializes) a node's durable state under dir and
// replays it: the snapshot, the hard state, then every log segment in order
// with supersession, truncating a torn tail on the final segment exactly
// like the Phase 2 WAL. Entries the snapshot already covers are discarded
// during replay (a crash between saving a snapshot and compacting leaves
// them behind; the gap costs duplicate bytes, never data). It returns the
// recovered pieces; the caller seeds the in-memory core with them.
func OpenStorage(dir string, maxSegBytes int64) (*Storage, HardState, *Snapshot, []Entry, error) {
	if maxSegBytes <= 0 {
		maxSegBytes = DefaultMaxSegmentBytes
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, HardState{}, nil, nil, fmt.Errorf("raft: create dir: %w", err)
	}
	hs, err := readHardState(filepath.Join(dir, hardStateFile))
	if err != nil {
		return nil, HardState{}, nil, nil, err
	}
	snap, err := loadSnapshot(filepath.Join(dir, snapshotFile))
	if err != nil {
		return nil, HardState{}, nil, nil, err
	}

	nums, err := listRaftSegments(dir)
	if err != nil {
		return nil, HardState{}, nil, nil, err
	}
	s := &Storage{dir: dir, maxSegBytes: maxSegBytes, segMax: make(map[uint64]uint64)}
	if snap != nil {
		s.snapIndex = snap.Index
	}

	var entries []Entry
	for i, num := range nums {
		final := i == len(nums)-1
		segEntries, err := s.replaySegment(num, final)
		if err != nil {
			return nil, HardState{}, nil, nil, err
		}
		for _, e := range segEntries {
			if e.Index > s.segMax[num] {
				s.segMax[num] = e.Index // covered entries still locate their segment for compaction
			}
			if snap != nil && e.Index <= snap.Index {
				continue // folded into the snapshot
			}
			if snap != nil && len(entries) == 0 && e.Index != snap.Index+1 {
				return nil, HardState{}, nil, nil, fmt.Errorf("%w: first surviving entry %d does not follow snapshot index %d", ErrCorruptLog, e.Index, snap.Index)
			}
			entries, err = applyReplayed(entries, e)
			if err != nil {
				return nil, HardState{}, nil, nil, err
			}
		}
		s.segNums = append(s.segNums, num)
	}
	switch {
	case len(entries) > 0:
		s.lastIndex = entries[len(entries)-1].Index
	case snap != nil:
		s.lastIndex = snap.Index
	}

	if len(s.segNums) == 0 {
		if err := s.openFreshSegment(1); err != nil {
			return nil, HardState{}, nil, nil, err
		}
	} else {
		num := s.segNums[len(s.segNums)-1]
		f, err := os.OpenFile(s.segmentPath(num), os.O_RDWR, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
		if err != nil {
			return nil, HardState{}, nil, nil, fmt.Errorf("raft: open active segment: %w", err)
		}
		size, err := f.Seek(0, io.SeekEnd)
		if err != nil {
			_ = f.Close()
			return nil, HardState{}, nil, nil, fmt.Errorf("raft: seek active segment: %w", err)
		}
		s.active, s.activeNum, s.activeSize = f, num, size
	}
	return s, hs, snap, entries, nil
}

// applyReplayed folds one on-disk record into the logical log, honoring
// supersession: an index at or below the current tail truncates the suffix
// and takes its place. Gaps and records below the first surviving index are
// corruption, not protocol.
func applyReplayed(entries []Entry, e Entry) ([]Entry, error) {
	if len(entries) == 0 {
		return append(entries, e), nil
	}
	first := entries[0].Index
	last := entries[len(entries)-1].Index
	switch {
	case e.Index == last+1:
		return append(entries, e), nil
	case e.Index >= first && e.Index <= last:
		return append(entries[:e.Index-first], e), nil
	default:
		return nil, fmt.Errorf("%w: replayed index %d after tail %d", ErrCorruptLog, e.Index, last)
	}
}

// replaySegment reads one segment. Any unreadable block on the FINAL segment
// is a torn tail: the file is truncated to the last good offset and the scan
// stops cleanly. The same damage on an earlier segment cannot be a torn
// write and is corruption.
func (s *Storage) replaySegment(num uint64, final bool) ([]Entry, error) {
	path := s.segmentPath(num)
	f, err := os.OpenFile(path, os.O_RDWR, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return nil, fmt.Errorf("raft: open segment: %w", err)
	}
	defer func() { _ = f.Close() }()

	var entries []Entry
	for {
		offset, err := f.Seek(0, io.SeekCurrent)
		if err != nil {
			return nil, fmt.Errorf("raft: segment offset: %w", err)
		}
		typ, payload, rerr := persist.ReadBlock(f)
		if rerr == io.EOF {
			return entries, nil
		}
		if rerr != nil || typ != persist.BlockRaftEntry {
			if !final {
				return nil, fmt.Errorf("%w: segment %d at offset %d", ErrCorruptLog, num, offset)
			}
			if terr := f.Truncate(offset); terr != nil {
				return nil, fmt.Errorf("raft: truncate torn tail: %w", terr)
			}
			if serr := f.Sync(); serr != nil {
				return nil, fmt.Errorf("raft: sync after truncate: %w", serr)
			}
			return entries, nil
		}
		e, derr := decodeEntryPayload(payload)
		if derr != nil {
			if !final {
				return nil, fmt.Errorf("%w: segment %d at offset %d: %v", ErrCorruptLog, num, offset, derr)
			}
			if terr := f.Truncate(offset); terr != nil {
				return nil, fmt.Errorf("raft: truncate torn tail: %w", terr)
			}
			if serr := f.Sync(); serr != nil {
				return nil, fmt.Errorf("raft: sync after truncate: %w", serr)
			}
			return entries, nil
		}
		entries = append(entries, e)
	}
}

// AppendEntries writes a contiguous batch and fsyncs once. The first index
// may supersede the tail (conflict resolution); it may never leave a gap.
// The write is durable when this returns nil, which is what lets the runtime
// honor persist-before-send.
func (s *Storage) AppendEntries(entries []Entry) error {
	if len(entries) == 0 {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrStorageClosed
	}
	if entries[0].Index > s.lastIndex+1 || entries[0].Index < 1 {
		return fmt.Errorf("raft: append index %d leaves a gap after %d", entries[0].Index, s.lastIndex)
	}
	if s.snapIndex > 0 && entries[0].Index <= s.snapIndex {
		return fmt.Errorf("raft: append at %d at or below snapshot index %d", entries[0].Index, s.snapIndex)
	}
	for i, e := range entries {
		if i > 0 && e.Index != entries[i-1].Index+1 { //nolint:gosec // i > 0 guards the i-1 access, always in range
			return fmt.Errorf("raft: non-contiguous batch at %d", e.Index)
		}
		if len(e.Data) > maxEntryData {
			return fmt.Errorf("%w: %d bytes", ErrEntryTooLarge, len(e.Data))
		}
	}
	for _, e := range entries {
		if s.activeSize >= s.maxSegBytes {
			if err := s.rotate(); err != nil {
				return err
			}
		}
		n, err := persist.WriteBlock(s.active, persist.BlockRaftEntry, encodeEntryPayload(e))
		if err != nil {
			return fmt.Errorf("raft: append entry %d: %w", e.Index, err)
		}
		s.activeSize += int64(n)
		if e.Index > s.segMax[s.activeNum] {
			s.segMax[s.activeNum] = e.Index
		}
	}
	if err := s.active.Sync(); err != nil {
		return fmt.Errorf("raft: fsync entries: %w", err)
	}
	s.lastIndex = entries[len(entries)-1].Index
	return nil
}

// SaveHardState atomically replaces the hard state file (temp, fsync,
// rename, directory fsync). The runtime calls this before any message that
// depends on the state leaves the node.
func (s *Storage) SaveHardState(hs HardState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrStorageClosed
	}
	payload := make([]byte, hardStatePayload)
	binary.LittleEndian.PutUint64(payload[0:8], hs.Term)
	binary.LittleEndian.PutUint64(payload[8:16], uint64(hs.Vote))
	binary.LittleEndian.PutUint64(payload[16:24], hs.Commit)

	tmp := filepath.Join(s.dir, hardStateFile+".tmp")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("raft: create hard state temp: %w", err)
	}
	if _, err := persist.WriteBlock(f, persist.BlockRaftHardState, payload); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: write hard state: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: fsync hard state: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("raft: close hard state temp: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, hardStateFile)); err != nil {
		return fmt.Errorf("raft: replace hard state: %w", err)
	}
	return fsyncDir(s.dir)
}

// SaveSnapshot atomically replaces the durable snapshot (temp, fsync,
// rename, directory fsync) and advances the append position when the
// snapshot is ahead of the log, which is how an installed snapshot lands.
// Compacting the covered segments is a separate step on purpose: a crash
// between the two leaves extra segments behind, and replay discards what
// the snapshot already covers, so the gap costs bytes, never data.
func (s *Storage) SaveSnapshot(snap Snapshot) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrStorageClosed
	}
	if snap.Index == 0 {
		return errors.New("raft: snapshot at index zero")
	}
	payload := make([]byte, snapHeader+len(snap.Data))
	binary.LittleEndian.PutUint64(payload[0:8], snap.Index)
	binary.LittleEndian.PutUint64(payload[8:16], snap.Term)
	copy(payload[snapHeader:], snap.Data)

	tmp := filepath.Join(s.dir, snapshotFile+".tmp")
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("raft: create snapshot temp: %w", err)
	}
	if _, err := persist.WriteBlock(f, persist.BlockRaftSnapshot, payload); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: write snapshot: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return fmt.Errorf("raft: fsync snapshot: %w", err)
	}
	if err := f.Close(); err != nil {
		return fmt.Errorf("raft: close snapshot temp: %w", err)
	}
	if err := os.Rename(tmp, filepath.Join(s.dir, snapshotFile)); err != nil {
		return fmt.Errorf("raft: replace snapshot: %w", err)
	}
	if err := fsyncDir(s.dir); err != nil {
		return err
	}
	s.snapIndex = snap.Index
	if snap.Index > s.lastIndex {
		s.lastIndex = snap.Index
	}
	return nil
}

// CompactThrough deletes every non-active segment whose highest entry index
// is at or below index (only committed, snapshotted history is ever
// compacted). The active segment is never deleted: the 2.3 rule.
func (s *Storage) CompactThrough(index uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return ErrStorageClosed
	}
	kept := s.segNums[:0]
	for _, num := range s.segNums {
		if num != s.activeNum && s.segMax[num] <= index {
			if err := os.Remove(s.segmentPath(num)); err != nil {
				return fmt.Errorf("raft: remove segment %d: %w", num, err)
			}
			delete(s.segMax, num)
			continue
		}
		kept = append(kept, num)
	}
	s.segNums = kept
	return fsyncDir(s.dir)
}

// LastIndex returns the highest durable entry index.
func (s *Storage) LastIndex() uint64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastIndex
}

// Close fsyncs and releases the active segment.
func (s *Storage) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil
	}
	s.closed = true
	if err := s.active.Sync(); err != nil {
		_ = s.active.Close()
		return fmt.Errorf("raft: fsync on close: %w", err)
	}
	return s.active.Close()
}

// rotate seals the active segment and opens the next one.
func (s *Storage) rotate() error {
	if err := s.active.Sync(); err != nil {
		return fmt.Errorf("raft: fsync before rotate: %w", err)
	}
	if err := s.active.Close(); err != nil {
		return fmt.Errorf("raft: close before rotate: %w", err)
	}
	return s.openFreshSegment(s.activeNum + 1)
}

// openFreshSegment creates segment num and makes it active, making the
// directory entry durable.
func (s *Storage) openFreshSegment(num uint64) error {
	f, err := os.OpenFile(s.segmentPath(num), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("raft: create segment %d: %w", num, err)
	}
	if err := fsyncDir(s.dir); err != nil {
		_ = f.Close()
		return err
	}
	s.active, s.activeNum, s.activeSize = f, num, 0
	s.segNums = append(s.segNums, num)
	return nil
}

func (s *Storage) segmentPath(num uint64) string {
	return filepath.Join(s.dir, fmt.Sprintf("%s%06d%s", segPrefix, num, segSuffix))
}

// listRaftSegments returns the segment numbers under dir in ascending order.
func listRaftSegments(dir string) ([]uint64, error) {
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("raft: list dir: %w", err)
	}
	var nums []uint64
	for _, it := range items {
		name := it.Name()
		if it.IsDir() || !strings.HasPrefix(name, segPrefix) || !strings.HasSuffix(name, segSuffix) {
			continue
		}
		mid := strings.TrimSuffix(strings.TrimPrefix(name, segPrefix), segSuffix)
		n, perr := strconv.ParseUint(mid, 10, 64)
		if perr != nil || n == 0 {
			continue // foreign file that happens to match loosely
		}
		nums = append(nums, n)
	}
	sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
	return nums, nil
}

// readHardState loads the hard state file. Absent means a fresh node (zero
// state); unreadable or malformed means fatal, never a default.
func readHardState(path string) (HardState, error) {
	f, err := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if errors.Is(err, os.ErrNotExist) {
		return HardState{}, nil
	}
	if err != nil {
		return HardState{}, fmt.Errorf("raft: open hard state: %w", err)
	}
	defer func() { _ = f.Close() }()
	typ, payload, err := persist.ReadBlock(f)
	if err != nil || typ != persist.BlockRaftHardState || len(payload) != hardStatePayload {
		return HardState{}, ErrCorruptHardState
	}
	return HardState{
		Term:   binary.LittleEndian.Uint64(payload[0:8]),
		Vote:   cluster.NodeID(binary.LittleEndian.Uint64(payload[8:16])),
		Commit: binary.LittleEndian.Uint64(payload[16:24]),
	}, nil
}

// loadSnapshot reads the durable snapshot. Absent means none yet;
// unreadable or malformed means fatal, never a silent nil.
func loadSnapshot(path string) (*Snapshot, error) {
	f, err := os.Open(path) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("raft: open snapshot: %w", err)
	}
	defer func() { _ = f.Close() }()
	typ, payload, err := persist.ReadBlock(f)
	if err != nil || typ != persist.BlockRaftSnapshot || len(payload) < snapHeader {
		return nil, ErrCorruptSnapshot
	}
	snap := &Snapshot{
		Index: binary.LittleEndian.Uint64(payload[0:8]),
		Term:  binary.LittleEndian.Uint64(payload[8:16]),
	}
	if snap.Index == 0 {
		return nil, ErrCorruptSnapshot
	}
	if len(payload) > snapHeader {
		snap.Data = make([]byte, len(payload)-snapHeader)
		copy(snap.Data, payload[snapHeader:])
	}
	return snap, nil
}

func encodeEntryPayload(e Entry) []byte {
	buf := make([]byte, entryHeader+len(e.Data))
	binary.LittleEndian.PutUint64(buf[0:8], e.Index)
	binary.LittleEndian.PutUint64(buf[8:16], e.Term)
	copy(buf[entryHeader:], e.Data)
	return buf
}

func decodeEntryPayload(payload []byte) (Entry, error) {
	if len(payload) < entryHeader {
		return Entry{}, errors.New("raft: short entry payload")
	}
	e := Entry{
		Index: binary.LittleEndian.Uint64(payload[0:8]),
		Term:  binary.LittleEndian.Uint64(payload[8:16]),
	}
	if e.Index == 0 {
		return Entry{}, errors.New("raft: entry index zero")
	}
	if len(payload) > entryHeader {
		e.Data = make([]byte, len(payload)-entryHeader)
		copy(e.Data, payload[entryHeader:])
	}
	return e, nil
}

// fsyncDir makes directory mutations (create, rename, remove) durable.
func fsyncDir(dir string) error {
	d, err := os.Open(dir) //nolint:gosec // dir is caller-provided data dir, not untrusted input
	if err != nil {
		return fmt.Errorf("raft: open dir for fsync: %w", err)
	}
	defer func() { _ = d.Close() }()
	if err := d.Sync(); err != nil {
		return fmt.Errorf("raft: fsync dir: %w", err)
	}
	return nil
}
