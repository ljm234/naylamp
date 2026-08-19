package naylamp

import (
	"testing"

	"naylamp/engine/vector"
)

// These are the defenders of Collection.IndexIDs, and the first one exists
// because nothing else in the tree can fail if that accessor is wired to the
// wrong object. A Collection writes every id to the store and to the index
// together and deletes it from both together, so through the public API the two
// hold the same set at all times: an IndexIDs that enumerated the store would
// return the right answer for every sequence a caller can produce, and the
// deterministic simulation would pass its whole seed budget with the accessor
// pointed at the store while clause (i) of the central property of Phase 1
// speaks about the index. Measured, not assumed: with the accessor reading the
// store AND the mutation that leaves ghosts in the index applied on top, so
// that the red row for that class should have fired, all 1000 seeds pass in
// 215.21s. The clause is stated in NAYLAMP_PHASE_1.md and the row is archived
// in NAYLAMP_D1_REDARM_2026-08-18, neither of them in this repository: they
// live in the workspace directory above it.
//
// So the two halves are driven apart here on purpose, through the unexported
// fields, which is what a test in this package can reach and a test outside it
// cannot. It is not a mutation of the engine and it is not a red arm: it runs
// on every push.

// TestCollection_IndexIDsReadsTheIndexNotTheStore drives the store and the index
// apart in both directions and asserts which object each method follows. The
// collection is built through the public API first, so what diverges is a real
// collection and not a hand-assembled one.
func TestCollection_IndexIDsReadsTheIndexNotTheStore(t *testing.T) {
	e := New()
	col, err := e.CreateCollection("docs", 3, vector.CosineDistance, 7)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}
	for id := uint64(1); id <= 5; id++ {
		mustUpsert(t, col, id, []float32{float32(id), 1, 0})
	}

	if got, want := col.IndexIDs(), []uint64{1, 2, 3, 4, 5}; !sameIDs(got, want) {
		t.Fatalf("IndexIDs after five upserts = %v, want %v", got, want)
	}
	if col.Len() != 5 {
		t.Fatalf("Len after five upserts = %d, want 5", col.Len())
	}

	// Direction one: drop id 3 from the STORE only. The index keeps its node,
	// so an accessor that reads the index still reports 3 and one that reads
	// the store no longer does.
	if err := col.store.Delete(3); err != nil {
		t.Fatalf("store.Delete(3): %v", err)
	}
	if got, want := col.IndexIDs(), []uint64{1, 2, 3, 4, 5}; !sameIDs(got, want) {
		t.Fatalf("IndexIDs after dropping id 3 from the store = %v, want %v: the accessor is following the store", got, want)
	}
	if col.Len() != 4 {
		t.Fatalf("Len after dropping id 3 from the store = %d, want 4", col.Len())
	}

	// Direction two: drop id 4 from the INDEX only. The store keeps its vector,
	// so its count does not move and the index's set does.
	col.index.Delete(4)
	if got, want := col.IndexIDs(), []uint64{1, 2, 3, 5}; !sameIDs(got, want) {
		t.Fatalf("IndexIDs after dropping id 4 from the index = %v, want %v", got, want)
	}
	if col.Len() != 4 {
		t.Fatalf("Len after dropping id 4 from the index = %d, want 4: the count is following the index", col.Len())
	}
}

// TestCollection_IndexIDsIsReadOnlyAndAscending pins the two properties the
// checker leans on: the order is ascending whatever order the ids arrived in,
// inherited from Export, and the returned slice is the caller's own rather than
// the graph's.
func TestCollection_IndexIDsIsReadOnlyAndAscending(t *testing.T) {
	e := New()
	col, err := e.CreateCollection("docs", 2, vector.CosineDistance, 3)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}

	if got := col.IndexIDs(); len(got) != 0 {
		t.Fatalf("IndexIDs on an empty collection = %v, want empty", got)
	}

	// Insert out of order; the accessor must not preserve arrival order.
	for _, id := range []uint64{30, 10, 20} {
		mustUpsert(t, col, id, []float32{float32(id), 1})
	}
	if got, want := col.IndexIDs(), []uint64{10, 20, 30}; !sameIDs(got, want) {
		t.Fatalf("IndexIDs = %v, want %v ascending", got, want)
	}

	// Scribble on the result. If the accessor handed out the graph's own memory
	// instead of a copy, the next call would come back scribbled too.
	scribbled := col.IndexIDs()
	for i := range scribbled {
		scribbled[i] = 99
	}
	if got, want := col.IndexIDs(), []uint64{10, 20, 30}; !sameIDs(got, want) {
		t.Fatalf("IndexIDs after scribbling on a previous result = %v, want %v", got, want)
	}
}

// sameIDs reports whether two id slices are equal element by element.
func sameIDs(a, b []uint64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestCollection_IndexIDsMatchesStoreThroughThePublicAPI is the control for
// TestCollection_IndexIDsReadsTheIndexNotTheStore: whatever the two directions of surgery prove, a collection driven
// only through the API must keep the two objects in step, or the checker built
// on this accessor would go red on a healthy engine.
func TestCollection_IndexIDsMatchesStoreThroughThePublicAPI(t *testing.T) {
	e := New()
	col, err := e.CreateCollection("docs", 2, vector.CosineDistance, 11)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}

	// A sequence that could separate the two objects through the API alone: an
	// id overwritten while live, one deleted and put back, and a delete of an id
	// that is already gone.
	for id := uint64(1); id <= 6; id++ {
		mustUpsert(t, col, id, []float32{float32(id), 1})
	}
	mustUpsert(t, col, 3, []float32{99, 1})
	if err := col.Delete(2); err != nil {
		t.Fatalf("Delete(2): %v", err)
	}
	if err := col.Delete(2); err == nil {
		t.Fatal("Delete(2) twice should fail the second time, got nil")
	}
	if err := col.Delete(5); err != nil {
		t.Fatalf("Delete(5): %v", err)
	}
	mustUpsert(t, col, 2, []float32{7, 1})

	want := []uint64{1, 2, 3, 4, 6}
	if got := col.IndexIDs(); !sameIDs(got, want) {
		t.Fatalf("IndexIDs = %v, want %v", got, want)
	}
	if col.Len() != len(want) {
		t.Fatalf("Len = %d, want %d", col.Len(), len(want))
	}
	// And the store holds the same ids, id by id and not just as many.
	for _, id := range want {
		if _, err := col.store.Get(id); err != nil {
			t.Errorf("store is missing id %d that the index holds: %v", id, err)
		}
	}
	if _, err := col.store.Get(5); err == nil {
		t.Error("store still holds id 5, which was deleted")
	}
}
