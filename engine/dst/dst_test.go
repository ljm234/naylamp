package dst

import (
	"testing"
)

// TestDST_ManySeeds runs the simulation across many seeds. Each seed drives a
// long, mixed sequence of operations against the engine while checking the
// invariants. If any seed violates an invariant, the test reports exactly which
// seed failed, so the failure can be reproduced deterministically.
func TestDST_ManySeeds(t *testing.T) {
	const (
		numSeeds = 200
		steps    = 2000
		dim      = 16
		maxID    = 100 // small, so upserts/deletes collide on the same ids
		checkN   = 200 // verify invariants every 200 steps
	)

	for seed := uint64(1); seed <= numSeeds; seed++ {
		cfg := Config{
			Seed:       seed,
			Steps:      steps,
			Dim:        dim,
			MaxID:      maxID,
			CheckEvery: checkN,
		}
		if err := Run(cfg); err != nil {
			t.Fatalf("seed %d failed: %v", seed, err)
		}
	}
	t.Logf("all %d seeds passed (%d steps each = %d total operations)",
		numSeeds, steps, numSeeds*steps)
}

// TestDST_Reproducible confirms determinism: the same seed produces the same
// outcome twice. This is the property that makes DST failures debuggable.
func TestDST_Reproducible(t *testing.T) {
	cfg := Config{Seed: 12345, Steps: 1000, Dim: 16, MaxID: 50, CheckEvery: 100}

	err1 := Run(cfg)
	err2 := Run(cfg)

	// Both runs must reach the same conclusion (both nil, or both the same error).
	if (err1 == nil) != (err2 == nil) {
		t.Fatalf("non-deterministic: run1=%v, run2=%v", err1, err2)
	}
	if err1 != nil && err2 != nil && err1.Error() != err2.Error() {
		t.Fatalf("non-deterministic errors: run1=%q, run2=%q", err1.Error(), err2.Error())
	}
}
