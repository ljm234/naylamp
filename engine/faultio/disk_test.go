package faultio

import (
	"errors"
	"math/rand/v2"
	"os"
	"path/filepath"
	"testing"
)

// These tests pin the instrument itself. Every other durability test in the
// tree reads a verdict off this package, so a failure here has to point at the
// injector rather than at whatever engine was being measured with it.

// mustOpen opens path on the disk for appending and fails the test if it cannot.
func mustOpen(t *testing.T, d *Disk, path string) File {
	t.Helper()
	f, err := d.Opener()(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open %s: %v", path, err)
	}
	return f
}

func mustWrite(t *testing.T, f File, s string) {
	t.Helper()
	if _, err := f.Write([]byte(s)); err != nil {
		t.Fatalf("write %q: %v", s, err)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path) //nolint:gosec // path is a test temp dir
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

// TestDisk_CrashKeepsExactlyWhatWasSynced is the assertion the whole package
// exists to support: after a crash the file holds the bytes that were fsynced
// and not one byte more.
func TestDisk_CrashKeepsExactlyWhatWasSynced(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "durable-")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, f, "lost-in-the-power-cut")

	// Before the crash the bytes are on the filesystem, exactly as they would
	// be in the page cache. The instrument does not hide them.
	if got := readFile(t, path); got != "durable-lost-in-the-power-cut" {
		t.Fatalf("write-through broken: file holds %q", got)
	}

	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if got := readFile(t, path); got != "durable-" {
		t.Fatalf("after crash: file holds %q, want %q", got, "durable-")
	}
}

// TestDisk_SecondSyncMovesTheBoundary checks the boundary tracks the last Sync
// and not the first, which is the difference between an instrument and a
// one-shot trick.
func TestDisk_SecondSyncMovesTheBoundary(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	for _, chunk := range []string{"one.", "two.", "three."} {
		mustWrite(t, f, chunk)
		if err := f.Sync(); err != nil {
			t.Fatalf("sync: %v", err)
		}
	}
	mustWrite(t, f, "tail")
	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if got := readFile(t, path); got != "one.two.three." {
		t.Fatalf("after crash: file holds %q", got)
	}
}

// TestDisk_LoseSuffixNeverEatsSyncedBytes runs the seeded policy over many
// draws. The cut may land anywhere in the unsynced region, including inside a
// record, but it may never reach below the last fsync: that is the property
// that makes an acknowledged write safe under this instrument.
func TestDisk_LoseSuffixNeverEatsSyncedBytes(t *testing.T) {
	const synced = "0123456789"
	const unsynced = "abcdefghijklmnop"

	sawPartial := false
	for seed := uint64(1); seed <= 200; seed++ {
		dir := t.TempDir()
		path := filepath.Join(dir, "log")
		d := NewDisk(SyncFsync)

		f := mustOpen(t, d, path)
		mustWrite(t, f, synced)
		if err := f.Sync(); err != nil {
			t.Fatalf("seed %d: sync: %v", seed, err)
		}
		mustWrite(t, f, unsynced)

		rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic draw for a reproducible cut, not security
		if err := d.Crash(LoseSuffixAt(rng)); err != nil {
			t.Fatalf("seed %d: crash: %v", seed, err)
		}

		got := readFile(t, path)
		if len(got) < len(synced) || len(got) > len(synced)+len(unsynced) {
			t.Fatalf("seed %d: survived %d bytes, outside [%d, %d]", seed, len(got), len(synced), len(synced)+len(unsynced))
		}
		if got[:len(synced)] != synced {
			t.Fatalf("seed %d: the fsynced prefix was damaged: %q", seed, got[:len(synced)])
		}
		if want := synced + unsynced[:len(got)-len(synced)]; got != want {
			t.Fatalf("seed %d: survivors are not a prefix: got %q want %q", seed, got, want)
		}
		if len(got) > len(synced) && len(got) < len(synced)+len(unsynced) {
			sawPartial = true
		}
	}
	// Without this the test would pass against a policy that always cut at
	// durable, which is the other policy wearing this one's name.
	if !sawPartial {
		t.Fatal("every seed survived whole or died whole: LoseSuffixAt is not drawing from the unsynced region")
	}
}

