package persist

import (
	"math/rand/v2"
	"testing"

	"naylamp/engine/faultio"
	"naylamp/engine/vector"
)

// This file closes the half of the Phase 2 durability claim that
// TestCrash_AcknowledgedWritesSurvive cannot reach.
//
// That test simulates a crash by dropping the Go handle, which evicts nothing:
// WAL.Append flushes unconditionally, so under either fsync policy the bytes
// have already crossed into the operating system's page cache and letting go of
// a handle does not bring them back. Measured on 4 August 2026 over the same
// 200-seed sequence: FsyncAlways loses 0 of 200 and FsyncNever loses 0 of 200.
// A test that cannot tell those two apart is not defending the fsync.
//
// Here the crash is a power cut modeled at the IO layer: every file is cut back
// into the region past its last fsync, so what survives is exactly what crossed
// the barrier. That makes the same claim falsifiable, and the two arms below
// are what pin it down.
//
// The positive arm establishes that a correct engine loses nothing THE LAYER
// CAN SEE. That is narrower than "loses nothing", and the gap is named rather
// than left for a reader to discover.
//
// The model treats directory metadata as durable the instant it happens:
// renames, removes and a directory's own fsync are not intercepted. So a defect
// that loses data through a missing directory fsync passes this arm untouched.
// There is one such defect in this very package, registered as DEFER-028:
// openActiveSegment creates a segment without making its directory entry
// durable, where raft.openFreshSegment does. Reordering is the other blind
// spot: this is the prefix crash model, and along the ordering axis it is
// strictly poorer than real hardware, which can persist a later page and lose
// an earlier one. Neither gap is a reason to distrust the green. Both are
// reasons not to read it as wider than it is.

// TestDropUnsynced_FsyncedWritesSurvivePowerLoss is the positive arm. Power is
// cut in the middle of the write stream, so there is genuinely unsynced data on
// the floor when the machine dies, and every write the engine acknowledged must
// still be there and still be searchable after recovery.
//
// The cut point is drawn from the unsynced region, so it usually lands inside a
// record and the torn-tail path runs for real.
func TestDropUnsynced_FsyncedWritesSurvivePowerLoss(t *testing.T) {
	const (
		seeds = 200
		dim   = 8
	)
	cutSomething := 0
	for s := uint64(1); s <= seeds; s++ {
		if runPowerLossSeed(t, s, dim, FsyncAlways) {
			cutSomething++
		}
	}
	// Without this the suite would pass against an injector that cut nothing at
	// all, which is the exact failure mode this file exists to retire.
	if cutSomething == 0 {
		t.Fatal("no seed lost a single unsynced byte: the injector removed nothing and the green is empty")
	}
	t.Logf("power cut removed unsynced bytes in %d of %d seeds, and 0 acknowledged writes were lost", cutSomething, seeds)
}

// TestDropUnsynced_WithoutFsyncAcknowledgedWritesAreLost is the red arm. The
// same sequence under an engine that never fsyncs must lose acknowledged
// writes. If this ever goes green, the layer stopped modeling the barrier and
// the positive arm above stopped meaning anything.
func TestDropUnsynced_WithoutFsyncAcknowledgedWritesAreLost(t *testing.T) {
	const dim = 8
	lostSomewhere := 0
	for s := uint64(1); s <= 20; s++ {
		acked, survived := runNoFsyncSeed(t, s, dim)
		if acked == 0 {
			t.Fatalf("seed %d: acknowledged nothing, so the arm proves nothing", s)
		}
		if survived > acked {
			t.Fatalf("seed %d: %d records survived out of %d acknowledged, which is impossible", s, survived, acked)
		}
		if survived < acked {
			lostSomewhere++
		}
	}
	if lostSomewhere == 0 {
		t.Fatal("an engine that never fsyncs lost nothing under a power cut: the layer is not modeling the fsync boundary")
	}
	t.Logf("an engine without fsync-before-ack lost acknowledged writes in %d of 20 seeds", lostSomewhere)
}

