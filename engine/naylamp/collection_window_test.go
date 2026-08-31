package naylamp

import (
	"sync"
	"testing"
	"time"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// This file pins the OTHER end of the window DEFER-058 opened, and it exists
// because a census of this tree's red arms on 2026-08-29 found that the
// defender in collection_concurrency_test.go leaves that end unguarded.
//
// The window has two ends and each test pins one. Measured, twenty runs per
// cell, mutating Upsert in operations.go:
//
//	mutation                                  this test   the other defender
//	no Lock at all                            green       red
//	Lock released BEFORE index.Insert         green       red
//	Lock taken AFTER store.Insert             red         green
//	untouched tree                            green       green
//
// So they are not substitutes, and the split is exact: each catches only what
// the other cannot see. This one stays green without any lock because then the
// Upsert runs straight through and the two objects never disagree while the
// poll is looking; that case belongs to the other defender.
//
// DO NOT REMOVE THE OTHER TEST BELIEVING THIS ONE COVERS IT. Read the table
// again: without any lock at all, which is the most destructive of the three
// mutations, THIS TEST IS GREEN. The only thing that catches it is
// TestCollection_UpsertAndDeleteAreAtomicAcrossTheWindow in
// collection_concurrency_test.go. Retiring that one and keeping this one leaves
// the window watched on the end that matters least. Whoever changes either of
// them changes this comment in both files, or the pair stops meaning what it
// says.
//
// Written this way on 2026-08-31 because until then the table lived only in the
// register outside this repository, so anyone reading the two files alone had
// no way to know they depend on each other. The other defender parks execution inside
// vectorData, which hnsw.Insert calls, and asks whether the mutex is held
// there; that catches a lock let go too early. It cannot catch a lock taken too
// late, because by the time vectorData runs the lock is held again in that
// variant, and the final state still comes out consistent. What a lock taken
// after store.Insert opens is a stretch where the store already holds the id
// and the index does not, and Query, IndexIDs and Len all enter that stretch
// under RLock. That is clause (i) broken in the direction the other defender
// checks only at the end.
//
// The assertion here is on the OBSERVABLE EFFECT through the real entry point,
// not on what a function returns, and that is the whole reason it reaches. The
// test takes the collection's own lock, which is what a reader does, and then
// asks whether an Upsert running concurrently can still push the id into the
// store. With the lock held by a reader, it must not be able to.
//
// The direction of error is written down rather than hidden: if the Upsert
// goroutine has not been scheduled yet, nothing is seen and the test passes.
// So this can report a false GREEN and never a false RED, which is why it polls
// instead of looking once. Against the mutation it went red twenty times out of
// twenty, so the polling is not the weak part.
func TestCollection_NoReaderCanSeeTheStoreAheadOfTheIndex(t *testing.T) {
	const target uint64 = 7

	store := vector.NewStore()
	index := hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, 1)
	c := &Collection{name: "probe", dim: 3, store: store, index: index, metric: vector.CosineDistance}

	mustUpsert(t, c, 1, []float32{1, 0, 0})

	c.mu.Lock() // the test stands where a reader stands

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		_ = c.Upsert(target, []float32{1, 1, 1})
	}()

	// Both objects are asked, because the claim is that they DISAGREE and the
	// first version of this check only looked at the store, so its failure line
	// asserted something about the index it had never read. Export takes the
	// index's own lock and not the collection's, so it is safe to call here.
	inIndex := func() bool {
		for _, n := range index.Export().Nodes {
			if n.ID == target {
				return true
			}
		}
		return false
	}

	disagree := false
	for i := 0; i < 2000 && !disagree; i++ {
		if _, err := store.Get(target); err == nil && !inIndex() {
			disagree = true
		}
		time.Sleep(200 * time.Microsecond)
	}
	c.mu.Unlock()
	wg.Wait()

	if disagree {
		t.Errorf("with a reader holding the lock, the store held id %d while the index did not: "+
			"there is a stretch where Query, IndexIDs and Len see the two objects disagree", target)
	}
}
