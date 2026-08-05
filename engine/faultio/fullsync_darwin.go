//go:build darwin

package faultio

import (
	"fmt"
	"os"
	"syscall"
)

// FullSyncSupported reports whether FullSync issues a barrier stronger than
// fsync(2) on this platform. It is true here.
const FullSyncSupported = true

// FullSync asks the drive to flush its own write cache to the physical medium,
// which is what makes a returned Sync mean what Phase 2 claims it means.
//
// The reason this exists at all: on macOS, fsync(2) hands the bytes to the
// drive and returns. The drive is free to hold them in a volatile cache it will
// lose on a power cut, so a write that paid for its fsync can still vanish.
// F_FULLFSYNC is Apple's documented way to ask for the flush that fsync(2) does
// not. Naylamp's Phase 2 measured durability against fsync(2), which on this
// hardware is a barrier that is not one; the injector in this package proves the
// code uses a barrier, and this call is what makes the barrier real.
//
// It goes through the standard library on purpose. The module has no external
// dependencies and the CI vulnerability scan says so, so pulling in
// golang.org/x/sys for one fcntl would cost more than it buys. SyscallConn is
// how you reach a descriptor without racing the runtime's own use of it.
func FullSync(f *os.File) error {
	sc, err := f.SyscallConn()
	if err != nil {
		return fmt.Errorf("faultio: syscall conn for full sync: %w", err)
	}
	var errno syscall.Errno
	if cerr := sc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_FCNTL, fd, uintptr(syscall.F_FULLFSYNC), 0)
	}); cerr != nil {
		return fmt.Errorf("faultio: full sync control: %w", cerr)
	}
	if errno != 0 {
		return fmt.Errorf("faultio: F_FULLFSYNC: %w", errno)
	}
	fullSyncs.Add(1)
	return nil
}