// runPowerLossSeed drives one scenario and reports whether the crash actually
// removed unsynced bytes. It fails the test if any acknowledged write is gone.
func runPowerLossSeed(t *testing.T, seed uint64, dim int, policy FsyncPolicy) bool {
	t.Helper()

	// Pass one, on a throwaway directory: learn how many writes this sequence
	// issues, so pass two can cut the power INSIDE it rather than after it. At
	// rest an engine that fsyncs before it acknowledges has nothing unsynced,
	// and a crash there would remove nothing and prove nothing.
	//
	// It counts under FsyncNever whatever policy is being measured. The count
	// is identical either way, because Append flushes unconditionally and only
	// the barrier after the flush depends on the policy, and skipping the
	// barrier here turns a pass that costs one fsync per record into one that
	// costs none.
	countingDisk := faultio.NewDisk(faultio.SyncFsync)
	countDB, err := openWith(t.TempDir(), vector.CosineDistance, FsyncNever, seed, DefaultCompactionPolicy, countingDisk.Opener())
	if err != nil {
		t.Fatalf("seed %d: open for counting: %v", seed, err)
	}
	if n, _ := applyOps(t, countDB, newCrashOracle(), opsRNG(seed), dim); n == 0 {
		t.Fatalf("seed %d: the counting pass acknowledged nothing", seed)
	}
	if cerr := countDB.Close(); cerr != nil {
		t.Fatalf("seed %d: close the counting db: %v", seed, cerr)
	}
	totalWrites := countingDisk.Writes()
	if totalWrites < 2 {
		t.Fatalf("seed %d: the sequence issued %d writes, too few to cut power inside it", seed, totalWrites)
	}

	// Pass two: the same sequence on a fresh directory, with the power cut
	// landing at a chosen write. The draw starts at the second write, not the
	// first, so at least one record crosses the barrier before the machine
	// dies: a scenario that acknowledges nothing cannot lose anything either,
	// and would be a green that proves nothing.
	faultRNG := crashRNG(seed)
	cutAt := 2 + faultRNG.IntN(totalWrites-1)

	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	db, err := openWith(dir, vector.CosineDistance, policy, seed, DefaultCompactionPolicy, disk.Opener())
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}
	if aerr := disk.ArmCrashAfter(cutAt, faultio.LoseSuffixAt(faultRNG)); aerr != nil {
		t.Fatalf("seed %d: arm the power cut: %v", seed, aerr)
	}

	oracle := newCrashOracle()
	acked, air := applyOps(t, db, oracle, opsRNG(seed), dim)
	if acked == 0 {
		t.Fatalf("seed %d: the power cut landed before the first acknowledgement", seed)
	}
	if !disk.Crashed() {
		// The sequence ran out before the armed write, which happens when the
		// startup path issues fewer writes than pass one saw. Cut the power now
		// so the scenario still ends in a crash and not a clean shutdown.
		if cerr := disk.Crash(faultio.LoseSuffixAt(faultRNG)); cerr != nil {
			t.Fatalf("seed %d: crash: %v", seed, cerr)
		}
	}

	assertOracleSurvived(t, seed, dir, oracle, air)
	return disk.BytesCut() > 0
}

// opsRNG is the draw that decides the operation sequence.
func opsRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for a reproducible scenario, not security
}

// crashRNG is the draw that decides where the power cut lands and how much of
// the unsynced region survives it. It is a separate stream from opsRNG so the
// fault schedule is not correlated with the workload it interrupts.
func crashRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, 0x9E3779B97F4A7C15)) //nolint:gosec // deterministic RNG for a reproducible scenario, not security
}

