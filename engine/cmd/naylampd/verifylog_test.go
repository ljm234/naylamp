package main

import (
	"encoding/binary"
	"math"
	"os"
	"path/filepath"
	"testing"

	"naylamp/engine/raft"
)

// upsertPayload and deletePayload hand-build the command byte layout the state
// machine decodes (op, id, then a count and float bits for an upsert), so a test
// can lay down a committed log without driving a whole cluster.
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

// writeCommittedLog lays down a durable log whose entries carry cmds at indices
// 1..len, all committed, so verifyLog reads them back as the committed record.
func writeCommittedLog(t *testing.T, dir string, cmds [][]byte) {
	t.Helper()
	s, _, _, _, err := raft.OpenStorage(dir, 0)
	if err != nil {
		t.Fatalf("open storage: %v", err)
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

// faithfulWorkload is the reference workload: three live ids, one put-then-del,
// and a final live-id put, with a trailing idempotent duplicate that must not
// change the verdict.
func faithfulWorkload() (manifest, [][]byte) {
	man := manifest{
		seen: map[uint64]bool{1: true, 2: true, 3: true, 5: true},
		live: map[uint64][]float32{1: {1, 0, 0}, 3: {0, 0, 1}, 5: {1, 1, 1}},
	}
	cmds := [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
		upsertPayload(3, []float32{0, 0, 1}),
		deletePayload(2),
		upsertPayload(5, []float32{1, 1, 1}),
		upsertPayload(5, []float32{1, 1, 1}), // idempotent duplicate: still faithful
	}
	return man, cmds
}

func TestVerifyLog_Faithful(t *testing.T) {
	cfg, err := configFromFlags(1, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	man, cmds := faithfulWorkload()
	dir := t.TempDir()
	writeCommittedLog(t, dir, cmds)

	ok, reasons := verifyLog(dir, 1, cfg, 3, man)
	if !ok {
		t.Fatalf("a faithful log with an idempotent duplicate was flagged: %v", reasons)
	}
}

func TestVerifyLog_CatchesDefects(t *testing.T) {
	cfg, err := configFromFlags(1, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	man, base := faithfulWorkload()

	cases := []struct {
		name string
		cmds [][]byte
	}{
		{
			// a committed id the workload never wrote
			name: "phantom",
			cmds: append(append([][]byte{}, base...), upsertPayload(999, []float32{9, 9, 9})),
		},
		{
			// the final acked id absent from the committed record
			name: "missing",
			cmds: base[:4], // put1, put2, put3, del2: id 5 never appears
		},
		{
			// a live id present but replaying to the wrong value
			name: "wrong-value",
			cmds: replaceFirst(base, upsertPayload(1, []float32{7, 7, 7})),
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			writeCommittedLog(t, dir, c.cmds)
			ok, _ := verifyLog(dir, 1, cfg, 3, man)
			if ok {
				t.Fatalf("%s defect was not caught; verifyLog reported faithful", c.name)
			}
		})
	}
}

// TestVerifyLog_CorruptOpen proves that a log that cannot be opened is a
// not-faithful verdict, not a crash: a corrupt hard state is one such case.
func TestVerifyLog_CorruptOpen(t *testing.T) {
	cfg, err := configFromFlags(1, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	man, cmds := faithfulWorkload()
	dir := t.TempDir()
	writeCommittedLog(t, dir, cmds)

	// Overwrite the hard state with bytes that are not a valid block, so it no
	// longer reads and OpenNode reports a corrupt hard state.
	if werr := os.WriteFile(filepath.Join(dir, "raft-hardstate"), []byte("not a hard state block"), 0o600); werr != nil {
		t.Fatalf("overwrite hard state: %v", werr)
	}

	ok, reasons := verifyLog(dir, 1, cfg, 3, man)
	if ok {
		t.Fatal("a corrupt hard state was reported faithful")
	}
	if len(reasons) == 0 {
		t.Fatal("expected a not-faithful reason for the corrupt open")
	}
}

// TestVerifyLog_RefusesSnapshot proves the audit refuses to run against a
// compacted log rather than attest a partial view.
func TestVerifyLog_RefusesSnapshot(t *testing.T) {
	cfg, err := configFromFlags(1, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	man, cmds := faithfulWorkload()
	dir := t.TempDir()
	writeCommittedLog(t, dir, cmds)
	if werr := os.WriteFile(filepath.Join(dir, "raft-snapshot"), []byte("x"), 0o600); werr != nil {
		t.Fatalf("write snapshot marker: %v", werr)
	}

	ok, _ := verifyLog(dir, 1, cfg, 3, man)
	if ok {
		t.Fatal("the audit ran against a compacted log instead of refusing")
	}
}

func replaceFirst(base [][]byte, first []byte) [][]byte {
	out := append([][]byte{}, base...)
	out[0] = first
	return out
}
