package persist

import (
	"math/rand/v2"
	"testing"

	"naylamp/engine/vector"
)

// This file drives crash-injection testing for the durability layer. The idea,
// borrowed from systems like TigerBeetle and FoundationDB, is to run a sequence
// of operations, simulate a crash at a chosen point, recover, and assert that
// every write we acknowledged as durable is still present. Because the crash
// point is chosen deterministically from a seed, a failure reproduces exactly.

// crashOracle tracks the set of vectors that must survive a crash: every id that
// was durably upserted and not later durably deleted. During replay after a
// simulated crash, the recovered database must contain exactly these (it may
// also contain a few extra from writes that were in flight, which is safe).
type crashOracle struct {
	live map[uint64]vector.Vector
}

func newCrashOracle() *crashOracle {
	return &crashOracle{live: make(map[uint64]vector.Vector)}
}

func (o *crashOracle) upsert(v vector.Vector) {
	o.live[v.ID] = v
}

func (o *crashOracle) delete(id uint64) {
	delete(o.live, id)
}

// TestCrash_AcknowledgedWritesSurvive runs many seeds. In each: open a DB, apply
// a deterministic sequence of upserts and deletes (each fsynced, so each is
// acknowledged and durable), simulate a crash by abandoning the DB without a
// clean close, reopen via recovery, and assert every acknowledged write is
// present. This is the core durability invariant of Phase 2.
func TestCrash_AcknowledgedWritesSurvive(t *testing.T) {
	const (
		seeds = 200
		dim   = 8
	)

	for s := uint64(1); s <= seeds; s++ {
		runCrashSeed(t, s, dim)
	}
}

// runCrashSeed executes one crash-injection scenario for a given seed.
func runCrashSeed(t *testing.T, seed uint64, dim int) {
	t.Helper()
	dir := t.TempDir()
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible crash scenarios, not security

	oracle := newCrashOracle()

	// Phase 1: open, apply a sequence of durable ops, then abandon (no Close),
	// simulating a crash. Because FsyncAlways is used, every returned op is
	// durable, so the oracle records exactly what must survive.
	db, err := Open(dir, vector.CosineDistance, FsyncAlways, seed)
	if err != nil {
		t.Fatalf("seed %d: open: %v", seed, err)
	}

	ops := 20 + rng.IntN(60)
	nextID := uint64(1)
	for i := 0; i < ops; i++ {
		// Bias toward upserts; occasionally delete an existing id.
		if len(oracle.live) > 0 && rng.IntN(4) == 0 {
			// Delete a random live id.
			victim := pickLiveID(rng, oracle)
			if err := db.Delete(victim); err != nil {
				t.Fatalf("seed %d: delete: %v", seed, err)
			}
			oracle.delete(victim)
		} else {
			v := vector.Vector{ID: nextID, Data: randData(rng, dim)}
			nextID++
			if err := db.Upsert(v); err != nil {
				t.Fatalf("seed %d: upsert: %v", seed, err)
			}
			oracle.upsert(v)
		}
	}

	// Simulate a crash: abandon db without Close (no extra flush beyond what each
	// fsynced op already guaranteed). Drop the reference.
	_ = db

	// Phase 2: recover and assert every acknowledged write survived.
	state, err := Recover(dir, vector.CosineDistance, seed)
	if err != nil {
		t.Fatalf("seed %d: recover: %v", seed, err)
	}

	for id, want := range oracle.live {
		got, gerr := state.Store.Get(id)
		if gerr != nil {
			t.Fatalf("seed %d: acknowledged id %d missing after crash: %v", seed, id, gerr)
		}
		if len(got.Data) != len(want.Data) {
			t.Fatalf("seed %d: id %d data len mismatch after recovery", seed, id)
		}
		for j := range want.Data {
			if got.Data[j] != want.Data[j] {
				t.Fatalf("seed %d: id %d data mismatch at %d after recovery", seed, id, j)
			}
		}
	}

	// The index must also find these ids (live vector is searchable). Spot-check
	// a few by searching for their own vector and expecting the id back.
	checked := 0
	for id, want := range oracle.live {
		res := state.Index.Search(want.Data, 5)
		found := false
		for _, n := range res {
			if n.ID == id {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("seed %d: acknowledged id %d not searchable after recovery", seed, id)
		}
		checked++
		if checked >= 5 {
			break
		}
	}
}

// pickLiveID returns a random id currently live in the oracle.
func pickLiveID(rng *rand.Rand, o *crashOracle) uint64 {
	ids := make([]uint64, 0, len(o.live))
	for id := range o.live {
		ids = append(ids, id)
	}
	// Sort for determinism, then pick by index.
	sortUint64Slice(ids)
	return ids[rng.IntN(len(ids))]
}

// randData builds a deterministic random vector of the given dimension.
func randData(rng *rand.Rand, dim int) []float32 {
	data := make([]float32, dim)
	for i := range data {
		data[i] = float32(rng.NormFloat64())
	}
	return data
}

// sortUint64Slice sorts ascending (small helper local to the crash tests).
func sortUint64Slice(s []uint64) {
	for i := 1; i < len(s); i++ {
		key := s[i]
		j := i - 1
		for j >= 0 && s[j] > key {
			s[j+1] = s[j]
			j--
		}
		s[j+1] = key
	}
}
