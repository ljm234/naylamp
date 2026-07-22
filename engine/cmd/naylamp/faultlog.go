package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"naylamp/engine/raft"
)

// faultlog is the red half of the log-fidelity gate: it reads a clean cold copy
// of a replica's durable state and writes a NEW directory that carries one
// deliberate defect, so verify-log can be shown to catch each one. It lives in
// the demo binary, never in naylampd, because a tool that fabricates corruption
// has no place in the production daemon. It never mutates its source: the source
// is read once and the mutated log is built fresh in the output directory, which
// keeps the "operate on a copy, and inject into a copy of that copy" rule
// mechanical.
//
// The four modes and the verdict each is meant to draw from verify-log:
//
//	phantom  a committed upsert for an id the workload never wrote. verify-log
//	         must red on "phantom id".
//	missing  the last committed command dropped by lowering the commit index below
//	         it, so an acked id loses its final op. verify-log must red on "acked
//	         id ... missing" and a replay mismatch.
//	corrupt  the log rebuilt into several small segments with a byte flipped inside
//	         a NON-final segment, where a raft replay treats the damage as real
//	         corruption (ErrCorruptLog) rather than a torn tail. verify-log must red
//	         on "corrupt-open". A single-segment flip would be swallowed as a torn
//	         tail and is deliberately not used.
//	dup      a byte-identical copy of the last committed upsert appended and
//	         committed. This is the NEGATIVE control: an idempotent duplicate is
//	         expected under the log-fidelity semantics, so verify-log must stay
//	         GREEN. It is here to prove the checker does not false-red on a
//	         legitimate re-issue.
//
// The command layout it needs is minimal and stable: the id sits at bytes [1:9]
// of a command payload for every op, and an upsert is any command longer than the
// fixed op+id header (it carries a vector). Nothing else about the payload is
// read, so the tool never decodes or re-encodes a vector.
const (
	// cmdHeaderLen is the op byte plus the 8-byte id every command begins with; a
	// longer payload is an upsert carrying a vector.
	cmdHeaderLen = 1 + 8
	// tinySegBytes rebuilds the corrupt-mode log with at most one entry per
	// segment: it is smaller than the smallest entry block, so every entry after
	// the first rotates the segment and there is always a non-final segment to
	// damage.
	tinySegBytes = 16
	// corruptOffset is the first payload byte of a block (past the 12-byte header:
	// magic, version, type, length). Flipping it changes the payload, so the block
	// CRC no longer matches and the read fails, which on a non-final segment is
	// reported as log corruption.
	corruptOffset = 12
)

func runFaultlog(args []string) {
	fs := flag.NewFlagSet("faultlog", flag.ExitOnError)
	var mode, src, out string
	var phantomID uint64
	fs.StringVar(&mode, "mode", "", "defect to inject: phantom, missing, corrupt, or dup (required)")
	fs.StringVar(&src, "src", "", "source data directory, a clean cold copy (required, read only, never mutated)")
	fs.StringVar(&out, "out", "", "output data directory to create with the defect (required, must not already exist)")
	fs.Uint64Var(&phantomID, "phantom-id", 0, "the never-written id to inject for -mode phantom (required for phantom)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylamp faultlog -mode MODE -src DIR -out DIR [-phantom-id N]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "reads a clean copy and writes a NEW directory carrying one deliberate log defect, for the red of the log-fidelity gate")
	}
	_ = fs.Parse(args)

	if mode == "" || src == "" || out == "" {
		fmt.Fprintln(os.Stderr, "faultlog: -mode, -src, and -out are required")
		fs.Usage()
		os.Exit(2)
	}
	if mode == "phantom" && phantomID == 0 {
		fmt.Fprintln(os.Stderr, "faultlog: -mode phantom requires a nonzero -phantom-id")
		os.Exit(2)
	}
	if _, err := os.Stat(out); err == nil {
		fmt.Fprintf(os.Stderr, "faultlog: -out %s already exists; give a fresh path so a defect is never written over real data\n", out)
		os.Exit(2)
	}

	// Read the source once. OpenStorage returns the recovered hard state and the
	// full entry log; the source is closed immediately and never written.
	storage, hs, snap, entries, err := raft.OpenStorage(src, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "faultlog: open src %s: %v\n", src, err)
		os.Exit(1)
	}
	_ = storage.Close()
	if snap != nil {
		fmt.Fprintf(os.Stderr, "faultlog: src %s carries a snapshot; the gate runs with compaction off, and a compacted source cannot be rebuilt faithfully\n", src)
		os.Exit(1)
	}
	if len(entries) == 0 {
		fmt.Fprintf(os.Stderr, "faultlog: src %s has no log entries to work from\n", src)
		os.Exit(1)
	}
	if entries[0].Index != 1 {
		fmt.Fprintf(os.Stderr, "faultlog: src %s starts at index %d, not 1; a rebuilt log must start from the first index\n", src, entries[0].Index)
		os.Exit(1)
	}

	switch mode {
	case "phantom":
		err = injectPhantom(out, entries, hs, phantomID)
	case "missing":
		err = injectMissing(out, entries, hs)
	case "corrupt":
		err = injectCorrupt(out, entries, hs)
	case "dup":
		err = injectDup(out, entries, hs)
	default:
		fmt.Fprintf(os.Stderr, "faultlog: unknown -mode %q (want phantom, missing, corrupt, or dup)\n", mode)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "faultlog: %s: %v\n", mode, err)
		os.Exit(1)
	}
}

