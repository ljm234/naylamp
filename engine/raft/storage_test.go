package raft

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"naylamp/engine/cluster"
)

func dataEnt(index, term uint64, data string) Entry {
	return Entry{Index: index, Term: term, Data: []byte(data)}
}

func openForTest(t *testing.T, dir string) (*Storage, HardState, []Entry) {
	t.Helper()
	s, hs, entries, err := OpenStorage(dir, 256) // tiny segments force rotation
	if err != nil {
		t.Fatalf("open storage: %v", err)
	}
	return s, hs, entries
}

func TestStorage_HardStateRoundTripAndFatalCorruption(t *testing.T) {
	dir := t.TempDir()
	s, hs, entries := openForTest(t, dir)
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
	s2, hs2, _ := openForTest(t, dir)
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
	if _, _, _, err := OpenStorage(dir, 256); !errors.Is(err, ErrCorruptHardState) {
		t.Fatalf("corrupt hard state accepted: %v", err)
	}
}

func TestStorage_AppendReplayAcrossRotation(t *testing.T) {
	dir := t.TempDir()
	s, _, _ := openForTest(t, dir)
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
	s2, _, got := openForTest(t, dir)
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
	s, _, _ := openForTest(t, dir)
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
	_, _, got := func() (*Storage, HardState, []Entry) { return openForTest(t, dir) }()
	if len(got) != 4 {
		t.Fatalf("replayed %d entries, want 4: %+v", len(got), got)
	}
	if string(got[2].Data) != "C2" || got[2].Term != 2 || string(got[3].Data) != "D2" {
		t.Fatalf("supersession lost: %+v", got)
	}
}

func TestStorage_TornTailTruncatedAndAppendContinues(t *testing.T) {
	dir := t.TempDir()
	s, _, _ := openForTest(t, dir)
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

	s2, _, got := openForTest(t, dir)
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
	_, _, got2 := func() (*Storage, HardState, []Entry) { return openForTest(t, dir) }()
	if len(got2) != 3 || string(got2[2].Data) != "after-tear" {
		t.Fatalf("post-tear append lost: %+v", got2)
	}
}

func TestStorage_CorruptionBeforeFinalSegmentIsFatal(t *testing.T) {
	dir := t.TempDir()
	s, _, _ := openForTest(t, dir)
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
	if _, _, _, err := OpenStorage(dir, 256); !errors.Is(err, ErrCorruptLog) {
		t.Fatalf("mid-log corruption accepted: %v", err)
	}
}

func TestStorage_CompactThroughDeletesCoveredSegmentsOnly(t *testing.T) {
	dir := t.TempDir()
	s, _, _ := openForTest(t, dir)
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
	_, _, got := func() (*Storage, HardState, []Entry) { return openForTest(t, dir) }()
	if len(got) == 0 || got[0].Index <= cover {
		t.Fatalf("replay after compaction wrong: first=%+v", got[:1])
	}
}