// TestDisk_CrashVisitsFilesInSortedOrder is the guard for the sort in Crash,
// and it asks the question directly instead of inferring it.
//
// The first version of this guard ran the same seed twice and demanded the same
// bytes back, reasoning that Go's randomized map iteration would produce a
// different order on one of the two runs. It usually does. A mutation run caught
// it not doing so: with five files the two iterations coincided, the cuts
// matched, and a Crash with no sort at all came out green. A guard that catches
// its bug most of the time is a guard that reports a coin flip as a verdict.
//
// So the policy records the order it is called in, and the assertion is that
// order. Remove the sort and this fails on the first run where the map hands
// back anything but ascending paths, which is nearly every run, and it fails on
// the reason rather than on a downstream symptom.
func TestDisk_CrashVisitsFilesInSortedOrder(t *testing.T) {
	dir := t.TempDir()
	d := NewDisk(SyncFsync)

	// Deliberately created in an order that is neither sorted nor its reverse.
	created := []string{"gamma", "alpha", "epsilon", "beta", "delta"}
	for _, name := range created {
		f := mustOpen(t, d, filepath.Join(dir, name))
		mustWrite(t, f, "synced")
		if err := f.Sync(); err != nil {
			t.Fatalf("sync %s: %v", name, err)
		}
		mustWrite(t, f, "unsynced tail")
	}

	var visited []string
	recording := func(path string, durable, _ int64) int64 {
		visited = append(visited, filepath.Base(path))
		return durable
	}
	if err := d.Crash(recording); err != nil {
		t.Fatalf("crash: %v", err)
	}

	want := []string{"alpha", "beta", "delta", "epsilon", "gamma"}
	if len(visited) != len(want) {
		t.Fatalf("the policy saw %d files, want %d: %v", len(visited), len(want), visited)
	}
	for i := range want {
		if visited[i] != want[i] {
			t.Fatalf("the policy was called in order %v, want %v", visited, want)
		}
	}
}

// TestDisk_SameSeedSameCuts is the end-to-end half: one seed, one set of bytes,
// every time. The sort is what makes it hold, and the guard for the sort itself
// is the test above.
func TestDisk_SameSeedSameCuts(t *testing.T) {
	run := func(seed uint64) []string {
		dir := t.TempDir()
		d := NewDisk(SyncFsync)
		names := []string{"alpha", "beta", "gamma", "delta", "epsilon"}
		for _, name := range names {
			f := mustOpen(t, d, filepath.Join(dir, name))
			mustWrite(t, f, "synced-part")
			if err := f.Sync(); err != nil {
				t.Fatalf("sync %s: %v", name, err)
			}
			mustWrite(t, f, "unsynced-tail-of-some-length")
		}
		rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic draw for a reproducible cut, not security
		if err := d.Crash(LoseSuffixAt(rng)); err != nil {
			t.Fatalf("crash: %v", err)
		}
		out := make([]string, 0, len(names))
		for _, name := range names {
			out = append(out, readFile(t, filepath.Join(dir, name)))
		}
		return out
	}

	first, second := run(7), run(7)
	for i := range first {
		if first[i] != second[i] {
			t.Fatalf("file %d differs between runs of the same seed: %q vs %q", i, first[i], second[i])
		}
	}
	if run(7)[0] == run(8)[0] && run(7)[1] == run(8)[1] && run(7)[2] == run(8)[2] {
		t.Fatal("seeds 7 and 8 produced the same cuts on three files: the seed is not reaching the policy")
	}
}

