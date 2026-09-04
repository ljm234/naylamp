// Package dst runs deterministic simulation tests against the Naylamp engine.
// A seeded random stream drives a long, mixed sequence of operations (upsert,
// delete, query) while an in-memory oracle tracks what the engine should
// contain. Because the randomness is seeded, any failure is exactly
// reproducible by re-running with the same seed.
package dst

import (
	"fmt"
	"math/rand/v2"
	"slices"

	"naylamp/engine/naylamp"
	"naylamp/engine/vector"
)

// oracle is the "source of truth": a plain map mirroring what the engine is
// expected to hold. The simulation updates the oracle alongside every engine
// operation, then checks that the engine agrees with it. Think of it as a
// ledger kept by hand and compared against the real system.
type oracle struct {
	// vectors maps id -> the data we last upserted for it.
	vectors map[uint64][]float32
}

// newOracle returns an empty oracle.
func newOracle() *oracle {
	return &oracle{
		vectors: make(map[uint64][]float32),
	}
}

// upsert records that an id now holds the given data.
func (o *oracle) upsert(id uint64, data []float32) {
	o.vectors[id] = data
}

// delete records that an id is gone.
func (o *oracle) delete(id uint64) {
	delete(o.vectors, id)
}

// has reports whether the oracle currently expects this id to exist.
func (o *oracle) has(id uint64) bool {
	_, ok := o.vectors[id]
	return ok
}

// count returns how many ids the oracle expects to exist.
func (o *oracle) count() int {
	return len(o.vectors)
}

// ids returns all ids the oracle currently holds, in ascending order.
//
// The order is sorted and not the map's, because a caller that stops at the
// FIRST id it finds wrong turns the map's traversal into part of the message.
// checkReachability does exactly that, so a state with two ids violating at
// once stayed reproducible in its FAILURE and not in its TEXT, which is what
// TestDST_Reproducible compares. Measured on one state of 40 ids with four
// sharing a vector, 200 calls in a single process: thirty distinct messages
// unsorted, one sorted. The cost is a single pass over ids the caller is about
// to walk anyway.
func (o *oracle) ids() []uint64 {
	out := make([]uint64, 0, len(o.vectors))
	for id := range o.vectors {
		out = append(out, id)
	}
	slices.Sort(out)
	return out
}

// Config controls one simulation run.
type Config struct {
	Seed       uint64 // makes the run reproducible
	Steps      int    // how many random operations to perform
	Dim        int    // vector dimensionality
	MaxID      int    // ids are drawn from [1, MaxID], so deletes/re-inserts collide
	CheckEvery int    // run invariant checks every N steps
}

// Run executes one deterministic simulation. It drives the engine through
// Steps random operations (upsert / delete / query) chosen by a seeded RNG,
// mirrors each change in the oracle, and periodically verifies invariants.
// It returns an error the moment an invariant is violated; because the RNG is
// seeded, that failure reproduces exactly on a re-run with the same Config.
func Run(cfg Config) error {
	rng := rand.New(rand.NewPCG(cfg.Seed, 0)) //nolint:gosec // deterministic RNG is the whole point of DST

	eng := naylamp.New()
	col, err := eng.CreateCollection("sim", cfg.Dim, vector.CosineDistance, cfg.Seed)
	if err != nil {
		return fmt.Errorf("setup: %w", err)
	}
	orc := newOracle()

	for step := 0; step < cfg.Steps; step++ {
		// Pick an id in [1, MaxID]. rng.IntN(cfg.MaxID) is in [0, MaxID) and
		// MaxID is a small positive test parameter, so the +1 result is always
		// a small positive value that fits in uint64 without overflow.
		id := uint64(rng.IntN(cfg.MaxID) + 1) //nolint:gosec // value is small and positive by construction

		switch rng.IntN(3) {
		case 0, 1: // upsert is twice as likely, so the set tends to grow
			data := randomVector(rng, cfg.Dim)
			if err := col.Upsert(id, data); err != nil {
				return fmt.Errorf("step %d: upsert id %d: %w", step, id, err)
			}
			orc.upsert(id, data)

		case 2: // delete
			err := col.Delete(id)
			if orc.has(id) {
				// The oracle expected it to exist, so delete must succeed.
				if err != nil {
					return fmt.Errorf("step %d: delete existing id %d failed: %w", step, id, err)
				}
				orc.delete(id)
			}
			// If the oracle did not expect it, an error is fine (already gone).
		}

		if cfg.CheckEvery > 0 && step%cfg.CheckEvery == 0 {
			if err := checkInvariants(col, orc); err != nil {
				return fmt.Errorf("step %d: %w", step, err)
			}
		}
	}

	// Final check after all steps.
	return checkInvariants(col, orc)
}

// randomVector builds a deterministic random vector of the given dimension.
func randomVector(rng *rand.Rand, dim int) []float32 {
	data := make([]float32, dim)
	for i := range data {
		data[i] = float32(rng.NormFloat64())
	}
	return data
}
