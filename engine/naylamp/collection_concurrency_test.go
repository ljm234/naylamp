package naylamp

import (
	"errors"
	"sync"
	"testing"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// This file defends the fix of DEFER-058: Collection operations are atomic
// against each other, so a Delete can never land inside an Upsert again.
//
// Why the interleaving is forced and not left to the scheduler: the defect was
// never a data race. The store and the index each carry their own mutex, so
// every single access is protected and the race detector has nothing to find;
// what breaks is the atomicity of a two-object operation. Reproducing it needs
// an execution stopped EXACTLY inside the measured window, after vectorData has
// read the id's data out of the store and before hnsw.Insert takes idx.mu.
// Chance cannot be asked for that, so the test stops the execution there
// itself: the collection is built by hand (same package, so the fields are
// reachable) with a wrapping vectorData that, the first time it is called for
// the experiment's id, closes a "window armed" channel and blocks on a
// "release" channel before returning. No sleeps, no probability: channels.
//
// What is asserted with the fix in place: TryLock from the test goroutine fails
// while the Upsert holds the write lock, the same observation lock_probe_test.go
// pins for the io-under-lock seam, and that is the deterministic evidence of
// exclusion. After release, the lock orders Upsert-then-Delete, so the final
// state is deterministic too, and it is checked as clause (i) asks, in BOTH
// directions: every id the index holds is in the store, every id the store is
// expected to hold is in the index, and the deleted id is in neither.
//
// The red arm is a reversion: dropping the Lock/RLock calls from operations.go
// turns this test RED, and the failing state is the counterexample the register
// archived on 2026-08-18: the index keeps id 7 while the store has already let
// it go, so IndexIDs is [1 2 3 7] against a store of 3, and a query for id 7's
// own vector returns it. That archived run measured a query distance of
// -5.110632e-10; this test's own reverted runs measure -3.5896463e-08, because
// its vector is [1 1 1] and not the one used then. The assertions are on the
// sets and not on the distance; neither number is a threshold.
func TestCollection_UpsertAndDeleteAreAtomicAcrossTheWindow(t *testing.T) {
	const target uint64 = 7

	store := vector.NewStore()
	armed := make(chan struct{})
	release := make(chan struct{})
	var armOnce, releaseOnce sync.Once
	defer releaseOnce.Do(func() { close(release) })

	targetCalls := 0
	index := hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		if id == target {
			targetCalls++
			armOnce.Do(func() {
				close(armed)
				<-release
			})
		}
		return v.Data, true
	}, 1)
	c := &Collection{name: "probe", dim: 3, store: store, index: index, metric: vector.CosineDistance}

	live := []uint64{1, 2, 3}
	mustUpsert(t, c, 1, []float32{1, 0, 0})
	mustUpsert(t, c, 2, []float32{0, 1, 0})
	mustUpsert(t, c, 3, []float32{0, 0, 1})

	var wg sync.WaitGroup
	var upErr, delErr error
	wg.Add(1)
	go func() {
		defer wg.Done()
		upErr = c.Upsert(target, []float32{1, 1, 1})
	}()

	<-armed // the Upsert is parked inside the measured window

	delCompleted := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		delErr = c.Delete(target)
		close(delCompleted)
	}()

	// While the Upsert is parked, the write lock must be observably held. That
	// TryLock is the deterministic half of this check: it fails if and only if
	// another goroutine holds the lock.
	//
	// The select below is the opportunistic half, and it is written down as such
	// so nobody reads more into it. If it catches the Delete already finished,
	// the operations are not atomic and that is a real failure; but passing it
	// proves nothing on its own, because the scheduler may simply not have
	// started that goroutine yet, which is what both reverted runs showed.
	select {
	case <-delCompleted:
		t.Errorf("Delete completed inside the Upsert window (err=%v): the operations are not atomic", delErr)
	default:
	}
	if c.mu.TryLock() {
		c.mu.Unlock()
		t.Errorf("collection mutex was not held while the Upsert sat in the window")
	}

	releaseOnce.Do(func() { close(release) })
	wg.Wait()

	if upErr != nil {
		t.Errorf("Upsert: %v", upErr)
	}
	if delErr != nil {
		t.Errorf("Delete: %v", delErr)
	}
	if targetCalls == 0 {
		t.Fatalf("the vectorData seam was never called for id %d: the test exercised nothing", target)
	}

	// Clause (i) from the API, in both directions. With the fix the Delete ran
	// after the Upsert, so the live set is exactly the three ids seeded above
	// and the target is gone from the index and from the store alike.
	ids := c.IndexIDs()
	inIndex := make(map[uint64]bool, len(ids))
	for _, id := range ids {
		inIndex[id] = true
		if _, err := store.Get(id); err != nil {
			t.Errorf("IndexIDs() = %v: id %d is in the index but not in the store (%v)", ids, id, err)
		}
	}
	for _, id := range live {
		if !inIndex[id] {
			t.Errorf("IndexIDs() = %v: id %d is in the store but not in the index", ids, id)
		}
	}
	if inIndex[target] {
		t.Errorf("IndexIDs() = %v: id %d is in the index after being deleted", ids, target)
	}
	if _, err := store.Get(target); !errors.Is(err, vector.ErrNotFound) {
		t.Errorf("store.Get(%d) after Delete returned %v, want vector.ErrNotFound", target, err)
	}
	if len(ids) != len(live) {
		t.Errorf("IndexIDs() = %v, want exactly %v", ids, live)
	}
	if c.Len() != len(live) {
		t.Errorf("store.Len() = %d, want %d (ids %v)", c.Len(), len(live), live)
	}

	got, err := c.Query([]float32{1, 1, 1}, 1)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	for _, n := range got {
		if n.ID == target {
			t.Errorf("Query for the deleted id's own vector returned it: %+v", got)
		}
	}
}
