package raft

import (
	"math/rand/v2"
	"os"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/faultio"
)

// The arm for PersistedEntries, and its direction is chosen and not incidental.
//
// The defect this accessor closes produces a false RED: the committed reading
// calls a correct engine unfaithful for a write acknowledged milliseconds before
// a cut. A red gets re-read. The mistake this accessor could ITSELF make is the
// opposite one -- reporting as persisted something the disk does not hold -- and
// that is a false GREEN over a broken engine, which nobody catches because
// nobody re-runs a green. So four of these six rows push on that side.
//
// The two that push the other way are not optional. Without V1, an accessor
// written as `return nil` passes R1, R2, R3 and R4 all four; without V2a,
// nothing here demonstrates the accessor reaches past the commit index at all,
// which is the entire reason it exists.

// restoredRaft opens dir cold, hands what came off the disk to a fresh Raft the
// way a restart does, and returns it. Nothing here fabricates state: the entries
// are whatever OpenStorage recovered.
func restoredRaft(t *testing.T, dir string) (*Raft, []Entry, error) {
	t.Helper()
	s, hs, snap, entries, err := OpenStorage(dir, 256)
	if err != nil {
		// Damage before the final segment is ErrCorruptLog and the directory does
		// not open at all. That is a legitimate outcome of "nothing here is
		// persisted", not a failure of this bench, so it goes back to the caller.
		return nil, nil, err
	}
	defer func() { _ = s.Close() }()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, nerr := New(1, cfg, rand.New(rand.NewPCG(1, 2)), DefaultOptions()) //nolint:gosec // deterministic, not security
	if nerr != nil {
		t.Fatalf("new raft: %v", nerr)
	}
	// A Restore failure is NOT a legitimate "nothing is persisted": it means this
	// bench built a state no replica could be in -- entries at a term the hard
	// state never reached, a commit past the log. Returning it as an open error
	// would let a caller treat a broken fixture as a proved property, and that is
	// how a row stops being able to fail. It was measured doing exactly that on
	// 2026-09-09: the deaf-barrier row passed with the barrier restored, because
	// the surviving entries carried a term no hard state covered.
	if rerr := r.Restore(hs, snap, entries); rerr != nil {
		t.Fatalf("restore rejected the fixture, so this row measured nothing: %v", rerr)
	}
	return r, entries, nil
}

// TestPersisted_WithoutFsyncNothingIsPersisted is R1, the direction the whole
// arm exists for: entries written through a barrier that lies, then a power cut,
// cannot come back as persisted.
func TestPersisted_WithoutFsyncNothingIsPersisted(t *testing.T) {
	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, faultio.DeafBarrier(disk.Opener()))
	if err != nil {
		t.Fatalf("open with a deaf barrier: %v", err)
	}
	acked := appendBatches(s, 11, nil)
	if len(acked) == 0 {
		t.Fatal("the sequence acknowledged nothing, so there is nothing to lose")
	}
	// A real replica saves a hard state whose term covers its log. Without this
	// the fixture is one no node could be in, and Restore says so.
	if herr := s.SaveHardState(HardState{Term: 7, Commit: 0}); herr != nil {
		t.Fatalf("hard state: %v", herr)
	}
	if cerr := disk.Crash(faultio.LoseAllUnsynced()); cerr != nil {
		t.Fatalf("cut the power: %v", cerr)
	}

	r, recovered, oerr := restoredRaft(t, dir)
	if oerr != nil {
		// Nothing survived well enough to open: the strongest form of "not
		// persisted", and the row is satisfied.
		return
	}
	got := r.PersistedEntries()
	if len(got) != len(recovered) {
		t.Fatalf("PersistedEntries reported %d entries and the disk gave up %d", len(got), len(recovered))
	}
	// The point is not that the number matches the recovery; it is that an
	// acknowledged entry whose barrier did nothing is NOT called persisted.
	for _, e := range got {
		if e.Index > uint64(len(recovered)) {
			t.Fatalf("entry %d is reported persisted and did not come off the disk", e.Index)
		}
	}
	if len(got) >= len(acked) {
		t.Fatalf("every one of the %d acknowledged entries survived a deaf barrier, so this row proved nothing: %d reported", len(acked), len(got))
	}
}

