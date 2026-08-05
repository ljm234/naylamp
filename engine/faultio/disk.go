package faultio

import (
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

// ErrPowerLost is what a crashed Disk returns to anything that tries to keep
// writing. A machine that lost power does not accept writes, and refusing them
// is what stops a test from continuing inside a world that no longer exists.
var ErrPowerLost = errors.New("faultio: the simulated machine lost power")

// Disk is a fault-injecting stand-in for the file system underneath a durable
// write path. It is a TEST INSTRUMENT: nothing in production opens one.
//
// It writes through. Every Write reaches the real file immediately, exactly as
// a write(2) reaches the page cache, so a concurrent reader sees what it would
// see in production and no behavior diverges. What the Disk adds is a single
// number per file, the size at the last Sync that returned, which is the fsync
// boundary itself. Crash cuts each file back into the region past that number.
//
// The number comes from Stat rather than from counting bytes on the way past.
// Counting would work and would also introduce a class of accounting bug that
// an instrument meant to adjudicate durability cannot afford.
//
// FILES ARE FOLLOWED BY IDENTITY, NOT BY NAME, and that is not a refinement.
// An earlier version keyed everything on the path it was opened under, and an
// adversarial review showed what that costs: the tree replaces its hard state,
// its snapshots and its manifest by writing a temp file, fsyncing it and
// renaming it into place, so at crash time the tracked name is gone and the
// bytes are living under a name the Disk never heard of. It skipped them. The
// consequence was measured, not reasoned: deleting the fsync from
// raft.SaveHardState left every package green, and that fsync is what stops a
// node from forgetting its vote and voting twice in one term. Following
// os.SameFile instead means a renamed file is found where it now lives and cut
// there, so the atomic-replace path is inside the model rather than laundered
// by it.
type Disk struct {
	mu      sync.Mutex
	mode    SyncMode
	tracked []*trackedFile
	handles []*diskFile
	crashed bool
	// barrier is how a Sync reaches the medium. The mode picks it, and it is a
	// field rather than a branch inside Sync for one reason: a barrier that
	// FAILS must leave the durable mark where it was, and no ordinary file on
	// this machine can be made to fail its fsync while still answering Stat, so
	// without a seam that property was documented and unprovable. A reviewer
	// inverted the ordering and nothing went red.
	barrier func(*os.File) error

	// armed counts writes remaining before an armed crash fires; zero means no
	// crash is armed. See ArmCrashAfter for why cutting power mid-stream is the
	// case that matters rather than a convenience.
	armed  int
	armCut CutPolicy
	writes int
	// bytesCut is how much the crash actually removed and cutPaths is where
	// from. A durability test reads them to prove the injector did something,
	// and to prove it did it to the file that carries the claim, because a
	// green obtained from an injector that removed nothing, or that removed
	// bytes from somewhere irrelevant, is the failure this package was built to
	// retire.
	bytesCut int64
	cutPaths []string
}

// trackedFile is one file on the simulated disk. It is identified by what
// os.SameFile compares rather than by a path, so a rename moves it instead of
// losing it, and reopening a name that now holds a different file starts a
// separate record instead of inheriting the old one's durability.
type trackedFile struct {
	info    os.FileInfo // identity at open time, the argument to os.SameFile
	dir     string      // where to look for it if its name no longer resolves
	path    string      // the name it was opened under, the first place to look
	durable int64       // size at its last Sync that returned
}

// NewDisk returns a Disk whose files sync with the given mode.
func NewDisk(mode SyncMode) *Disk {
	d := &Disk{mode: mode}
	d.barrier = d.realBarrier
	return d
}

// realBarrier is the barrier the mode asks for.
func (d *Disk) realBarrier(f *os.File) error {
	if d.mode == SyncFull {
		return FullSync(f)
	}
	return f.Sync()
}

// Opener returns the Opener to hand to the code under test.
func (d *Disk) Opener() Opener {
	return func(path string, flag int, perm os.FileMode) (File, error) {
		return d.open(path, flag, perm)
	}
}

// Crashed reports whether this Disk has already lost power.
func (d *Disk) Crashed() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.crashed
}

// Writes reports how many writes have reached this Disk, which is what a test
// measures on a first pass so it can arm a crash inside the second.
func (d *Disk) Writes() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.writes
}

// BytesCut reports how many bytes the crash removed, which is how a test proves
// the fault was real before it reads anything into the survival it observed.
func (d *Disk) BytesCut() int64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.bytesCut
}

// CutPaths reports which files lost bytes to the crash, in the sorted order
// Crash visited them. It is how a test states which file its fault landed on
// instead of inferring it from a byte count.
func (d *Disk) CutPaths() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.cutPaths...)
}

