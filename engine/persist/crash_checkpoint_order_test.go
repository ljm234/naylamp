package persist

import (
	"testing"

	"naylamp/engine/faultio"
	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// This file closes DEFER-093: the ORDER of the three steps inside
// checkpointWith had no defender, and inverting it loses every acknowledged
// write.
//
// The package already had both halves and never put them together. The arms
// that inject faults (the TestDropUnsynced family) open on a t.TempDir() that
// was just created, so the replay brings nothing back, startup compaction never
// fires, and checkpointWith is never reached under an injecting opener. The
// arms that do reach a checkpoint (checkpoint_test.go, db_test.go,
// compaction_sweep_test.go) all go through the real operating-system opener, so
// no cut can land inside one. Fault injection and checkpoints existed in the
// same package and never met. This file is the crossing.
//
// The order buys everything, and inverting it is total rather than partial.
// checkpointWith writes the snapshot, then points the manifest at that
// snapshot's watermark, then reclaims the WAL segments the snapshot covers.
// Recover reads that watermark in its second step, watermark :=
// manifest.SnapshotLSN, WITHOUT conditioning it on the snapshot being present.
// So a manifest published before its snapshot tells recovery to skip every
// record up to the watermark, and an intact WAL is walked past in full. The
// damage is not the truncation. It is the manifest arriving first.
//
// The blast radius does NOT need a rotated WAL, which is worth stating because
// the first version of the register claimed it did. Truncation is what needs
// two live segments; the manifest-before-snapshot window opens on the first
// checkpoint of a small database, with a single segment and nothing to reclaim.
// Measured on 5 September 2026: with one segment the sweep walks six cut
// points, the healthy tree loses at none of them, and the inverted order loses
// all 150 acknowledged writes at five of the six.
//
// WHAT THIS FILE DOES NOT ASSERT, said here rather than left to be discovered.
//
// It is the same prefix crash model the rest of this package uses, with the
// same gaps: renames, removes and a directory's own fsync are not intercepted,
// so a defect that loses data through a missing directory fsync passes this
// file untouched. That is DEFER-028, and it is not what this arm is for.
//
// It sweeps with ONE live segment, so truncation has nothing to reclaim and is
// never exercised. The guard inside truncateWALSegments that spares the active
// segment is defended elsewhere, by TestCheckpoint_TruncatesCoveredSegments,
// and a cut landing inside a truncation that does reclaim is nobody's arm yet.
//
// Its RED depends on Recover reading the manifest watermark. That read is
// itself undefended: the crudo of 4 September 2026 archives a mutant where
// Recover ignores manifest.SnapshotLSN and the package stays green. With both
// mutations applied at once this arm goes green too, because the second one
// hides the first. Two undefended defects covering for each other is not a
// property of this file, it is the state of the package, and it is written here
// so the next reader does not have to find it twice.
//
// It checks the records, not the index. countIntactRecords compares every
// acknowledged ID and payload against what was written, so a recovery that
// returns the right count of wrong vectors fails here; but a recovery that
// restores every record and rebuilds an index that cannot find them passes.
// Searchability after a cut is what the TestDropUnsynced family asks for.

// TestCrashInsideCheckpoint_AckedWritesSurvive cuts the power at every write
// the layer intercepts INSIDE a checkpoint and requires every acknowledged
// write to come back. The assertion is on the recovered store through the
// real Recover entry point, not on a return value: a checkpoint that reports
// success while having destroyed the durable state is exactly the shape this
// arm exists to catch.
//
// The sweep runs with a single live segment. That is the harder case for the
// arm and the easier one for the tree to reach in production: nothing is
// reclaimed, so the only window left is the one the ordering opens.
func TestCrashInsideCheckpoint_AckedWritesSurvive(t *testing.T) {
	const acked = 150

	// Pass one, with nothing armed: learn how many writes the checkpoint issues,
	// so the sweep below can be checked against that number instead of against a
	// floor. A floor would let a tree that shrank the checkpoint to two writes
	// pass while reporting success, and the count is not a constant: it follows
	// the snapshot's size through the buffered writer, so it moves with acked
	// and with the vector width.
	writes := countCheckpointWrites(t, acked)
	if writes < 2 {
		t.Fatalf("the checkpoint issued %d writes the layer can see: there is no window to sweep and this arm proves nothing", writes)
	}

	positions, tookBytes := 0, 0
	for k := 1; k <= writes; k++ {
		fired, cut, recovered := runCheckpointCutSeed(t, k, acked)
		if fired {
			positions++
		}
		if cut > 0 {
			tookBytes++
		}
		if recovered != acked {
			t.Fatalf("cut point %d: %d of the %d acknowledged writes came back intact after recovery; the checkpoint destroyed durable state it had already published",
				k, recovered, acked)
		}
	}

	// Every position of the axis must have armed a crash. An axis measured on
	// one tree and swept on another would spend its tail past the end of the
	// stream, arming nobody and reporting a wide green for positions that never
	// existed.
	if positions != writes {
		t.Fatalf("the crash fired at only %d of the %d writes the checkpoint issues: the axis does not match the stream it walks", positions, writes)
	}
	// Firing is not enough. A cut policy that lands at the end of the file fires
	// and takes nothing, and the assertion above is then trivially true. This
	// guard exists because its absence was measured in the order defender of
	// engine/naylamp: degraded that way, its sweep passed green and wide and the
	// whole red arm disappeared without a word.
	if tookBytes != writes {
		t.Fatalf("the cut removed bytes at only %d of the %d positions swept: the injector fired without taking anything and the green is empty", tookBytes, writes)
	}
	t.Logf("power cut inside the checkpoint at every one of its %d writes, bytes removed at all of them, and all %d acknowledged writes came back intact each time", writes, acked)
}

// runCheckpointCutSeed lays down a WAL with that many acknowledged records,
// arms the crash for the k-th write the layer sees after that, runs a real
// checkpoint, and reports whether the crash fired, how many bytes it removed,
// and how many records recovery brought back.
//
// The WAL is closed before the checkpoint so the sweep counts only the writes
// the checkpoint itself issues. Counting from the whole run instead would spend
// most positions past the end of the armed stream, arming nobody, which is the
// mistake the order defender made and wrote down.
func runCheckpointCutSeed(t *testing.T, k, acked int) (fired bool, cut int64, recovered int) {
	t.Helper()

	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	open := disk.Opener()

	lastLSN, snap := seedWALForCheckpoint(t, dir, acked, open)

	if err := disk.ArmCrashAfter(k, faultio.LoseAllUnsynced()); err != nil {
		t.Fatalf("arming the crash for write %d: %v", k, err)
	}
	// The error is deliberately not asserted on. A checkpoint interrupted by a
	// power cut is entitled to fail; what it is not entitled to do is leave the
	// durable state unreadable. The claim is checked below, through Recover.
	_ = checkpointWith(dir, snap, lastLSN, open)

	if !disk.Crashed() {
		return false, 0, 0
	}
	rec, err := Recover(dir, vector.CosineDistance, 1)
	if err != nil {
		t.Fatalf("cut point %d: recovery refused to open a directory the engine wrote: %v", k, err)
	}
	return true, disk.BytesCut(), countIntactRecords(t, rec.Store, acked)
}

// countCheckpointWrites runs one checkpoint with nothing armed and reports how
// many writes the injecting layer saw, which is the axis the sweep walks.
func countCheckpointWrites(t *testing.T, acked int) int {
	t.Helper()

	dir := t.TempDir()
	disk := faultio.NewDisk(faultio.SyncFsync)
	open := disk.Opener()

	lastLSN, snap := seedWALForCheckpoint(t, dir, acked, open)
	before := disk.Writes()
	if err := checkpointWith(dir, snap, lastLSN, open); err != nil {
		t.Fatalf("the checkpoint failed on a tree with no crash armed: %v", err)
	}
	return disk.Writes() - before
}

// countIntactRecords reports how many of the acknowledged records came back
// with the ID AND the payload they were written with. Counting the store
// instead would pass a recovery that returned the right number of wrong
// vectors, which is a defect this arm is meant to see rather than one it is
// allowed to skip.
func countIntactRecords(t *testing.T, store *vector.Store, acked int) int {
	t.Helper()

	intact := 0
	for i := 0; i < acked; i++ {
		want := vector.Vector{ID: uint64(i + 1), Data: []float32{float32(i), 1, 2, 3}}
		got, err := store.Get(want.ID)
		if err != nil {
			continue
		}
		if len(got.Data) != len(want.Data) {
			continue
		}
		same := true
		for j := range want.Data {
			if got.Data[j] != want.Data[j] {
				same = false
				break
			}
		}
		if same {
			intact++
		}
	}
	return intact
}

// seedWALForCheckpoint writes acked records through the real WAL under the
// given opener, fsyncing before each acknowledgement, and returns the last LSN
// and an index snapshot covering all of them.
func seedWALForCheckpoint(t *testing.T, dir string, acked int, open faultio.Opener) (uint64, hnsw.IndexSnapshot) {
	t.Helper()

	wal, err := openWALWith(dir, FsyncAlways, defaultSegmentBytes, open)
	if err != nil {
		t.Fatalf("opening the wal: %v", err)
	}
	idx, store := buildTestIndex(t, 0, 4)

	var lastLSN uint64
	for i := 0; i < acked; i++ {
		v := vector.Vector{ID: uint64(i + 1), Data: []float32{float32(i), 1, 2, 3}}
		lsn, aerr := wal.Append(OpUpsert, v)
		if aerr != nil {
			t.Fatalf("appending record %d: %v", i, aerr)
		}
		lastLSN = lsn
		if serr := store.Insert(v); serr != nil {
			t.Fatalf("seeding the store with record %d: %v", i, serr)
		}
		if ierr := idx.Insert(v.ID); ierr != nil {
			t.Fatalf("seeding the index with record %d: %v", i, ierr)
		}
	}
	if cerr := wal.Close(); cerr != nil {
		t.Fatalf("closing the wal: %v", cerr)
	}
	return lastLSN, idx.Export()
}