// injectPhantom clones a committed upsert, rewrites its id to a never-written one,
// appends it as a new committed entry, and raises the commit index to cover it.
func injectPhantom(out string, entries []raft.Entry, hs raft.HardState, phantomID uint64) error {
	proto, ok := lastUpsertData(entries, hs.Commit)
	if !ok {
		return fmt.Errorf("no committed upsert to base a phantom on")
	}
	data := make([]byte, len(proto))
	copy(data, proto)
	binary.LittleEndian.PutUint64(data[1:cmdHeaderLen], phantomID)

	last := entries[len(entries)-1]
	phantom := raft.Entry{Index: last.Index + 1, Term: last.Term, Data: data}
	mutated := appendEntry(entries, phantom)
	hs.Commit = phantom.Index

	if err := writeLog(out, mutated, hs, 0); err != nil {
		return err
	}
	fmt.Printf("faultlog: phantom out=%s injected id=%d as committed entry index=%d; verify-log must red on a phantom id\n", out, phantomID, phantom.Index)
	return nil
}

// injectMissing makes the final acked operation vanish from the committed record
// by lowering the commit index below every committed copy of it. The client
// re-emits under an at-most-once transport, so one logical write can commit as
// several idempotent duplicates; dropping only the last copy would leave an
// earlier one and the id would stay live. This walks back over the contiguous
// committed-tail run of the last command's id (past any interleaved no-op) and
// lowers commit below the earliest of them. Its correctness rests on one
// precondition the gate's workload guarantees: because each client operation runs
// to completion before the next, every committed copy of the final write, however
// many were re-emitted, is that contiguous tail, with no other id interleaved. If
// that precondition did not hold, some copies could survive; the checker would
// still red, but on a value or live-set mismatch rather than a clean missing id.
// The entries stay on disk unchanged; only the commit watermark moves, a clean
// gap rather than a hole in a segment.
func injectMissing(out string, entries []raft.Entry, hs raft.HardState) error {
	last := -1
	for i, e := range entries {
		if e.Index <= hs.Commit && len(e.Data) > 0 {
			last = i
		}
	}
	if last < 0 {
		return fmt.Errorf("no committed command to drop")
	}
	targetID := binary.LittleEndian.Uint64(entries[last].Data[1:cmdHeaderLen])
	newCommit := entries[last].Index
	for i := last; i >= 0; i-- {
		e := entries[i]
		if e.Index > hs.Commit {
			continue
		}
		if len(e.Data) == 0 {
			continue // a no-op inside the run belongs to no id; drop it with the run
		}
		if binary.LittleEndian.Uint64(e.Data[1:cmdHeaderLen]) != targetID {
			break // a different id ends the run of the final write's copies
		}
		newCommit = e.Index - 1
	}
	hs.Commit = newCommit

	if err := writeLog(out, entries, hs, 0); err != nil {
		return err
	}
	fmt.Printf("faultlog: missing out=%s dropped every committed copy of the final write id=%d by lowering commit to %d; verify-log must red on a missing acked id and a replay mismatch\n", out, targetID, hs.Commit)
	return nil
}

