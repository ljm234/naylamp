package main

import (
	"encoding/binary"
	"errors"
	"math"
	"path/filepath"
	"testing"

	"naylamp/engine/raft"
)

func upsertPayload(id uint64, vec []float32) []byte {
	buf := make([]byte, 1+8+4+4*len(vec))
	buf[0] = 1
	binary.LittleEndian.PutUint64(buf[1:9], id)
	binary.LittleEndian.PutUint32(buf[9:13], uint32(len(vec))) //nolint:gosec // a fixed small dimension in a test
	for i, v := range vec {
		binary.LittleEndian.PutUint32(buf[13+4*i:17+4*i], math.Float32bits(v))
	}
	return buf
}

func deletePayload(id uint64) []byte {
	buf := make([]byte, 9)
	buf[0] = 2
	binary.LittleEndian.PutUint64(buf[1:9], id)
	return buf
}

// writeSrc lays down a clean source log the injector reads, the same shape a
// stopped replica leaves: contiguous entries from index 1, all committed.
func writeSrc(t *testing.T, dir string, cmds [][]byte) {
	t.Helper()
	s, _, _, _, err := raft.OpenStorage(dir, 0)
	if err != nil {
		t.Fatalf("open src: %v", err)
	}
	entries := make([]raft.Entry, len(cmds))
	for i, d := range cmds {
		entries[i] = raft.Entry{Index: uint64(i + 1), Term: 1, Data: d} //nolint:gosec // small test index
	}
	if aerr := s.AppendEntries(entries); aerr != nil {
		t.Fatalf("append: %v", aerr)
	}
	if herr := s.SaveHardState(raft.HardState{Term: 1, Commit: uint64(len(cmds))}); herr != nil { //nolint:gosec // small test index
		t.Fatalf("hard state: %v", herr)
	}
	if cerr := s.Close(); cerr != nil {
		t.Fatalf("close: %v", cerr)
	}
}

// readSrc reads a log back the way the injector does.
func readSrc(t *testing.T, dir string) ([]raft.Entry, raft.HardState) {
	t.Helper()
	s, hs, snap, entries, err := raft.OpenStorage(dir, 0)
	if err != nil {
		t.Fatalf("read src: %v", err)
	}
	_ = s.Close()
	if snap != nil {
		t.Fatalf("unexpected snapshot in src")
	}
	return entries, hs
}

func workload() [][]byte {
	return [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
		upsertPayload(3, []float32{0, 0, 1}),
		deletePayload(2),
		upsertPayload(5, []float32{1, 1, 1}),
		upsertPayload(5, []float32{1, 1, 1}), // a legitimate duplicate the client re-emitted
	}
}

// TestFaultlogPhantom checks the phantom adds one committed entry carrying the
// never-written id, with the commit index raised to cover it.
func TestFaultlogPhantom(t *testing.T) {
	src := t.TempDir()
	writeSrc(t, src, workload())
	entries, hs := readSrc(t, src)
	out := filepath.Join(t.TempDir(), "phantom")

	if err := injectPhantom(out, entries, hs, 900001); err != nil {
		t.Fatalf("inject phantom: %v", err)
	}
	got, gotHS := readSrc(t, out)
	if len(got) != len(entries)+1 {
		t.Fatalf("phantom added %d entries, want 1", len(got)-len(entries))
	}
	last := got[len(got)-1]
	if id := binary.LittleEndian.Uint64(last.Data[1:9]); id != 900001 {
		t.Fatalf("phantom entry id=%d, want 900001", id)
	}
	if gotHS.Commit != last.Index {
		t.Fatalf("commit=%d does not cover the phantom at %d", gotHS.Commit, last.Index)
	}
}

// TestFaultlogMissing checks the missing defect lowers the commit below every
// committed copy of the final write, so id 5 is no longer committed even though
// the client re-emitted it.
func TestFaultlogMissing(t *testing.T) {
	src := t.TempDir()
	writeSrc(t, src, workload())
	entries, hs := readSrc(t, src)
	out := filepath.Join(t.TempDir(), "missing")

	if err := injectMissing(out, entries, hs); err != nil {
		t.Fatalf("inject missing: %v", err)
	}
	_, gotHS := readSrc(t, out)
	// The two final entries are both id 5; commit must fall below the earlier one.
	if gotHS.Commit >= entries[len(entries)-2].Index {
		t.Fatalf("commit=%d did not drop both copies of the final write", gotHS.Commit)
	}
	// Every entry still committed must be an id other than 5.
	for _, e := range entries {
		if e.Index <= gotHS.Commit && len(e.Data) > 0 {
			if id := binary.LittleEndian.Uint64(e.Data[1:9]); id == 5 {
				t.Fatalf("id 5 is still committed at index %d after the missing defect", e.Index)
			}
		}
	}
}

// TestFaultlogCorrupt checks the corrupt defect makes the log unreadable with the
// raft corruption error, not a silent torn-tail truncation.
func TestFaultlogCorrupt(t *testing.T) {
	src := t.TempDir()
	writeSrc(t, src, workload())
	entries, hs := readSrc(t, src)
	out := filepath.Join(t.TempDir(), "corrupt")

	if err := injectCorrupt(out, entries, hs); err != nil {
		t.Fatalf("inject corrupt: %v", err)
	}
	if _, _, _, _, err := raft.OpenStorage(out, 0); !errors.Is(err, raft.ErrCorruptLog) {
		t.Fatalf("reopening the corrupt log returned %v, want ErrCorruptLog", err)
	}
}

// TestFaultlogDup checks the duplicate defect appends a byte-identical copy of the
// last committed upsert and commits it, the negative control.
func TestFaultlogDup(t *testing.T) {
	src := t.TempDir()
	writeSrc(t, src, workload())
	entries, hs := readSrc(t, src)
	out := filepath.Join(t.TempDir(), "dup")

	if err := injectDup(out, entries, hs); err != nil {
		t.Fatalf("inject dup: %v", err)
	}
	got, gotHS := readSrc(t, out)
	if len(got) != len(entries)+1 {
		t.Fatalf("dup added %d entries, want 1", len(got)-len(entries))
	}
	last := got[len(got)-1]
	if id := binary.LittleEndian.Uint64(last.Data[1:9]); id != 5 {
		t.Fatalf("duplicate id=%d, want 5 (the last committed upsert)", id)
	}
	if gotHS.Commit != last.Index {
		t.Fatalf("commit=%d does not cover the duplicate at %d", gotHS.Commit, last.Index)
	}
}
