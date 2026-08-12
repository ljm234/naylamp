package hnsw

import (
	"math/rand/v2"
	"testing"

	"naylamp/engine/vector"
)

// buildAndReupsert builds an index over n gaussian vectors drawn from a fixed
// PCG(1, 0) stream, so the corpus is identical on every call, and then upserts
// every id a second time with that same data, which is what re-indexing a
// document that already exists does. The seed argument reaches NewIndex only,
// where it drives the layer draws; it does not vary the vectors. There is no
// delete anywhere: Insert on an id already in the graph is itself a clean
// delete-then-insert, so this reaches deleteLocked and its repair through the
// ordinary write path.
func buildAndReupsert(t *testing.T, n, dim int, seed uint64) (*vector.Store, *Index) {
	t.Helper()
	rng := rand.New(rand.NewPCG(1, 0)) //nolint:gosec // deterministic RNG for test data
	store := vector.NewStore()
	idx := NewIndex(DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, seed)

	for i := 0; i < n; i++ {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		if err := store.Insert(vector.Vector{ID: uint64(i + 1), Data: data}); err != nil { //nolint:gosec // i is a small loop bound
			t.Fatalf("store insert: %v", err)
		}
		if err := idx.Insert(uint64(i + 1)); err != nil { //nolint:gosec // i is a small loop bound
			t.Fatalf("index insert: %v", err)
		}
	}
	for i := 0; i < n; i++ {
		if err := idx.Insert(uint64(i + 1)); err != nil { //nolint:gosec // i is a small loop bound
			t.Fatalf("re-upsert: %v", err)
		}
	}
	return store, idx
}

// TestHNSW_ReupsertKeepsGraphNavigable defends the graph against the way it was
// broken: re-upserting every id used to leave nodes that nothing pointed at, and
// over a large enough corpus that became nodes no query could reach while the
// engine kept counting them as present. It took no delete at all.
//
// WHY THE CORPUS IS SIZED FROM DefaultM. The defect needs the layer-0 pruning to
// refuse a back-link, and it can only refuse once a node's list is full, which
// on layer 0 means 2*M connections. Below that nothing is ever refused, every
// edge stays symmetric, and no half-edge exists for a later upsert to inherit.
// Measured on the broken code at dim 8: 70 vectors produce nothing at all, 72 is
// where the first refusal happens, and 74 is where the first node ends up
// pointing at itself. The size is derived rather than written as 80, because a
// literal would keep its value while the threshold moved: raising DefaultM to 48
// takes a corpus of 80 back under the bar, and this test would go green forever
// while defending nothing.
//
// WHY dim 32. Not for cheapness and not because the defect prefers low
// dimensions, which is what an earlier version of this comment claimed and had
// backwards. Measured on the broken code at this corpus size, the count of nodes
// left pointing at themselves runs 4 at dim 8, 13 at dim 16, 29 at dim 32 and 33
// at dim 64. Dim 8 is the weakest trigger of the four, so the margin here is
// dim 32: it turns red by an order of magnitude rather than by two nodes, and it
// sits inside the 32 to 64 band the central property of Phase 1 declares.
//
// DECLARED BLIND SPOT, because two of the three assertions do the work and the
// third does not. On the broken code this corpus reports zero unreachable ids:
// what turns the test red is the self link and the missing reverse edge, which
// are the cause, not the symptom the test is named for. Reachability only breaks
// once the corpus runs to thousands, a run this suite does not carry. The
// assertion stays as a second route to the same failure, and it defends nothing
// on its own at this size.
func TestHNSW_ReupsertKeepsGraphNavigable(t *testing.T) {
	const (
		// 2*DefaultM is the layer-0 cap, and the corpus has to clear it before a
		// back-link is ever refused. The margin above it is what keeps the trigger
		// alive; 16 reproduces the 80 this was characterised at.
		n    = 2*DefaultM + 16
		dim  = 32
		seed = 3
	)
	store, idx := buildAndReupsert(t, n, dim, seed)
	snap := idx.Export()

	// The corpus really did cross the cap. Without this the two assertions below
	// pass on a graph too small to have been at risk, and the whole test becomes
	// green for the wrong reason.
	fullLists := 0
	for _, ns := range snap.Nodes {
		if len(ns.Neighbors) > 0 && len(ns.Neighbors[0]) >= 2*DefaultM {
			fullLists++
		}
	}
	if fullLists == 0 {
		t.Fatalf("no node reached the layer-0 cap of %d over %d vectors, so this corpus never exercised the refusal this test defends", 2*DefaultM, n)
	}

	// No node links to itself. This is the visible half of the defect and it is
	// read straight off the exported graph, with no search involved.
	for _, ns := range snap.Nodes {
		for layer := range ns.Neighbors {
			for _, nbr := range ns.Neighbors[layer] {
				if nbr == ns.ID {
					t.Errorf("node %d links to itself on layer %d", ns.ID, layer)
				}
			}
		}
	}

	// Every edge is answered in both directions. This is the cause: an edge one
	// side does not hold survives a delete, because deleteLocked can only detach
	// the edges the deleted node itself lists.
	listed := make(map[uint64]map[uint64]map[int]bool, len(snap.Nodes))
	for _, ns := range snap.Nodes {
		listed[ns.ID] = make(map[uint64]map[int]bool, len(ns.Neighbors))
		for layer := range ns.Neighbors {
			for _, nbr := range ns.Neighbors[layer] {
				if listed[ns.ID][nbr] == nil {
					listed[ns.ID][nbr] = make(map[int]bool, 1)
				}
				listed[ns.ID][nbr][layer] = true
			}
		}
	}
	for from, targets := range listed {
		for to, layers := range targets {
			for layer := range layers {
				if !listed[to][from][layer] {
					t.Errorf("edge %d to %d on layer %d has no reverse edge", from, to, layer)
				}
			}
		}
	}

	// And the property itself: every live id comes back as its own nearest
	// neighbor. See the declared blind spot above for what this does and does not
	// catch at this size.
	for i := 0; i < n; i++ {
		want := uint64(i + 1) //nolint:gosec // i is a small loop bound
		v, err := store.Get(want)
		if err != nil {
			t.Fatalf("store lost id %d: %v", want, err)
		}
		got := idx.Search(v.Data, 1)
		if len(got) != 1 || got[0].ID != want {
			t.Errorf("id %d is not its own nearest neighbor, got %v", want, got)
		}
	}
}

