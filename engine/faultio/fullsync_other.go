//go:build !darwin

package faultio

import "os"

// FullSyncSupported reports whether FullSync issues a barrier stronger than
// fsync(2) on this platform. It is false here, and callers are expected to read
// it rather than assume they got the strong barrier they asked for.
const FullSyncSupported = false

// FullSync degrades to fsync(2) on every platform that is not darwin.
//
// This is not a stub standing in for work left undone. F_FULLFSYNC is Apple's
// answer to a gap that fsync(2) leaves open on macOS; on Linux, fsync(2)
// already pushes the data to the device, and asking for more is a different
// question with a different answer (write barriers, the block layer's own cache
// policy) that this package does not pretend to settle. What it does promise is
// that FullSyncSupported tells the truth about which of the two you got.
func FullSync(f *os.File) error {
	if err := f.Sync(); err != nil {
		return err
	}
	fullSyncs.Add(1)
	return nil
}
