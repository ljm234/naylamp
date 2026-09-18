package raft

import (
	"bytes"
	"fmt"
	"math/rand/v2"
	"testing"

	"naylamp/engine/faultio"
)

// The Phase 2 durability claim has a carrier the product actually starts, and
// it is this one, not persist.DB: naylampd runs a Raft node, and the fsync that
// stands between a client write and its acknowledgement is the one in
// AppendEntries.
//
// Until these two arms existed, nothing defended it: removing that fsync
// compiled, started, and left the whole short suite green. That is no longer
// true, and the sentence is in the past tense on purpose. Remove it now and the
// positive arm below reports the first acknowledged entry it lost.
//
// These two arms tell the difference. Power is cut at the IO layer, so what
// survives is what crossed the barrier and nothing else.
//
// The red arm is built from a deaf barrier rather than from a mutated build.
// The sabotage is an opener whose files accept Sync and do nothing with it. The
// node's code is untouched: it calls Sync exactly where it always did, and the
// call is a lie. That models more than a build with the line deleted. It is
// also what a drive that ignores a cache flush does, and what a filesystem
// mounted with barriers off does, which are the ways this failure actually
// reaches production rather than the way it reaches a diff.
//
// What neither arm reaches: the hard state and the snapshot are replaced through a temp file that is
// fsynced and then renamed. Renames are not intercepted by the model, which
// treats them as durable the instant they happen, so a lost barrier on THAT
// path does not show up here. The entry log is what these arms cover, and the
// entry log is where an acknowledged client write lives. See DEFER-028 for the
// same blind spot found on the other engine.

// TestDropUnsynced_AppendedEntriesSurvivePowerLoss is the positive arm: cut the
// power in the middle of the write stream and every batch AppendEntries
// acknowledged has to come back, byte for byte, through a real reopen.
func TestDropUnsynced_AppendedEntriesSurvivePowerLoss(t *testing.T) {
	const seeds = 60
	cutSomething := 0
	for s := uint64(1); s <= seeds; s++ {
		if runStoragePowerLoss(t, s) {
			cutSomething++
		}
	}
	if cutSomething == 0 {
		t.Fatal("every seed came through with its log untouched: no fault was applied, so no survival was demonstrated")
	}
	t.Logf("power cut removed unsynced bytes in %d of %d seeds, and 0 acknowledged entries were lost", cutSomething, seeds)
}

// TestDropUnsynced_WithoutFsyncAppendedEntriesAreLost is the red arm. A node
// whose barrier does nothing must lose entries it acknowledged. If this goes
// green, AppendEntries could stop fsyncing tomorrow and nobody would find out.
func TestDropUnsynced_WithoutFsyncAppendedEntriesAreLost(t *testing.T) {
	lostSomewhere := 0
	for s := uint64(1); s <= 20; s++ {
		acked, survived := runStorageNoBarrier(t, s)
		if acked == 0 {
			t.Fatalf("seed %d: no batch was ever acknowledged, so there is nothing whose loss would be a fault", s)
		}
		if survived > acked {
			t.Fatalf("seed %d: %d entries survived out of %d acknowledged, which is impossible", s, survived, acked)
		}
		if survived < acked {
			lostSomewhere++
		}
	}
	if lostSomewhere == 0 {
		t.Fatal("a node whose fsync does nothing lost no acknowledged entries: the layer is not modeling the barrier")
	}
	t.Logf("a node without a real fsync-before-ack lost acknowledged entries in %d of 20 seeds", lostSomewhere)
}