// injectCorrupt rebuilds the log into one-entry segments and flips a byte inside a
// non-final segment, where the raft replay reports real corruption rather than a
// torn tail.
func injectCorrupt(out string, entries []raft.Entry, hs raft.HardState) error {
	if err := writeLog(out, entries, hs, tinySegBytes); err != nil {
		return err
	}
	segs, err := listSegments(out)
	if err != nil {
		return err
	}
	if len(segs) < 2 {
		return fmt.Errorf("rebuilt %d segment(s); need at least two so one is non-final, but the workload is too small", len(segs))
	}
	victim := segs[0] // the first segment is guaranteed non-final
	if err := flipByte(filepath.Join(out, victim), corruptOffset); err != nil {
		return err
	}
	fmt.Printf("faultlog: corrupt out=%s rebuilt into %d segments and flipped one byte in the non-final segment %s; verify-log must red on corrupt-open\n", out, len(segs), victim)
	return nil
}

// injectDup appends a byte-identical copy of the last committed upsert and commits
// it. This is the negative control: an idempotent duplicate must leave verify-log
// green.
func injectDup(out string, entries []raft.Entry, hs raft.HardState) error {
	proto, ok := lastUpsertData(entries, hs.Commit)
	if !ok {
		return fmt.Errorf("no committed upsert to duplicate")
	}
	data := make([]byte, len(proto))
	copy(data, proto)

	last := entries[len(entries)-1]
	dup := raft.Entry{Index: last.Index + 1, Term: last.Term, Data: data}
	mutated := appendEntry(entries, dup)
	hs.Commit = dup.Index

	if err := writeLog(out, mutated, hs, 0); err != nil {
		return err
	}
	fmt.Printf("faultlog: dup out=%s appended an idempotent duplicate as committed entry index=%d; verify-log must stay GREEN (the negative control)\n", out, dup.Index)
	return nil
}

// lastUpsertData returns the payload of the highest-index committed upsert, the
// entry whose payload is longer than the op+id header because it carries a vector.
func lastUpsertData(entries []raft.Entry, commit uint64) ([]byte, bool) {
	var data []byte
	found := false
	for _, e := range entries {
		if e.Index <= commit && len(e.Data) > cmdHeaderLen {
			data = e.Data
			found = true
		}
	}
	return data, found
}

// appendEntry returns a new slice with e appended, never aliasing the input's
// backing array, so the caller's entries stay intact.
func appendEntry(entries []raft.Entry, e raft.Entry) []raft.Entry {
	out := make([]raft.Entry, 0, len(entries)+1)
	out = append(out, entries...)
	return append(out, e)
}

// writeLog builds a fresh durable log under dir from entries and hs, rotating
// segments at maxSeg (0 for the default single large segment). It is the one
// place segments are created, so every mode shares the same framing the runtime
// uses.
func writeLog(dir string, entries []raft.Entry, hs raft.HardState, maxSeg int64) error {
	s, _, _, _, err := raft.OpenStorage(dir, maxSeg)
	if err != nil {
		return fmt.Errorf("open out %s: %w", dir, err)
	}
	if aerr := s.AppendEntries(entries); aerr != nil {
		_ = s.Close()
		return fmt.Errorf("append entries: %w", aerr)
	}
	if serr := s.SaveHardState(hs); serr != nil {
		_ = s.Close()
		return fmt.Errorf("save hard state: %w", serr)
	}
	return s.Close()
}

// listSegments returns the raft segment file names under dir in ascending order,
// matching the runtime's own naming (raft-NNNNNN.log).
func listSegments(dir string) ([]string, error) {
	items, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var segs []string
	for _, it := range items {
		name := it.Name()
		if it.IsDir() || !strings.HasPrefix(name, "raft-") || !strings.HasSuffix(name, ".log") {
			continue
		}
		mid := strings.TrimSuffix(strings.TrimPrefix(name, "raft-"), ".log")
		if _, err := strconv.ParseUint(mid, 10, 64); err != nil {
			continue // raft-hardstate and the like are not numbered segments
		}
		segs = append(segs, name)
	}
	sort.Strings(segs)
	return segs, nil
}

// flipByte inverts one byte at offset in path, in place, and fsyncs, corrupting
// the block that contains it.
func flipByte(path string, offset int64) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0o600) //nolint:gosec // path is a rebuilt segment in a caller-provided output dir, not untrusted input
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	b := make([]byte, 1)
	if _, err := f.ReadAt(b, offset); err != nil {
		return fmt.Errorf("read byte at %d: %w", offset, err)
	}
	b[0] ^= 0xFF
	if _, err := f.WriteAt(b, offset); err != nil {
		return fmt.Errorf("write byte at %d: %w", offset, err)
	}
	return f.Sync()
}
