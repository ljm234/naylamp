package dst

import (
	"os"
	"strconv"
	"testing"
)

// TestDST_ManySeeds runs the simulation across many seeds. Each seed drives a
// long, mixed sequence of operations against the engine while checking the
// invariants. If any seed violates an invariant, the test reports exactly which
// seed failed, so the failure can be reproduced deterministically.
//
// THE SEED BUDGET IS 1000 AND USED TO BE 200, and the shape below is copied from
// the two sweeps written after this one rather than invented here: the cluster
// sweep in engine/naylamp and the raft safety sweep in engine/raft both declare a
// full budget, drop to 40 under -short, and take an override from the
// environment. This one declared 200, took no override, and did not drop, which
// left it in the worst of both worlds. Subphase 1.5 promises invariants over at
// least 1000 seeds and 200 is not 1000, so the declared budget is now the number
// the criterion asks for; and measured before the change, the old 200 cost
// 358.483s under -short -race, which made the sweep accused of covering too
// little the most expensive of the three on the push path, because the other two
// were already dropping to 40 there and this one was not.
func TestDST_ManySeeds(t *testing.T) {
	const (
		steps  = 2000
		dim    = 16
		maxID  = 100 // small, so upserts/deletes collide on the same ids
		checkN = 200 // verify invariants every 200 steps
	)

	numSeeds := 1000
	if testing.Short() {
		numSeeds = 40
	}
	if env := os.Getenv("NAYLAMP_DST_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_DST_SEEDS=%q invalid", env)
		}
		numSeeds = v
	}

	for seed := uint64(1); seed <= uint64(numSeeds); seed++ {
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
