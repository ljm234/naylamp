package raft

import "math/rand/v2"

// testRNG builds a deterministic generator for harness and unit tests.
func testRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic tests require seeded randomness
}