// TestPersisted_TornTailIsNotPersisted is R2: a record cut in half by the power
// going out must not come back, whole or partial, and must not take the process
// with it.
//
// THE CONSTRUCTION IS THE HARD PART AND THE FIRST ONE WAS WRONG. Written with a
// deaf barrier, all twelve seeds refused to open -- ErrCorruptLog, because with
// nothing ever synced the cut lands in a segment that is not the last one, and
// that is fatal by design (storage.go:233-244). The body never ran: the row
// asserted nothing, twelve times. It was measured doing that on 2026-09-09.
//
// A torn tail in the FINAL segment needs what a real machine has: a durable
// prefix, and an unsynced remainder confined to the active segment. So the
// barrier here is real, and the cut is armed mid-sequence, which is the shape
// runStoragePowerLoss already uses for the same reason.
func TestPersisted_TornTailIsNotPersisted(t *testing.T) {
	abiertos := 0
	for seed := uint64(1); seed <= 12; seed++ {
		// Pass one, on a directory thrown away, to learn where the writes fall.
		counting := faultio.NewDisk(faultio.SyncFsync)
		countS, _, _, _, cerr := OpenStorageWith(t.TempDir(), 256, counting.Opener())
		if cerr != nil {
			t.Fatalf("seed %d: open for counting: %v", seed, cerr)
		}
		// The term is persisted BEFORE the entries that carry it, which is the order
		// a real node uses: it saves the term when it votes and appends at that term
		// afterwards. It goes in both passes so the write counts stay aligned, and
		// it goes before the crash is armed because after it the disk may be gone.
		if herr := countS.SaveHardState(HardState{Term: 7, Commit: 0}); herr != nil {
			t.Fatalf("seed %d: counting hard state: %v", seed, herr)
		}
		firstAck := 0
		appendBatches(countS, seed, func() {
			if firstAck == 0 {
				firstAck = counting.Writes()
			}
		})
		total := counting.Writes()
		if closeErr := countS.Close(); closeErr != nil {
			t.Fatalf("seed %d: close counting: %v", seed, closeErr)
		}
		if firstAck == 0 || total <= firstAck {
			t.Fatalf("seed %d: no room to cut after the first acknowledgement", seed)
		}

		faultRNG := rand.New(rand.NewPCG(seed, 0x9E3779B97F4A7C15)) //nolint:gosec // deterministic fault schedule, not security
		cutAt := firstAck + 1 + faultRNG.IntN(total-firstAck)

		dir := t.TempDir()
		disk := faultio.NewDisk(faultio.SyncFsync)
		s, _, _, _, oerr := OpenStorageWith(dir, 256, disk.Opener())
		if oerr != nil {
			t.Fatalf("seed %d: open: %v", seed, oerr)
		}
		if herr := s.SaveHardState(HardState{Term: 7, Commit: 0}); herr != nil {
			t.Fatalf("seed %d: hard state: %v", seed, herr)
		}
		if aerr := disk.ArmCrashAfter(cutAt, faultio.LoseSuffixAt(faultRNG)); aerr != nil {
			t.Fatalf("seed %d: arm the cut: %v", seed, aerr)
		}
		appendBatches(s, seed, nil)
		if !disk.Crashed() {
			if crashErr := disk.Crash(faultio.LoseSuffixAt(faultRNG)); crashErr != nil {
				t.Fatalf("seed %d: cut the power: %v", seed, crashErr)
			}
		}

		r, recovered, rerr := restoredRaft(t, dir)
		if rerr != nil {
			// Damage before the final segment refuses the whole directory, which is
			// still "nothing here is persisted". Counted, not silently skipped: if
			// EVERY seed took this branch the row would prove nothing, and the
			// assertion below is what says so.
			continue
		}
		abiertos++
		got := r.PersistedEntries()
		if len(got) != len(recovered) {
			t.Fatalf("seed %d: reported %d and the disk gave up %d", seed, len(got), len(recovered))
		}
		for i, e := range got {
			if e.Index != recovered[i].Index || len(e.Data) != len(recovered[i].Data) {
				t.Fatalf("seed %d: entry %d came back altered", seed, e.Index)
			}
		}
	}
	if abiertos == 0 {
		t.Fatal("every seed refused to open, so the truncated-tail path was never exercised and this row measured nothing")
	}
}