// TestDisk_RefusesWorkAfterTheCrash keeps a test from carrying on inside a
// machine that is gone.
func TestDisk_RefusesWorkAfterTheCrash(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "before")
	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if !d.Crashed() {
		t.Fatal("Crashed reports false after a crash")
	}
	if _, err := f.Write([]byte("after")); !errors.Is(err, ErrPowerLost) {
		t.Fatalf("write after crash returned %v, want ErrPowerLost", err)
	}
	if err := f.Sync(); !errors.Is(err, ErrPowerLost) {
		t.Fatalf("sync after crash returned %v, want ErrPowerLost", err)
	}
	if _, err := d.Opener()(filepath.Join(dir, "another"), os.O_CREATE|os.O_WRONLY, 0o600); !errors.Is(err, ErrPowerLost) {
		t.Fatalf("open after crash returned %v, want ErrPowerLost", err)
	}
	if err := d.Crash(LoseAllUnsynced()); !errors.Is(err, ErrPowerLost) {
		t.Fatalf("second crash returned %v, want ErrPowerLost", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close after crash returned %v, want nil", err)
	}
}

// TestDisk_ArmedCrashFiresMidStream covers the window that matters. The write
// that trips the crash succeeds, because it did reach the page cache. The fsync
// that would have made it durable is the first thing to fail.
func TestDisk_ArmedCrashFiresMidStream(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "first.")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if err := d.ArmCrashAfter(1, LoseAllUnsynced()); err != nil {
		t.Fatalf("arm: %v", err)
	}

	n, err := f.Write([]byte("second."))
	if err != nil {
		t.Fatalf("the write that trips the crash reported %v, want success", err)
	}
	if n != len("second.") {
		t.Fatalf("the tripping write reported %d bytes, want %d", n, len("second."))
	}
	if !d.Crashed() {
		t.Fatal("the armed crash did not fire")
	}
	if err := f.Sync(); !errors.Is(err, ErrPowerLost) {
		t.Fatalf("the fsync after the crash returned %v, want ErrPowerLost", err)
	}
	if got := readFile(t, path); got != "first." {
		t.Fatalf("after the armed crash: file holds %q, want %q", got, "first.")
	}
	if d.Writes() != 2 {
		t.Fatalf("Writes reports %d, want 2", d.Writes())
	}
}

// TestDisk_ArmingRejectsANonPositiveCount keeps a caller from arming a crash
// that silently never fires, which would turn a durability test green by
// removing the fault rather than surviving it.
func TestDisk_ArmingRejectsANonPositiveCount(t *testing.T) {
	d := NewDisk(SyncFsync)
	if err := d.ArmCrashAfter(0, LoseAllUnsynced()); err == nil {
		t.Fatal("arming with a count of zero was accepted")
	}
	if d.Crashed() {
		t.Fatal("a rejected arming crashed the disk")
	}
}

// TestDisk_RejectsACutBelowTheFsync guards the one thing a policy must never
// do. Eating fsynced bytes would model a filesystem that loses acknowledged
// data, and a green obtained that way would be about a different claim.
func TestDisk_RejectsACutBelowTheFsync(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "0123456789")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	rogue := func(_ string, durable, _ int64) int64 { return durable - 1 }
	if err := d.Crash(rogue); err == nil {
		t.Fatal("a cut below the fsync boundary was accepted")
	}
	if got := readFile(t, path); got != "0123456789" {
		t.Fatalf("the rejected cut still damaged the file: %q", got)
	}
}

// TestDisk_TruncatingOpenIsNotDurable covers the temp files in the snapshot,
// manifest and hard state paths: a truncation nobody fsynced is worth as much
// as a write nobody fsynced.
func TestDisk_TruncatingOpenIsNotDurable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "temp")
	if err := os.WriteFile(path, []byte("stale content from a previous life"), 0o600); err != nil {
		t.Fatalf("seed the file: %v", err)
	}
	d := NewDisk(SyncFsync)
	f, err := d.Opener()(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustWrite(t, f, "fresh")
	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if got := readFile(t, path); got != "" {
		t.Fatalf("after crash: temp file holds %q, want empty", got)
	}
}