// runStoragePowerLoss drives one positive scenario and reports whether the
// crash actually removed unsynced bytes.
func runStoragePowerLoss(t *testing.T, seed uint64) bool {
	t.Helper()

	// Pass one on a throwaway directory, to learn how many writes the sequence
	// issues so pass two can cut the power inside it. A node that fsyncs before
	// it acknowledges has nothing unsynced while it sits still, so a crash at
	// rest leaves the log exactly as an orderly shutdown would.
	counting := faultio.NewDisk(faultio.SyncFsync)
	countS, _, _, _, err := OpenStorageWith(t.TempDir(), 256, counting.Opener())
	if err != nil {
		t.Fatalf("seed %d: open for counting: %v", seed, err)
	}
	// A batch fsyncs once, at the end, however many entries it holds, so the
	// first acknowledgement can be several writes in. Cutting the power before
	// it would leave nothing acknowledged and nothing to prove.
	firstAck := 0
	appendBatches(countS, seed, func() {
		if firstAck == 0 {
			firstAck = counting.Writes()
		}
	})
	if cerr := countS.Close(); cerr != nil {
		t.Fatalf("seed %d: close counting storage: %v", seed, cerr)
	}
	totalWrites := counting.Writes()
	if firstAck == 0 || totalWrites <= firstAck {
		t.Fatalf("seed %d: %d writes with the first acknowledgement at %d, no room to cut power after it", seed, totalWrites, firstAck)
	}

	faultRNG := rand.New(rand.NewPCG(seed, 0x9E3779B97F4A7C15)) //nolint:gosec // deterministic fault schedule, not security
	cutAt := firstAck + 1 + faultRNG.IntN(totalWrites-firstAck)

	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, disk.Opener())
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}
	if aerr := disk.ArmCrashAfter(cutAt, faultio.LoseSuffixAt(faultRNG)); aerr != nil {
		t.Fatalf("seed %d: arm the power cut: %v", seed, aerr)
	}

	acked := appendBatches(s, seed, nil)
	if len(acked) == 0 {
		t.Fatalf("seed %d: the power cut landed before the first acknowledgement", seed)
	}
	if !disk.Crashed() {
		if cerr := disk.Crash(faultio.LoseSuffixAt(faultRNG)); cerr != nil {
			t.Fatalf("seed %d: crash: %v", seed, cerr)
		}
	}

	// Recovery is real: a fresh OpenStorage over the same directory, with the
	// ordinary opener, replaying the segments that survived.
	back, _, _, recovered, rerr := OpenStorage(dir, 256)
	if rerr != nil {
		t.Fatalf("seed %d: reopen after power loss: %v", seed, rerr)
	}
	defer func() { _ = back.Close() }()
	byIndex := make(map[uint64]Entry, len(recovered))
	for _, e := range recovered {
		byIndex[e.Index] = e
	}
	for _, want := range acked {
		got, ok := byIndex[want.Index]
		if !ok {
			t.Fatalf("seed %d: acknowledged entry %d lost to the power cut", seed, want.Index)
		}
		if got.Term != want.Term || !bytes.Equal(got.Data, want.Data) {
			t.Fatalf("seed %d: acknowledged entry %d came back altered: term %d/%d", seed, want.Index, got.Term, want.Term)
		}
	}
	return disk.BytesCut() > 0
}

// runStorageNoBarrier drives the red arm and returns how many entries were
// acknowledged and how many survived.
func runStorageNoBarrier(t *testing.T, seed uint64) (acked, survived int) {
	t.Helper()
	dir := t.TempDir()

	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, faultio.DeafBarrier(disk.Opener()))
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}
	entries := appendBatches(s, seed, nil)
	if cerr := disk.Crash(faultio.LoseAllUnsynced()); cerr != nil {
		t.Fatalf("seed %d: crash: %v", seed, cerr)
	}

	back, _, _, recovered, rerr := OpenStorage(dir, 256)
	if rerr != nil {
		t.Fatalf("seed %d: reopen after power loss: %v", seed, rerr)
	}
	defer func() { _ = back.Close() }()
	return len(entries), len(recovered)
}

