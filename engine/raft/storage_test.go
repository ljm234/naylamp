package raft

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/persist"
)

func dataEnt(index, term uint64, data string) Entry {
	return Entry{Index: index, Term: term, Data: []byte(data)}
}

func openForTest(t *testing.T, dir string) (*Storage, HardState, *Snapshot, []Entry) {
	t.Helper()
	s, hs, snap, entries, err := OpenStorage(dir, 256) // tiny segments force rotation
	if err != nil {
		t.Fatalf("open storage: %v", err)
	}
	return s, hs, snap, entries
}

func TestStorage_HardStateRoundTripAndFatalCorruption(t *testing.T) {
	dir := t.TempDir()
	s, hs, _, entries := openForTest(t, dir)
	if hs != (HardState{}) || len(entries) != 0 {
		t.Fatalf("fresh node not zero: %+v %v", hs, entries)
	}
	want := HardState{Term: 7, Vote: cluster.NodeID(3), Commit: 42}
	if err := s.SaveHardState(want); err != nil {
		t.Fatalf("save: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	s2, hs2, _, _ := openForTest(t, dir)
	if hs2 != want {
		t.Fatalf("reload = %+v, want %+v", hs2, want)
	}
	if err := s2.Close(); err != nil {
		t.Fatalf("close2: %v", err)
	}
	// Corrupt one byte: opening must FAIL, never default to zero (a node
	// that forgets its vote can vote twice).
	path := filepath.Join(dir, hardStateFile)
	raw, err := os.ReadFile(path) //nolint:gosec // test-controlled path
	if err != nil {
		t.Fatalf("read hs: %v", err)
	}
	raw[len(raw)/2] ^= 0xFF
	if err := os.WriteFile(path, raw, 0o600); err != nil { //nolint:gosec // test-controlled path
		t.Fatalf("write hs: %v", err)
	}
	if _, _, _, _, err := OpenStorage(dir, 256); !errors.Is(err, ErrCorruptHardState) {
		t.Fatalf("corrupt hard state accepted: %v", err)
	}
}

func TestStorage_AppendReplayAcrossRotation(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	var want []Entry
	for i := uint64(1); i <= 30; i++ {
		e := dataEnt(i, 1+i/10, "payload-padding-to-force-rotation")
		want = append(want, e)
	}
	if err := s.AppendEntries(want[:10]); err != nil {
		t.Fatalf("append 1: %v", err)
	}
	if err := s.AppendEntries(want[10:]); err != nil {
		t.Fatalf("append 2: %v", err)
	}
	if s.LastIndex() != 30 {
		t.Fatalf("last = %d, want 30", s.LastIndex())
	}
	if len(s.segNums) < 3 {
		t.Fatalf("expected rotation, got %d segments", len(s.segNums))
	}
	// Gaps are refused.
	if err := s.AppendEntries([]Entry{dataEnt(40, 5, "gap")}); err == nil {
		t.Fatalf("gap accepted")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	s2, _, _, got := openForTest(t, dir)
	defer func() { _ = s2.Close() }()
	if len(got) != len(want) {
		t.Fatalf("replayed %d entries, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i].Index != want[i].Index || got[i].Term != want[i].Term || string(got[i].Data) != string(want[i].Data) {
			t.Fatalf("entry %d mismatch: %+v vs %+v", i, got[i], want[i])
		}
	}
}

func TestStorage_SupersessionOnReplay(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	if err := s.AppendEntries([]Entry{
		dataEnt(1, 1, "a"), dataEnt(2, 1, "b"), dataEnt(3, 1, "c"),
		dataEnt(4, 1, "d"), dataEnt(5, 1, "e"),
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// Conflict resolution appends new entries under existing indices.
	if err := s.AppendEntries([]Entry{dataEnt(3, 2, "C2"), dataEnt(4, 2, "D2")}); err != nil {
		t.Fatalf("supersede: %v", err)
	}
	if s.LastIndex() != 4 {
		t.Fatalf("last after supersede = %d, want 4", s.LastIndex())
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	_, _, _, got := func() (*Storage, HardState, *Snapshot, []Entry) { return openForTest(t, dir) }()
	if len(got) != 4 {
		t.Fatalf("replayed %d entries, want 4: %+v", len(got), got)
	}
	if string(got[2].Data) != "C2" || got[2].Term != 2 || string(got[3].Data) != "D2" {
		t.Fatalf("supersession lost: %+v", got)
	}
}

func TestStorage_TornTailTruncatedAndAppendContinues(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	if err := s.AppendEntries([]Entry{dataEnt(1, 1, "keep-1"), dataEnt(2, 1, "keep-2")}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	activePath := s.segmentPath(s.activeNum)
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	// Simulate a torn write: garbage at the tail of the final segment.
	f, err := os.OpenFile(activePath, os.O_APPEND|os.O_WRONLY, 0o600) //nolint:gosec // test-controlled path
	if err != nil {
		t.Fatalf("open for garbage: %v", err)
	}
	if _, err := f.Write([]byte{0xDE, 0xAD, 0xBE}); err != nil {
		t.Fatalf("write garbage: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close garbage: %v", err)
	}

	s2, _, _, got := openForTest(t, dir)
	if len(got) != 2 || string(got[1].Data) != "keep-2" {
		t.Fatalf("torn tail recovery lost data: %+v", got)
	}
	// The tail was truncated, so appends land cleanly.
	if err := s2.AppendEntries([]Entry{dataEnt(3, 1, "after-tear")}); err != nil {
		t.Fatalf("append after tear: %v", err)
	}
	if err := s2.Close(); err != nil {
		t.Fatalf("close2: %v", err)
	}
	_, _, _, got2 := func() (*Storage, HardState, *Snapshot, []Entry) { return openForTest(t, dir) }()
	if len(got2) != 3 || string(got2[2].Data) != "after-tear" {
		t.Fatalf("post-tear append lost: %+v", got2)
	}
}

func TestStorage_CorruptionBeforeFinalSegmentIsFatal(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	var batch []Entry
	for i := uint64(1); i <= 30; i++ {
		batch = append(batch, dataEnt(i, 1, "payload-padding-to-force-rotation"))
	}
	if err := s.AppendEntries(batch); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if len(s.segNums) < 2 {
		t.Fatalf("need rotation for this test, got %d segments", len(s.segNums))
	}
	firstSeg := s.segmentPath(s.segNums[0])
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	raw, err := os.ReadFile(firstSeg) //nolint:gosec // test-controlled path
	if err != nil {
		t.Fatalf("read seg: %v", err)
	}
	raw[len(raw)/2] ^= 0xFF
	if err := os.WriteFile(firstSeg, raw, 0o600); err != nil { //nolint:gosec // test-controlled path
		t.Fatalf("write seg: %v", err)
	}
	if _, _, _, _, err := OpenStorage(dir, 256); !errors.Is(err, ErrCorruptLog) {
		t.Fatalf("mid-log corruption accepted: %v", err)
	}
}

func TestStorage_CompactThroughDeletesCoveredSegmentsOnly(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	var batch []Entry
	for i := uint64(1); i <= 30; i++ {
		batch = append(batch, dataEnt(i, 1, "payload-padding-to-force-rotation"))
	}
	if err := s.AppendEntries(batch); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if len(s.segNums) < 3 {
		t.Fatalf("need >=3 segments, got %d", len(s.segNums))
	}
	firstSeg := s.segmentPath(s.segNums[0])
	activeSeg := s.segmentPath(s.activeNum)
	cover := s.segMax[s.segNums[0]] // covers exactly the first segment
	if err := s.CompactThrough(cover); err != nil {
		t.Fatalf("compact: %v", err)
	}
	if _, err := os.Stat(firstSeg); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("covered segment survived: %v", err)
	}
	if _, err := os.Stat(activeSeg); err != nil {
		t.Fatalf("active segment touched: %v", err)
	}
	// Compacting far beyond everything still never deletes the active one.
	if err := s.CompactThrough(999); err != nil {
		t.Fatalf("compact all: %v", err)
	}
	if _, err := os.Stat(activeSeg); err != nil {
		t.Fatalf("active deleted by full compaction: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	// Replay after compaction starts at the first surviving entry.
	_, _, _, got := func() (*Storage, HardState, *Snapshot, []Entry) { return openForTest(t, dir) }()
	if len(got) == 0 || got[0].Index <= cover {
		t.Fatalf("replay after compaction wrong: first=%+v", got[:1])
	}
}

func TestStorage_SnapshotRoundTripAndFatalCorruption(t *testing.T) {
	dir := t.TempDir()
	s, _, snap, _ := openForTest(t, dir)
	if snap != nil {
		t.Fatalf("fresh node has a snapshot: %+v", snap)
	}
	want := Snapshot{Index: 5, Term: 2, Data: []byte("engine-state")}
	if err := s.SaveSnapshot(want); err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	if s.LastIndex() != 5 {
		t.Fatalf("snapshot ahead of log did not advance tail: %d", s.LastIndex())
	}
	// Appends below or at the snapshot index are refused: that history is
	// committed and immutable.
	if err := s.AppendEntries([]Entry{dataEnt(3, 1, "stale")}); err == nil {
		t.Fatalf("append below snapshot accepted")
	}
	if err := s.AppendEntries([]Entry{dataEnt(6, 2, "next")}); err != nil {
		t.Fatalf("append after snapshot: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	s2, _, snap2, entries := openForTest(t, dir)
	if snap2 == nil || snap2.Index != 5 || snap2.Term != 2 || string(snap2.Data) != "engine-state" {
		t.Fatalf("snapshot round trip failed: %+v", snap2)
	}
	if len(entries) != 1 || entries[0].Index != 6 {
		t.Fatalf("post-snapshot entries wrong: %+v", entries)
	}
	if err := s2.Close(); err != nil {
		t.Fatalf("close2: %v", err)
	}
	// Corrupt one byte: opening must FAIL, never silently drop the snapshot.
	path := filepath.Join(dir, snapshotFile)
	raw, err := os.ReadFile(path) //nolint:gosec // test-controlled path
	if err != nil {
		t.Fatalf("read snap: %v", err)
	}
	raw[len(raw)/2] ^= 0xFF
	if err := os.WriteFile(path, raw, 0o600); err != nil { //nolint:gosec // test-controlled path
		t.Fatalf("write snap: %v", err)
	}
	if _, _, _, _, err := OpenStorage(dir, 256); !errors.Is(err, ErrCorruptSnapshot) {
		t.Fatalf("corrupt snapshot accepted: %v", err)
	}
}

func TestStorage_CrashBetweenSnapshotAndCompactIsTolerated(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	var batch []Entry
	for i := uint64(1); i <= 10; i++ {
		batch = append(batch, dataEnt(i, 1, "payload-padding-to-force-rotation"))
	}
	if err := s.AppendEntries(batch); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if err := s.SaveSnapshot(Snapshot{Index: 7, Term: 1, Data: []byte("st")}); err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	// Crash HERE: no CompactThrough. The covered entries are still on disk.
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	s2, _, snap, entries := openForTest(t, dir)
	if snap == nil || snap.Index != 7 {
		t.Fatalf("snapshot lost: %+v", snap)
	}
	if len(entries) != 3 || entries[0].Index != 8 || entries[2].Index != 10 {
		t.Fatalf("covered entries not discarded on replay: %+v", entries)
	}
	if s2.LastIndex() != 10 {
		t.Fatalf("tail wrong after tolerant replay: %d", s2.LastIndex())
	}
	// The deferred compaction still works and spares the active segment.
	if err := s2.CompactThrough(7); err != nil {
		t.Fatalf("compact: %v", err)
	}
	if err := s2.AppendEntries([]Entry{dataEnt(11, 1, "after")}); err != nil {
		t.Fatalf("append after compact: %v", err)
	}
	if err := s2.Close(); err != nil {
		t.Fatalf("close2: %v", err)
	}
}

func TestStorage_LaterSnapshotSupersedesEarlier(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	// A snapshot at index zero captures nothing and is refused.
	if err := s.SaveSnapshot(Snapshot{Index: 0, Term: 1}); err == nil {
		t.Fatalf("snapshot at index zero accepted")
	}
	var batch []Entry
	for i := uint64(1); i <= 12; i++ {
		batch = append(batch, dataEnt(i, 1, "payload-padding-to-force-rotation"))
	}
	if err := s.AppendEntries(batch); err != nil {
		t.Fatalf("seed: %v", err)
	}
	// A first snapshot, then a later one that supersedes it: the second
	// atomically replaces the file and advances the append floor.
	if err := s.SaveSnapshot(Snapshot{Index: 4, Term: 1, Data: []byte("s4")}); err != nil {
		t.Fatalf("first snapshot: %v", err)
	}
	if err := s.SaveSnapshot(Snapshot{Index: 9, Term: 1, Data: []byte("s9")}); err != nil {
		t.Fatalf("second snapshot: %v", err)
	}
	// The floor now tracks the latest snapshot: index 9 is covered history.
	if err := s.AppendEntries([]Entry{dataEnt(9, 1, "stale")}); err == nil {
		t.Fatalf("append at superseded snapshot index accepted")
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	// Only the latest snapshot survives on disk; replay drops all it covers.
	s2, _, snap, entries := openForTest(t, dir)
	defer func() { _ = s2.Close() }()
	if snap == nil || snap.Index != 9 || string(snap.Data) != "s9" {
		t.Fatalf("latest snapshot not recovered: %+v", snap)
	}
	if len(entries) != 3 || entries[0].Index != 10 || entries[2].Index != 12 {
		t.Fatalf("entries after superseding snapshot wrong: %+v", entries)
	}
	if s2.LastIndex() != 12 {
		t.Fatalf("tail wrong after supersession: %d", s2.LastIndex())
	}
}

func TestStorage_GapBetweenSnapshotAndLogIsFatal(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	if err := s.SaveSnapshot(Snapshot{Index: 3, Term: 1, Data: []byte("st")}); err != nil {
		t.Fatalf("save snapshot: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	// Hand-craft a segment whose first surviving entry skips the index right
	// after the snapshot: replay must refuse the gap as corruption, because
	// silently accepting it would fabricate a hole in committed history.
	f, err := os.OpenFile(filepath.Join(dir, "raft-000002.log"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600) //nolint:gosec // test-controlled path
	if err != nil {
		t.Fatalf("craft segment: %v", err)
	}
	if _, werr := persist.WriteBlock(f, persist.BlockRaftEntry, encodeEntryPayload(dataEnt(5, 1, "gap"))); werr != nil {
		t.Fatalf("write crafted entry: %v", werr)
	}
	if cerr := f.Close(); cerr != nil {
		t.Fatalf("close crafted: %v", cerr)
	}
	if _, _, _, _, oerr := OpenStorage(dir, 256); !errors.Is(oerr, ErrCorruptLog) {
		t.Fatalf("gap after snapshot accepted: %v", oerr)
	}
}