// TestDisk_ReopenDoesNotLaunderUnsyncedBytes stops the boundary from being
// reset upward by the act of reopening: bytes an earlier handle never made
// durable do not become durable because a later handle found them on disk.
func TestDisk_ReopenDoesNotLaunderUnsyncedBytes(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "synced")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, f, "never-synced")
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	f2 := mustOpen(t, d, path)
	mustWrite(t, f2, "-more")
	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if got := readFile(t, path); got != "synced" {
		t.Fatalf("after crash: file holds %q, want %q", got, "synced")
	}
}

// TestDisk_RenamedAwayFileIsNotAnError covers the atomic-write pattern the tree
// uses for snapshots, manifests and hard state: write to a temp path, fsync it,
// rename it into place. The temp path is gone by crash time, which is the
// pattern working rather than a fault.
func TestDisk_RenamedAwayFileIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	tmp := filepath.Join(dir, "MANIFEST.tmp")
	final := filepath.Join(dir, "MANIFEST")
	d := NewDisk(SyncFsync)

	f, err := d.Opener()(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	mustWrite(t, f, "committed")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := os.Rename(tmp, final); err != nil {
		t.Fatalf("rename: %v", err)
	}

	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash over a renamed-away temp: %v", err)
	}
	if got := readFile(t, final); got != "committed" {
		t.Fatalf("the renamed file holds %q, want %q", got, "committed")
	}
}

// TestDisk_FollowsAFileThroughARename is the guard for the hole an adversarial
// review found and the reason the Disk stopped keying on paths.
//
// The tree replaces its hard state, its snapshots and its manifest by writing a
// temp file, fsyncing it and renaming it into place. Keyed on the temp path, the
// crash found nothing there and skipped the file, so those four writers were
// laundered: deleting the fsync from raft.SaveHardState left every package
// green, and that fsync is what stops a node from forgetting its vote.
func TestDisk_FollowsAFileThroughARename(t *testing.T) {
	for _, tc := range []struct {
		name  string
		sync  bool
		final string
	}{
		{"fsynced before the rename survives", true, "committed"},
		{"not fsynced before the rename does not", false, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			tmp := filepath.Join(dir, "state.tmp")
			final := filepath.Join(dir, "state")
			d := NewDisk(SyncFsync)

			f, err := d.Opener()(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			mustWrite(t, f, "committed")
			if tc.sync {
				if serr := f.Sync(); serr != nil {
					t.Fatalf("sync: %v", serr)
				}
			}
			if cerr := f.Close(); cerr != nil {
				t.Fatalf("close: %v", cerr)
			}
			if rerr := os.Rename(tmp, final); rerr != nil {
				t.Fatalf("rename: %v", rerr)
			}

			if cerr := d.Crash(LoseAllUnsynced()); cerr != nil {
				t.Fatalf("crash: %v", cerr)
			}
			if got := readFile(t, final); got != tc.final {
				t.Fatalf("after the crash the renamed file holds %q, want %q", got, tc.final)
			}
		})
	}
}

// TestDisk_CutPathsNamesOnlyWhatItCut is the guard for the accessor a cluster
// arm leans on to say WHERE its fault landed. A reviewer moved the append one
// block outward so every visited file reported as cut, and the whole suite
// stayed green: that guard could no longer fail.
func TestDisk_CutPathsNamesOnlyWhatItCut(t *testing.T) {
	dir := t.TempDir()
	clean := filepath.Join(dir, "aaa-fully-synced")
	dirty := filepath.Join(dir, "zzz-has-a-tail")
	d := NewDisk(SyncFsync)

	cf := mustOpen(t, d, clean)
	mustWrite(t, cf, "all of this crossed the barrier")
	if err := cf.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}

	df := mustOpen(t, d, dirty)
	mustWrite(t, df, "synced")
	if err := df.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, df, "and this did not")

	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}

	got := d.CutPaths()
	if len(got) != 1 || filepath.Base(got[0]) != "zzz-has-a-tail" {
		t.Fatalf("CutPaths reports %v, want only the file that lost bytes", got)
	}
	if n := d.BytesCut(); n != int64(len("and this did not")) {
		t.Fatalf("BytesCut reports %d, want %d", n, len("and this did not"))
	}
}