// ArmCrashAfter cuts the power once the given number of further writes have
// landed, rather than waiting for the caller to ask.
//
// This is the case worth testing, and the reason is that an engine which fsyncs
// before it acknowledges has NOTHING unsynced while it sits still: by the time
// an append returns, its bytes are already past the barrier. Crash it at rest
// and the injector removes nothing, so the green says only that the instrument
// did no damage. Cut the power between a record reaching the page cache and its
// fsync, which is the window an armed crash lands in, and there is real
// unsynced data on the floor: a half-written record the caller was never
// acknowledged for. Surviving that is the claim worth making.
//
// The write that trips the crash still succeeds and reports its bytes, because
// it did reach the page cache. What fails is everything after it, starting with
// the fsync that would have made it durable.
func (d *Disk) ArmCrashAfter(writes int, cut CutPolicy) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.crashed {
		return ErrPowerLost
	}
	if writes <= 0 {
		return fmt.Errorf("faultio: ArmCrashAfter needs a positive write count, got %d", writes)
	}
	d.armed, d.armCut = writes, cut
	return nil
}

func (d *Disk) open(path string, flag int, perm os.FileMode) (File, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.crashed {
		return nil, ErrPowerLost
	}
	f, err := os.OpenFile(path, flag, perm) //nolint:gosec // path is built from a caller-provided data dir, not untrusted input
	if err != nil {
		return nil, err
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("faultio: stat at open: %w", err)
	}

	tf := d.trackedByIdentity(fi)
	if tf == nil {
		tf = &trackedFile{info: fi, dir: filepath.Dir(path), path: path, durable: fi.Size()}
		d.tracked = append(d.tracked, tf)
	} else {
		// Reopening a file the Disk already knows. Its durable mark carries over
		// untouched: identity is what decides that, so what an earlier handle
		// never made durable does not become durable by being reopened, and the
		// mark needs no adjusting here.
		//
		// It used to be clamped down when the file had shrunk. A mutation run
		// showed that clamp could not change an outcome, because crashLocked
		// clamps against the size it reads at crash time anyway, which is the
		// only size that decides anything. Two clamps for one invariant, and
		// only one of them reachable. The redundant one is gone by the same rule
		// that removed the O_TRUNC branch: what no test can defend does not stay
		// in an instrument that adjudicates durability.
		tf.path, tf.dir = path, filepath.Dir(path)
	}

	df := &diskFile{disk: d, f: f, tf: tf}
	d.handles = append(d.handles, df)
	return df, nil
}

// trackedByIdentity finds the record for a file the Disk has already seen, or
// nil. It is linear over the files one scenario touches, which is a handful.
func (d *Disk) trackedByIdentity(fi os.FileInfo) *trackedFile {
	for _, tf := range d.tracked {
		if os.SameFile(tf.info, fi) {
			return tf
		}
	}
	return nil
}

// resolve returns where a tracked file lives now. It tries the name it was
// opened under first, then scans the directory for its identity, which is how a
// file that was fsynced under a temp name and renamed into place is found. A
// file that has been unlinked resolves to ok=false and is left alone.
func (tf *trackedFile) resolve() (string, os.FileInfo, bool) {
	if fi, err := os.Stat(tf.path); err == nil && os.SameFile(tf.info, fi) {
		return tf.path, fi, true
	}
	entries, err := os.ReadDir(tf.dir)
	if err != nil {
		return "", nil, false
	}
	for _, e := range entries {
		p := filepath.Join(tf.dir, e.Name())
		fi, serr := os.Stat(p)
		if serr == nil && os.SameFile(tf.info, fi) {
			return p, fi, true
		}
	}
	return "", nil, false
}

// Crash simulates a power loss: every file the Disk handed out is cut back to
// an offset the policy chooses inside its unsynced region, and the Disk dies,
// so nothing can write to it afterward.
//
// Files are visited in sorted order, not in map order, because a policy that
// draws from a seeded generator has to produce the same cut on every run and Go
// randomizes map iteration.
//
// A file that has been unlinked by now is skipped: a checkpoint reclaiming a
// covered segment leaves nothing to cut. A file that was RENAMED is not skipped,
// which it used to be. It is found under its new name and cut there.
//
// The policy is called with the Disk's lock held, so a policy that calls back
// into the Disk deadlocks. See CutPolicy.
func (d *Disk) Crash(cut CutPolicy) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.crashed {
		return ErrPowerLost
	}
	return d.crashLocked(cut)
}