// runNoFsyncSeed drives the red arm and returns how many records were
// acknowledged and how many survived the power cut.
func runNoFsyncSeed(t *testing.T, seed uint64, dim int) (acked, survived int) {
	t.Helper()
	dir := t.TempDir()

	disk := faultio.NewDisk(faultio.SyncFsync)
	db, err := openWith(dir, vector.CosineDistance, FsyncNever, seed, DefaultCompactionPolicy, disk.Opener())
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}
	acked, _ = applyOps(t, db, newCrashOracle(), opsRNG(seed), dim)
	if cerr := disk.Crash(faultio.LoseAllUnsynced()); cerr != nil {
		t.Fatalf("seed %d: crash: %v", seed, cerr)
	}

	records, rerr := ReadAllRecords(dir)
	if rerr != nil {
		t.Fatalf("seed %d: read wal after crash: %v", seed, rerr)
	}
	return acked, len(records)
}

// inFlight names the operation that was in the air when the power went out: the
// one whose record may already be on disk and whose caller never got an answer.
type inFlight struct {
	deleted  uint64 // the id a delete was trying to remove
	isDelete bool
}

// applyOps runs the deterministic upsert and delete sequence against db,
// recording in the oracle exactly what was acknowledged, and stops at the first
// error, which is how a power cut mid-sequence reaches a caller. It returns how
// many operations were acknowledged and what was in flight when it stopped.
//
// The ack boundary has a sharp edge here and getting it wrong is how a
// durability test lies. An operation that returned an error has an UNDEFINED
// outcome: its record may already be in the page cache and may survive the
// crash, and the caller was told nothing either way. For an upsert of a fresh
// id that is harmless, since the oracle never listed it and a surviving record
// only adds data. For a delete it is not: the oracle still lists the victim as
// live, and if the unacknowledged delete happens to survive, recovery is right
// to have applied it and the oracle is wrong to demand the id back. So the
// in-flight delete's victim is the one id the survival check has to let go of.
func applyOps(t *testing.T, db *DB, oracle *crashOracle, rng *rand.Rand, dim int) (int, inFlight) {
	t.Helper()
	ops := 20 + rng.IntN(60)
	acked, nextID := 0, uint64(1)
	for i := 0; i < ops; i++ {
		if len(oracle.live) > 0 && rng.IntN(4) == 0 {
			victim := pickLiveID(rng, oracle)
			if err := db.Delete(victim); err != nil {
				return acked, inFlight{deleted: victim, isDelete: true}
			}
			oracle.delete(victim)
		} else {
			v := vector.Vector{ID: nextID, Data: randData(rng, dim)}
			nextID++
			if err := db.Upsert(v); err != nil {
				return acked, inFlight{}
			}
			oracle.upsert(v)
		}
		acked++
	}
	return acked, inFlight{}
}

// assertOracleSurvived recovers from dir and fails if any acknowledged write is
// missing, altered, or no longer findable through the index.
func assertOracleSurvived(t *testing.T, seed uint64, dir string, oracle *crashOracle, air inFlight) {
	t.Helper()
	state, err := Recover(dir, vector.CosineDistance, seed)
	if err != nil {
		t.Fatalf("seed %d: recover after power loss: %v", seed, err)
	}
	for id, want := range oracle.live {
		if air.isDelete && id == air.deleted {
			continue // its delete was never acknowledged, so either outcome is correct
		}
		got, gerr := state.Store.Get(id)
		if gerr != nil {
			t.Fatalf("seed %d: acknowledged id %d lost to the power cut: %v", seed, id, gerr)
		}
		if len(got.Data) != len(want.Data) {
			t.Fatalf("seed %d: id %d data len mismatch after the power cut", seed, id)
		}
		for j := range want.Data {
			if got.Data[j] != want.Data[j] {
				t.Fatalf("seed %d: id %d data mismatch at %d after the power cut", seed, id, j)
			}
		}
	}
	checked := 0
	for id, want := range oracle.live {
		if air.isDelete && id == air.deleted {
			continue
		}
		found := false
		for _, n := range state.Index.Search(want.Data, 5) {
			if n.ID == id {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("seed %d: acknowledged id %d not searchable after the power cut", seed, id)
		}
		checked++
		if checked >= 5 {
			break
		}
	}
}