// TestDisk_AFailedBarrierDoesNotMoveTheMark pins what diskFile.Sync's comment
// promises and nothing checked. The false direction here is the dangerous one:
// a mark that advances on a failed fsync would call unsynced bytes durable, on
// exactly the EIO or ENOSPC the promise is about.
//
// It substitutes the Disk's barrier rather than breaking the descriptor, and the
// first version did the opposite and was worthless for it. Closing the file out
// from under the handle makes the Stat fail too, so Sync bailed one line later
// than the line under test and the mutation that inverts the ordering survived.
func TestDisk_AFailedBarrierDoesNotMoveTheMark(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log")
	d := NewDisk(SyncFsync)

	f := mustOpen(t, d, path)
	mustWrite(t, f, "this much crossed")
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, f, " and this much did not")

	// From here the medium refuses. The file is otherwise healthy, so Stat keeps
	// answering and the only thing that fails is the barrier itself.
	sick := errors.New("the medium refused the barrier")
	d.barrier = func(*os.File) error { return sick }

	if err := f.Sync(); !errors.Is(err, sick) {
		t.Fatalf("sync returned %v, want the barrier's own failure", err)
	}

	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("crash: %v", err)
	}
	if got := readFile(t, path); got != "this much crossed" {
		t.Fatalf("a failed barrier moved the durable mark: the file kept %q", got)
	}
}

// TestDisk_UnlinkedFileIsSkipped covers the branch that decides what a crash
// does about a file which is no longer there. A checkpoint reclaiming a covered
// segment leaves nothing to cut, and treating that as a fault would turn routine
// space reclamation into a failed crash.
//
// It exists because the branch had no test and the mutation that claimed to
// cover it did not compile, so the harness scored a build failure as a red. A
// red that any test name produces is not evidence about any of them.
//
// Remove the guard and this fails as a panic rather than as an assertion, since
// resolve returns a nil FileInfo for a file that is gone and the size read below
// it dereferences that nil. The panic names disk.go, so it points where it
// should, and saying it here is cheaper than leaving the next reader to wonder
// whether a crashing test counts.
func TestDisk_UnlinkedFileIsSkipped(t *testing.T) {
	dir := t.TempDir()
	gone := filepath.Join(dir, "reclaimed")
	kept := filepath.Join(dir, "still-here")
	d := NewDisk(SyncFsync)

	gf := mustOpen(t, d, gone)
	mustWrite(t, gf, "synced")
	if err := gf.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, gf, "a tail nobody will ever read")
	if err := gf.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if err := os.Remove(gone); err != nil {
		t.Fatalf("reclaim: %v", err)
	}

	kf := mustOpen(t, d, kept)
	mustWrite(t, kf, "synced")
	if err := kf.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	mustWrite(t, kf, "and this did not")

	if err := d.Crash(LoseAllUnsynced()); err != nil {
		t.Fatalf("a crash over a reclaimed file reported %v, want success", err)
	}
	if _, err := os.Stat(gone); !os.IsNotExist(err) {
		t.Fatalf("the reclaimed file came back: %v", err)
	}
	if got := readFile(t, kept); got != "synced" {
		t.Fatalf("the surviving file was not cut: it holds %q", got)
	}
	for _, p := range d.CutPaths() {
		if filepath.Base(p) == "reclaimed" {
			t.Fatalf("CutPaths names a file that no longer exists: %v", d.CutPaths())
		}
	}
}