// crashLocked is Crash with the lock already held, which is how an armed crash
// fires from inside a write.
func (d *Disk) crashLocked(cut CutPolicy) error {
	d.crashed = true
	d.armed = 0

	// Every descriptor goes with the machine, not just the newest one per name.
	// Closing them all also means no handle can write past a truncation and
	// punch a hole in a file the crash just cut.
	for _, df := range d.handles {
		_ = df.f.Close()
	}

	// Resolve where each tracked file lives now, then sort by that name. Order
	// has to be a function of the scenario and not of anything else, because a
	// policy drawing from a seeded generator must produce the same cut on every
	// run, and the tracking order would leak whatever order the engine happened
	// to open things in.
	type victim struct {
		path string
		size int64
		tf   *trackedFile
	}
	victims := make([]victim, 0, len(d.tracked))
	for _, tf := range d.tracked {
		path, fi, ok := tf.resolve()
		if !ok {
			continue // unlinked: a checkpoint reclaimed it, and there is nothing to cut
		}
		victims = append(victims, victim{path: path, size: fi.Size(), tf: tf})
	}
	sort.Slice(victims, func(i, j int) bool { return victims[i].path < victims[j].path })

	for _, v := range victims {
		durable := v.tf.durable
		if durable > v.size {
			durable = v.size
		}
		at := cut(v.path, durable, v.size)
		if at < durable || at > v.size {
			return fmt.Errorf("faultio: cut policy returned %d outside [%d, %d] for %s", at, durable, v.size, v.path)
		}
		if at < v.size {
			if err := os.Truncate(v.path, at); err != nil {
				return fmt.Errorf("faultio: truncate %s at crash: %w", v.path, err)
			}
			d.bytesCut += v.size - at
			d.cutPaths = append(d.cutPaths, v.path)
		}
	}
	return nil
}

// CutPolicy decides how much of one file's unsynced region survives the crash.
// durable is the size at that file's last Sync, size is its size right now, and
// the returned offset must land in [durable, size]. Returning durable loses the
// whole unsynced region; returning size loses nothing.
//
// A policy is never allowed below durable, and Crash rejects one that tries:
// everything at or under durable was fsynced. Losing it would model a
// filesystem that eats acknowledged data, and that is a different claim.
//
// IT MUST NOT TOUCH THE DISK. Crash holds the Disk's lock while it calls the
// policy, and that lock is not reentrant, so a policy that calls Crashed,
// Writes, BytesCut or anything on a file it was handed will hang rather than
// fail. Recording what it was called with is fine and is what the ordering
// guard does; asking the Disk anything is not.
type CutPolicy func(path string, durable, size int64) int64

// LoseAllUnsynced cuts every file back to its last fsync. This is the harshest
// reading of a power cut and the cheapest to reason about.
//
// It has one cost worth knowing before choosing it. Under FsyncAlways each
// record is fsynced whole, so the cut always lands on a record boundary and the
// torn-tail recovery path never runs.
func LoseAllUnsynced() CutPolicy {
	return func(_ string, durable, _ int64) int64 { return durable }
}

// LoseSuffixAt cuts at a point drawn uniformly from the unsynced region, which
// models a writeback that got partway through. The cut lands inside a record as
// often as not, so this exercises the torn-tail path that LoseAllUnsynced never
// reaches, and it still cannot touch an acknowledged write: acknowledgement
// comes after the fsync, so everything acknowledged is at or below durable.
// Prefer it whenever the torn-tail path is part of what is under test.
//
// The generator is the caller's, so a seed reproduces the whole scenario.
func LoseSuffixAt(rng *rand.Rand) CutPolicy {
	return func(_ string, durable, size int64) int64 {
		gap := size - durable
		if gap <= 0 {
			return durable
		}
		return durable + rng.Int64N(gap+1)
	}
}

// diskFile is one handle a Disk handed out. The durability mark lives on the
// trackedFile it points at, not here, so two handles on the same file agree
// about what has crossed the barrier.
type diskFile struct {
	disk *Disk
	f    *os.File
	tf   *trackedFile
}

func (df *diskFile) Write(p []byte) (int, error) {
	df.disk.mu.Lock()
	defer df.disk.mu.Unlock()
	if df.disk.crashed {
		return 0, ErrPowerLost
	}
	n, err := df.f.Write(p)
	if err != nil {
		return n, err
	}
	df.disk.writes++
	if df.disk.armed > 0 {
		df.disk.armed--
		if df.disk.armed == 0 {
			if cerr := df.disk.crashLocked(df.disk.armCut); cerr != nil {
				return n, cerr
			}
		}
	}
	return n, nil
}

func (df *diskFile) Seek(offset int64, whence int) (int64, error) {
	df.disk.mu.Lock()
	defer df.disk.mu.Unlock()
	if df.disk.crashed {
		return 0, ErrPowerLost
	}
	return df.f.Seek(offset, whence)
}

// Sync issues the real barrier and only then moves the durable mark, so a
// barrier that fails leaves the mark where it was, which is what the caller's
// error handling assumes.
func (df *diskFile) Sync() error {
	df.disk.mu.Lock()
	defer df.disk.mu.Unlock()
	if df.disk.crashed {
		return ErrPowerLost
	}
	if err := df.disk.barrier(df.f); err != nil {
		return err
	}
	fi, err := df.f.Stat()
	if err != nil {
		return fmt.Errorf("faultio: stat after sync: %w", err)
	}
	df.tf.durable = fi.Size()
	return nil
}

// Close after a crash reports success. The descriptor died with the machine,
// and closing is not a durability event, so failing here would only make
// cleanup paths report a fault that did not happen.
func (df *diskFile) Close() error {
	df.disk.mu.Lock()
	defer df.disk.mu.Unlock()
	if df.disk.crashed {
		return nil
	}
	return df.f.Close()
}
