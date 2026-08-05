//go:build darwin

package faultio

import (
	"errors"
	"os"
	"syscall"
	"testing"
)

// These two exist because an earlier version of this package claimed more than
// it could show. It said degrading FullSync back to fsync(2) would go red, and
// the only check behind that was a counter FullSync increments itself, so the
// counter moved either way and the claim was empty. An adversarial review made
// exactly that edit and the package stayed green.
//
// What follows is what can actually be observed from inside the process, and it
// is less than the old sentence promised.
//
// The honest ceiling, stated once here and repeated in the docs: NOTHING running
// on this machine can show that the drive flushed its cache to the medium. Both
// calls return zero on a healthy regular file and leave no trace behind them.
// Showing it needs a power cut and an observer outside the box.
//
// And a second limit, about where these run rather than what they prove: the
// build tag is darwin and CI is ubuntu, so CI never executes either of them. A
// green pipeline says nothing about the F_FULLFSYNC path. These are a local
// guard, and whoever changes fullsync_darwin.go has to run the darwin suite by
// hand or the change ships unchecked.

// TestFullSync_DoesNotRouteThroughFileSync catches the degradation that matters,
// and it catches it by type rather than by errno.
//
// On a device that supports neither barrier, both calls fail with the same
// errno. They do not fail with the same Go error: os.File.Sync wraps its errno
// in an *os.PathError with the file's name in it, and the fcntl path returns the
// bare syscall.Errno. So an implementation that quietly became f.Sync() is
// visible here even though the operating system saw an equivalent failure.
//
// What this does NOT establish: that the command reached the drive. It
// establishes that the call did not go through os.File.Sync.
func TestFullSync_DoesNotRouteThroughFileSync(t *testing.T) {
	f, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		t.Fatalf("open %s: %v", os.DevNull, err)
	}
	defer func() { _ = f.Close() }()

	// The premise the discrimination rests on: this device refuses both
	// barriers. If some future platform starts accepting them, the check below
	// would pass for the wrong reason, so the premise is asserted rather than
	// assumed.
	var pathErr *os.PathError
	if serr := f.Sync(); !errors.As(serr, &pathErr) {
		t.Skipf("%s accepted fsync(2) (%v), so it can no longer tell the two paths apart", os.DevNull, serr)
	}

	ferr := FullSync(f)
	if ferr == nil {
		t.Fatalf("%s refused fsync(2) but accepted the full barrier, which no single implementation can do", os.DevNull)
	}
	if errors.As(ferr, &pathErr) {
		t.Fatalf("the full barrier returned %T: it routed through os.File.Sync instead of issuing the fcntl", ferr)
	}
	var errno syscall.Errno
	if !errors.As(ferr, &errno) {
		t.Fatalf("the full barrier returned %T (%v), want a bare syscall.Errno from the fcntl", ferr, ferr)
	}
}

// TestFullSync_UsesACommandARegularFileAccepts pins the command number. Every
// neighbouring fcntl constant tried against a regular file (50, 52, 37, 99)
// comes back with an errno; F_FULLFSYNC comes back clean. So a typo in the
// constant shows up here, which the type check above would miss because a wrong
// command also returns a bare errno.
//
// The pair is the whole guard, and the pair still stops short of the medium.
func TestFullSync_UsesACommandARegularFileAccepts(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "barrier")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	defer func() { _ = f.Close() }()
	if _, werr := f.Write([]byte("bytes for the barrier to carry")); werr != nil {
		t.Fatalf("write: %v", werr)
	}
	if ferr := FullSync(f); ferr != nil {
		t.Fatalf("the full barrier failed on a plain regular file: %v", ferr)
	}
}