// TestPersisted_FlippedChecksumIsNotPersisted is R3. The bytes are all there and
// the length prefix is intact; only the CRC disagrees. An accessor that trusted
// the prefix would hand the record back.
func TestPersisted_FlippedChecksumIsNotPersisted(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	if err := s.AppendEntries([]Entry{dataEnt(1, 7, "first"), dataEnt(2, 7, "second")}); err != nil {
		t.Fatalf("append: %v", err)
	}
	// A term at least the log's, and no commit: entries on the platter that the
	// group has not yet told this replica are agreed. That is a state a real
	// follower sits in, and Restore refuses the unreal ones.
	if err := s.SaveHardState(HardState{Term: 7, Commit: 0}); err != nil {
		t.Fatalf("hard state: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	// Flip a byte inside the final segment's payload, leaving its length alone.
	path := dir + "/raft-000001.log"
	raw, err := os.ReadFile(path) //nolint:gosec // a path this test just created
	if err != nil {
		t.Fatalf("read segment: %v", err)
	}
	before := len(raw)
	raw[len(raw)-3] ^= 0xFF
	if werr := os.WriteFile(path, raw, 0o600); werr != nil { //nolint:gosec // a path this test just created
		t.Fatalf("write segment: %v", werr)
	}
	if len(raw) != before {
		t.Fatalf("the sabotage changed the file length, so this row tests truncation and not the checksum")
	}

	r, _, oerr := restoredRaft(t, dir)
	if oerr != nil {
		t.Fatalf("a flipped checksum must truncate a tail, not refuse the directory: %v", oerr)
	}
	for _, e := range r.PersistedEntries() {
		if string(e.Data) == "second" {
			t.Fatal("an entry whose checksum does not verify was reported as persisted")
		}
	}
}

// TestPersisted_AppendedAfterOpenIsNotPersisted is R4, and it is the row that
// separates a watermark taken at Restore from the two obvious wrong bounds. An
// accessor cut at LastIndex passes R1, R2, R3 and V1 and fails only here -- and
// it fails GREEN, by calling an entry durable that the disk never confirmed.
func TestPersisted_AppendedAfterOpenIsNotPersisted(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	if err := s.AppendEntries([]Entry{dataEnt(1, 7, "off-the-disk")}); err != nil {
		t.Fatalf("append: %v", err)
	}
	if err := s.SaveHardState(HardState{Term: 7, Commit: 0}); err != nil {
		t.Fatalf("hard state: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	r, recovered, oerr := restoredRaft(t, dir)
	if oerr != nil {
		t.Fatalf("cold open: %v", oerr)
	}
	if len(recovered) != 1 {
		t.Fatalf("the cold open recovered %d entries, want 1", len(recovered))
	}
	if err := r.log.Append(dataEnt(2, 7, "appended-after-the-open")); err != nil {
		t.Fatalf("append after open: %v", err)
	}
	got := r.PersistedEntries()
	if len(got) != 1 {
		t.Fatalf("PersistedEntries reported %d entries after one was appended post-open, want 1", len(got))
	}
	if string(got[0].Data) != "off-the-disk" {
		t.Fatalf("reported %q, want the entry that came off the disk", got[0].Data)
	}
}

// TestPersisted_FsyncedEntriesArePersisted is V1, and without it the four rows
// above are satisfied by an accessor that always returns nothing.
func TestPersisted_FsyncedEntriesArePersisted(t *testing.T) {
	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, disk.Opener())
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	acked := appendBatches(s, 23, nil)
	if len(acked) == 0 {
		t.Fatal("nothing was acknowledged")
	}
	if herr := s.SaveHardState(HardState{Term: 7, Commit: 0}); herr != nil {
		t.Fatalf("hard state: %v", herr)
	}
	if cerr := disk.Crash(faultio.LoseAllUnsynced()); cerr != nil {
		t.Fatalf("cut the power: %v", cerr)
	}

	r, _, oerr := restoredRaft(t, dir)
	if oerr != nil {
		t.Fatalf("a real barrier must survive the cut: %v", oerr)
	}
	got := r.PersistedEntries()
	if len(got) != len(acked) {
		t.Fatalf("a real barrier acknowledged %d entries and only %d came back persisted", len(acked), len(got))
	}
}

// TestPersisted_ReachesPastTheCommitIndex is V2a: DEFER-102 written as a test.
// It is the only row here that does not compile without the accessor, and the
// only one that demonstrates persisted > committed is reachable at all.
func TestPersisted_ReachesPastTheCommitIndex(t *testing.T) {
	dir := t.TempDir()
	s, _, _, _ := openForTest(t, dir)
	entries := []Entry{dataEnt(1, 7, "one"), dataEnt(2, 7, "two"), dataEnt(3, 7, "three")}
	if err := s.AppendEntries(entries); err != nil {
		t.Fatalf("append: %v", err)
	}
	// The hard state stops one short, which is exactly where a follower sits in
	// the milliseconds after the leader acknowledges and before the next append
	// tells it the entry is committed.
	if err := s.SaveHardState(HardState{Term: 7, Commit: 2}); err != nil {
		t.Fatalf("hard state: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	r, _, oerr := restoredRaft(t, dir)
	if oerr != nil {
		t.Fatalf("cold open: %v", oerr)
	}
	committed := r.CommittedEntries()
	persisted := r.PersistedEntries()
	if len(committed) != 2 {
		t.Fatalf("CommittedEntries returned %d, want 2", len(committed))
	}
	if len(persisted) != 3 {
		t.Fatalf("PersistedEntries returned %d, want 3: the third is on the disk and below no commit index", len(persisted))
	}
	if string(persisted[2].Data) != "three" {
		t.Fatalf("the entry past the commit index came back as %q", persisted[2].Data)
	}
}
