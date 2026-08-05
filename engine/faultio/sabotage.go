package faultio

import "os"

// DeafBarrier wraps an opener so every file it hands out accepts Sync and does
// nothing with it. It is a TEST INSTRUMENT, and it is how a red arm is built
// without editing the engine under test.
//
// The engine calls Sync exactly where it always did. The call is a lie, so a
// Disk underneath never advances its durable mark, and a power cut takes back
// everything the engine believed it had committed. That is a stronger sabotage
// than deleting the line from a build, because it also names two ways the same
// failure arrives in production without anyone editing anything: a drive that
// acknowledges a cache flush it did not perform, and a filesystem mounted with
// write barriers off.
//
// It belongs in this package rather than in one test file because both durable
// engines need it and a copy in each would be a copy that can drift.
func DeafBarrier(inner Opener) Opener {
	return func(path string, flag int, perm os.FileMode) (File, error) {
		f, err := inner(path, flag, perm)
		if err != nil {
			return nil, err
		}
		return deafFile{f}, nil
	}
}

// deafFile is a File whose barrier does nothing.
type deafFile struct{ File }

// Sync reports success without asking anything to reach the medium.
func (d deafFile) Sync() error { return nil }