// appendBatches writes a deterministic run of batches and returns the entries
// that AppendEntries acknowledged, stopping at the first error, which is how a
// power cut mid-batch reaches a caller. The entries of a batch that failed are
// not acknowledged and are not returned: their outcome is undefined and the
// claim under test says nothing about them.
//
// onAck, when given, fires after each acknowledged batch, which is how the
// counting pass learns where the first acknowledgement fell.
func appendBatches(s *Storage, seed uint64, onAck func()) []Entry {
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic sequence, not security
	var acked []Entry
	index, term := uint64(1), uint64(7)
	batches := 8 + rng.IntN(12)
	for b := 0; b < batches; b++ {
		n := 1 + rng.IntN(4)
		batch := make([]Entry, 0, n)
		for i := 0; i < n; i++ {
			batch = append(batch, Entry{
				Index: index,
				Term:  term,
				Data:  fmt.Appendf(nil, "seed-%d-entry-%d-payload", seed, index),
			})
			index++
		}
		if err := s.AppendEntries(batch); err != nil {
			return acked
		}
		acked = append(acked, batch...)
		if onAck != nil {
			onAck()
		}
	}
	return acked
}

// The hard state is a separate arm because it is a separate claim. The entry
// log carries acknowledged client writes; the hard state carries Term and Vote,
// and a node that comes back having forgotten its vote can hand out a second one
// in the same term and help elect two leaders. That is a safety property, not a
// durability one, and losing it costs more than losing a write.
//
// It needed its own arm for a reason worth recording. The hard state is replaced
// by writing a temp file, fsyncing it and renaming it into place, and the
// injector used to key its bookkeeping on the path a file was opened under. At
// crash time the temp name was gone, so it skipped the file, so the fsync was
// invisible: deleting it left every package in the tree green. An adversarial
// review found that, the injector now follows files by identity through the
// rename, and these two arms are what stop it from coming back.

// TestDropUnsynced_HardStateSurvivesPowerLoss is the positive arm: a hard state
// that SaveHardState acknowledged has to come back exactly.
func TestDropUnsynced_HardStateSurvivesPowerLoss(t *testing.T) {
	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, disk.Opener())
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	want := HardState{Term: 9, Vote: 3, Commit: 4}
	if serr := s.SaveHardState(want); serr != nil {
		t.Fatalf("save hard state: %v", serr)
	}
	// Something unsynced has to be on the floor, or the crash proves nothing.
	if aerr := s.AppendEntries([]Entry{{Index: 1, Term: 9, Data: []byte("committed")}}); aerr != nil {
		t.Fatalf("append: %v", aerr)
	}
	if aerr := disk.ArmCrashAfter(1, faultio.LoseAllUnsynced()); aerr != nil {
		t.Fatalf("arm: %v", aerr)
	}
	_ = s.AppendEntries([]Entry{{Index: 2, Term: 9, Data: []byte("in flight when the lights went out")}})
	if !disk.Crashed() {
		t.Fatal("the armed power cut never fired")
	}
	if disk.BytesCut() == 0 {
		t.Fatal("the power cut removed nothing, so surviving it means nothing")
	}

	_, got, _, _, rerr := OpenStorage(dir, 256)
	if rerr != nil {
		t.Fatalf("reopen after power loss: %v", rerr)
	}
	if got != want {
		t.Fatalf("the acknowledged hard state came back as %+v, want %+v", got, want)
	}
}

// TestDropUnsynced_WithoutFsyncTheHardStateIsLost is the red arm. A node whose
// barrier does nothing must not bring its vote back intact. Coming back unusable
// counts too: refusing to start is not a node voting twice.
func TestDropUnsynced_WithoutFsyncTheHardStateIsLost(t *testing.T) {
	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	s, _, _, _, err := OpenStorageWith(dir, 256, faultio.DeafBarrier(disk.Opener()))
	if err != nil {
		t.Fatalf("open: %v", err)
	}

	want := HardState{Term: 9, Vote: 3, Commit: 0}
	if serr := s.SaveHardState(want); serr != nil {
		t.Fatalf("save hard state: %v", serr)
	}
	if cerr := disk.Crash(faultio.LoseAllUnsynced()); cerr != nil {
		t.Fatalf("crash: %v", cerr)
	}

	_, got, _, _, rerr := OpenStorage(dir, 256)
	if rerr == nil && got == want {
		t.Fatal("a node whose fsync does nothing brought its vote back intact after a power cut")
	}
	if rerr != nil {
		t.Logf("without a real barrier the node refuses to start: %v", rerr)
	} else {
		t.Logf("without a real barrier the vote came back as %+v instead of %+v", got, want)
	}
}
