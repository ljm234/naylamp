// Package faultio is the seam between Naylamp's durable write paths and the
// files they write to, plus the fault injector that makes the durability claim
// falsifiable.
//
// Two things live here and they are not the same thing.
//
// The seam is production code. File is the subset of *os.File that the WAL and
// the Raft entry log actually use, and Opener is how they get one. With
// SyncFsync, OSOpener hands back the *os.File itself, so the production path
// gains an interface dispatch and nothing else: no wrapper and no buffering of
// its own.
//
// The injector is a test instrument. Disk hands out files that write straight
// through to the real filesystem while remembering, per file, the size at the
// last Sync that returned. Crash cuts every file back into its unsynced region,
// which is what a machine that lost power leaves behind. Without it the crash
// tests cannot tell an engine that fsyncs from one that does not, because
// dropping a Go handle does not evict the operating system's page cache.
//
// # What the model covers, and what it does not
//
// Covered: the loss of bytes written and not fsynced, with Sync as the barrier.
// Everything before a Sync that returned survives; anything after it may not.
// Files are independent of each other.
//
// Not covered, and each of these is a separate axis:
//
//  1. Reordering. This is the prefix crash model, the standard one in the
//     literature: a crash state is a prefix of what was written. A real device
//     or writeback can persist a later page and lose an earlier one, leaving a
//     hole, and this package never produces that state. Along the ordering axis
//     the model is strictly poorer than reality, so a green here is a green
//     about prefixes, not about every crash the hardware can produce.
//  2. The drive's volatile cache. The model assumes Sync is a real barrier. On
//     macOS, fsync(2) is not: it hands the bytes to the drive without asking it
//     to flush its own cache. That is what F_FULLFSYNC is for, and it is why
//     SyncFull exists in this package. The two halves are complementary and
//     neither substitutes for the other: the injector proves the code USES the
//     barrier, F_FULLFSYNC makes the barrier EXIST.
//  3. Directory metadata. Renames, removes and the directory's own fsync are
//     not intercepted, and the model treats them as durable the instant they
//     happen, which is optimistic. A missing directory fsync cannot be caught
//     here; see DEFER-028 for the one this analysis found.
//  4. Torn sectors, bit rot and partial page writes, which are already the job
//     of the byte-sabotage tests in engine/persist.
package faultio

import (
	"io"
	"os"
	"sync/atomic"
)

// File is what a durable write path needs from the file it appends to. It is
// deliberately the union of what the two carriers use and nothing more.
//
// Write, Sync and Close are self-evident. Seek is here for one caller and one
// reason: raft.OpenStorage reopens the active segment with O_RDWR and seeks to
// the end to learn its size and to position the write offset (storage.go). The
// WAL opens with O_APPEND and never seeks. Truncate is absent for the mirror of
// that reason: both engines truncate a torn tail during recovery, after the
// crash, through their own handles opened by path, never through this one.
//
// *os.File satisfies this interface directly, which is what keeps the
// production path free of wrappers.
type File interface {
	io.Writer
	io.Seeker
	Sync() error
	Close() error
}

// Opener opens a file for appending. The signature is os.OpenFile's on purpose:
// callers that hold one can swap it for a fault-injecting Disk without changing
// a single call site.
type Opener func(path string, flag int, perm os.FileMode) (File, error)

// SyncMode selects which barrier a file's Sync issues.
type SyncMode uint8

const (
	// SyncFsync issues fsync(2). On Linux this pushes the data to the device;
	// on macOS it stops one layer short, at the drive's own volatile cache.
	SyncFsync SyncMode = iota
	// SyncFull issues the strongest barrier the platform offers: F_FULLFSYNC on
	// darwin, which asks the drive to flush its cache to the physical medium.
	// Everywhere else it degrades to fsync(2), and FullSyncSupported says so
	// rather than letting the caller assume otherwise.
	SyncFull
)

// fullSyncs counts the calls to FullSync this process has made. It is real
// observability, since an operator can ask how many strong barriers were paid
// for, and one atomic add against a barrier that costs milliseconds is not a
// measurable price.
//
// It counts CALLS, not fcntls. FullSync increments it whatever its body does,
// so a body rewritten as f.Sync() keeps the number moving, and a test that reads
// this cannot tell the two apart. That is why the guard against a degraded body
// is fullsync_darwin_test.go and not this counter. The distinction is written
// here because a previous version of these comments got it wrong.
var fullSyncs atomic.Uint64

// FullSyncCount returns how many full barriers this process has issued through
// FullSync. It never decreases and it is not reset.
func FullSyncCount() uint64 { return fullSyncs.Load() }

// OSOpener opens a real file whose Sync is fsync(2). This is what every
// production caller uses, and it returns the *os.File unwrapped.
func OSOpener(path string, flag int, perm os.FileMode) (File, error) {
	f, err := os.OpenFile(path, flag, perm) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return nil, err
	}
	return f, nil
}

// OSOpenerMode returns an Opener whose files sync with the given mode.
// SyncFsync returns OSOpener itself, so asking for the default costs nothing.
func OSOpenerMode(mode SyncMode) Opener {
	if mode != SyncFull {
		return OSOpener
	}
	return func(path string, flag int, perm os.FileMode) (File, error) {
		f, err := os.OpenFile(path, flag, perm) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
		if err != nil {
			return nil, err
		}
		return fullSyncFile{f}, nil
	}
}

// fullSyncFile is an *os.File whose Sync asks for the full barrier. Everything
// else is the embedded file's own method.
type fullSyncFile struct{ *os.File }

// Sync is the only method that differs from the embedded file's.
func (f fullSyncFile) Sync() error { return FullSync(f.File) }
