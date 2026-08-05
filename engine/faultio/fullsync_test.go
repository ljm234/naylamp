package faultio

import (
	"os"
	"path/filepath"
	"testing"
)

// What these tests can and cannot establish, said here rather than left for a
// reader to work out.
//
// What they reach: fullSyncFile.Sync dispatches to FullSync rather than to the
// embedded file's Sync, the default mode does not pay for the strong barrier,
// and a Disk in SyncFull mode pays for it. That is DISPATCH coverage and no
// more, because the counter these read is incremented by FullSync itself, so it
// moves whatever FullSync's body does.
//
// What they do NOT reach, said plainly because an earlier version of this
// comment claimed otherwise and a reviewer disproved it in one edit: whether
// FullSync's body issues the fcntl at all. Rewriting that body as f.Sync() and
// keeping the counter leaves every test in this file green. The guard against
// that lives in fullsync_darwin_test.go, and it works by error type rather than
// by counting.
//
// What nothing on this machine reaches: whether the drive committed the bytes to
// the physical medium. Proving that needs a power cut and an observer outside
// the box. Phase 2's durability numbers were measured against fsync(2), which
// on macOS is one layer short of the medium.
//
// None of the three may be given t.Parallel. They read a process-wide counter
// before and after and assert the exact delta, so a second test issuing a
// barrier at the same moment would move the number under them. The exact delta
// is what makes them worth having, so the constraint is written down rather
// than traded away for a >= that a degraded branch could still satisfy.

// TestFullSync_TakesTheStrongBranch pins the dispatch: degrade fullSyncFile.Sync
// to call the embedded file's Sync and the count stops moving. It says nothing
// about what FullSync does once it is reached.
func TestFullSync_TakesTheStrongBranch(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "barrier")

	before := FullSyncCount()

	open := OSOpenerMode(SyncFull)
	f, err := open(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := f.Write([]byte("bytes that want to reach the medium")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := f.Sync(); err != nil {
		t.Fatalf("full sync on a real file: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if got := FullSyncCount(); got != before+1 {
		t.Fatalf("full sync count went %d -> %d: the strong branch was not taken", before, got)
	}
}

// TestFullSync_DefaultModeStaysOnFsync is the other half: asking for the
// default must not quietly pay for the strong barrier, and OSOpenerMode must
// hand back the plain opener rather than a wrapper.
func TestFullSync_DefaultModeStaysOnFsync(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "plain")

	before := FullSyncCount()

	f, err := OSOpenerMode(SyncFsync)(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := f.Write([]byte("ordinary bytes")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	if got := FullSyncCount(); got != before {
		t.Fatalf("full sync count moved %d -> %d under SyncFsync", before, got)
	}
	// The production path is the *os.File itself, with no wrapper in the way.
	// If this ever stops holding, the claim that the seam costs nothing but an
	// interface dispatch stops holding with it.
	//
	// It asks what the value IS rather than what it is not. An earlier version
	// excluded the one wrapper this package happens to define, which a reviewer
	// walked straight past by returning a different one.
	if _, plain := f.(*os.File); !plain {
		t.Fatalf("SyncFsync handed back %T, not the *os.File itself", f)
	}
}

// TestFullSync_DiskUsesTheModeItWasGiven keeps the injector honest: a Disk in
// SyncFull mode has to pay for the strong barrier too, otherwise a durability
// run under that mode would be measuring the weak one.
func TestFullSync_DiskUsesTheModeItWasGiven(t *testing.T) {
	dir := t.TempDir()
	d := NewDisk(SyncFull)

	before := FullSyncCount()
	f, err := d.Opener()(filepath.Join(dir, "log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if _, err := f.Write([]byte("x")); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := f.Sync(); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if got := FullSyncCount(); got != before+1 {
		t.Fatalf("full sync count went %d -> %d: the Disk ignored SyncFull", before, got)
	}
}

// TestFullSync_SupportIsReportedNotAssumed records what this platform actually
// offers, so a run's log says which barrier the numbers were measured against
// instead of leaving it to be inferred from the operating system.
func TestFullSync_SupportIsReportedNotAssumed(t *testing.T) {
	if FullSyncSupported {
		t.Log("this platform issues F_FULLFSYNC: Sync asks the drive to flush its own cache")
	} else {
		t.Log("this platform has no stronger barrier than fsync(2): FullSync degrades and says so")
	}
}