// TestHNSW_RestoredHalfEdgeDoesNotSelfLink covers the half of the defense that
// the test above cannot reach. RestoreIndex copies neighbor lists verbatim, so a
// graph read from a snapshot written before the repair became symmetric arrives
// carrying half-edges this package would no longer make. One of them is all it
// takes: it gives the insert's own search a way back to the node being
// inserted, which then selects itself.
//
// The half-edge is produced here the only way an outside graph can be built with
// the package's own API, by exporting a healthy graph, dropping one side of one
// edge, and restoring. That is what a pre-fix snapshot looks like on the way in.
func TestHNSW_RestoredHalfEdgeDoesNotSelfLink(t *testing.T) {
	const (
		n    = 2*DefaultM + 16
		dim  = 32
		seed = 3
	)
	store, idx := buildAndReupsert(t, n, dim, seed)

	// Cut one direction of one layer-0 edge, and the DIRECTION is the whole
	// point. What has to survive is an edge POINTING AT the id that gets
	// re-upserted, held by a node that id does not list back: deleteLocked walks
	// only the deleted node's own list, so that is the edge it cannot see. Take
	// a pair where holder lists target, then remove holder from target's list.
	// Cutting it the other way round leaves nothing pointing at target, the
	// search never reaches it, and the test goes green while defending nothing.
	snap := idx.Export()
	var holder, target uint64
	for i := range snap.Nodes {
		if len(snap.Nodes[i].Neighbors) == 0 || len(snap.Nodes[i].Neighbors[0]) == 0 {
			continue
		}
		holder = snap.Nodes[i].ID
		target = snap.Nodes[i].Neighbors[0][0]
		break
	}
	if holder == 0 {
		t.Fatalf("no layer-0 edge to cut over %d nodes", len(snap.Nodes))
	}
	cut := false
	for i := range snap.Nodes {
		if snap.Nodes[i].ID != target || len(snap.Nodes[i].Neighbors) == 0 {
			continue
		}
		kept := make([]uint64, 0, len(snap.Nodes[i].Neighbors[0]))
		for _, nbr := range snap.Nodes[i].Neighbors[0] {
			if nbr == holder {
				cut = true
				continue
			}
			kept = append(kept, nbr)
		}
		snap.Nodes[i].Neighbors[0] = kept
	}
	if !cut {
		t.Fatalf("edge %d to %d had no reverse side to cut, so no half-edge was injected", holder, target)
	}

	restored := RestoreIndex(snap, vector.CosineDistance, func(id uint64) ([]float32, bool) {
		v, err := store.Get(id)
		if err != nil {
			return nil, false
		}
		return v.Data, true
	}, seed)

	// Re-upsert the id that is still pointed at but no longer points back. This
	// is the ordinary write path, and on a graph carrying that half-edge it is
	// what used to manufacture a self link.
	if err := restored.Insert(target); err != nil {
		t.Fatalf("re-upsert of %d: %v", target, err)
	}

	for _, ns := range restored.Export().Nodes {
		for layer := range ns.Neighbors {
			for _, nbr := range ns.Neighbors[layer] {
				if nbr == ns.ID {
					t.Errorf("node %d links to itself on layer %d after an upsert over a restored half-edge", ns.ID, layer)
				}
			}
		}
	}
}
