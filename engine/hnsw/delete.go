package hnsw

// Delete removes a node from the graph entirely. It acquires the lock and then
// delegates to deleteLocked. Call this from outside the package (e.g. the
// engine API). This fixes the "ghost node" problem: a deleted vector must not
// linger in the graph, or searches could route through a node whose data no
// longer exists in the store.
func (idx *Index) Delete(id uint64) {
	idx.mu.Lock()
	defer idx.mu.Unlock()
	idx.deleteLocked(id)
}

// deleteLocked performs the actual removal and ASSUMES the caller already holds
// idx.mu. It drops the node, scrubs every reference to it from its neighbors'
// adjacency lists, and then repairs the hole: the now-disconnected neighbors
// are re-linked to each other so the graph does not fragment.
//
// Without this repair, every delete leaves the removed node's neighbors with
// one fewer connection and nothing to replace it. Over many deletes, a node can
// lose all its neighbors and become unreachable, which the deterministic
// simulation test exposed (a node present in the graph but with zero usable
// links, so search could never reach it).
func (idx *Index) deleteLocked(id uint64) {
	target, ok := idx.nodes[id]
	if !ok {
		return // nothing to delete
	}

	// For each layer, collect the target's neighbors, detach the target from
	// them, then re-link those neighbors to each other to fill the hole.
	for layer := 0; layer <= target.layer(); layer++ {
		neighbors := target.neighbors[layer]

		// Detach target from each neighbor's adjacency list.
		for _, nbrID := range neighbors {
			nbr, ok := idx.nodes[nbrID]
			if !ok || layer > nbr.layer() {
				continue
			}
			nbr.neighbors[layer] = removeID(nbr.neighbors[layer], id)
		}

		// Repair: re-link the orphaned neighbors to each other. They were all
		// close to the deleted node, so they make good replacement links. We
		// connect each to its nearest few among the group, capped by maxConn.
		idx.repairNeighborhood(neighbors, layer)
	}

	// Remove the node itself.
	delete(idx.nodes, id)

	// If we just removed the entry point, pick a new one.
	if idx.hasEntry && idx.entryPoint == id {
		idx.reassignEntryPoint()
	}
}

// repairNeighborhood re-links a set of nodes (the former neighbors of a deleted
// node) to each other on the given layer, so the graph stays connected after a
// deletion. For each node in the group it adds links to the others it is not
// already connected to, and EVERY LINK IT ADDS GOES IN BOTH DIRECTIONS: when
// the other side has no room, the link is declined rather than added one way.
// That costs repair strength, measurably, and the body says why it is the right
// trade and what a one-directional edge does to a later upsert.
//
// It assumes the caller already holds idx.mu, like deleteLocked, its only
// caller.
func (idx *Index) repairNeighborhood(group []uint64, layer int) {
	maxConn := idx.maxConnections(layer)

	for _, aID := range group {
		a, ok := idx.nodes[aID]
		if !ok || layer > a.layer() {
			continue
		}

		for _, bID := range group {
			if aID == bID {
				continue
			}
			if len(a.neighbors[layer]) >= maxConn {
				break
			}
			b, ok := idx.nodes[bID]
			if !ok || layer > b.layer() {
				continue
			}
			// Skip if already connected.
			if containsID(a.neighbors[layer], bID) {
				continue
			}

			// THE EDGE GOES IN BOTH DIRECTIONS OR IN NEITHER, and the old form
			// did not: it added a->b unconditionally and b->a only when b had
			// room, so a full b was left with an edge pointing at it that b did
			// not list back. Nothing in the index cleans an edge like that.
			// deleteLocked walks the deleted node's OWN list to detach itself, so
			// an edge it does not hold is invisible to it and survives the delete;
			// and because an upsert reuses the id, the stale edge comes back
			// attached to the newly inserted node. From there the insert's own
			// searchLayer can reach the node being inserted, selectNeighbors can
			// never reject it (its distance to its own data is zero), and Insert
			// writes both halves of that link into the one node: a self link, plus
			// a reciprocal that should have gone to a real neighbor. The self link
			// is harmless by itself; the lost reciprocal is not, because it was
			// the edge by which anything else would have reached this node. Repeat
			// it and the node keeps answering when asked directly while no search
			// can find it.
			//
			// b listing a while a does not list b is the old shape, left behind by
			// this same function before it was fixed or carried in from a restored
			// snapshot. With the invariant holding it cannot arise here, and it
			// measures zero fires on a graph this package built; it stays for the
			// graph that came from somewhere else. It closes the pair instead of
			// skipping it, and a is under its cap by the break above.
			//
			// Declining a link is a real loss of repair strength, not a free
			// choice: measured at 2000 vectors, this refuses about seven links in
			// ten. It is still the right trade, because the half it refuses is the
			// half that never helped. Repair exists to keep an orphaned neighbor
			// REACHABLE, and reachability comes from the b->a that the old code
			// already withheld when b was full; all it added in that case was
			// a->b, which gives a no in-edge at all. Measured minimum layer-0
			// in-degree over 5000 vectors, by dimension: 4, 8 and 13 with this
			// form against 2, 2 and 2 with the old one.
			//
			// The alternative that keeps both the strength and the invariant is to
			// append on both sides and then call shrinkNeighbors(bID, layer,
			// maxConn), which prunes symmetrically. It is not taken here because
			// this runs inside a delete, once per neighbor per layer, and the
			// numbers above say the cheap form already improves what it exists to
			// protect. Declining needs no prune, so no cap is exceeded either.
			if containsID(b.neighbors[layer], aID) {
				a.neighbors[layer] = append(a.neighbors[layer], bID)
				continue
			}
			if len(b.neighbors[layer]) >= maxConn {
				continue
			}
			a.neighbors[layer] = append(a.neighbors[layer], bID)
			b.neighbors[layer] = append(b.neighbors[layer], aID)
		}
	}
}

// containsID reports whether ids contains target.
func containsID(ids []uint64, target uint64) bool {
	for _, v := range ids {
		if v == target {
			return true
		}
	}
	return false
}

// removeID returns a NEW slice with the first occurrence of target removed.
// It deliberately allocates a fresh slice rather than mutating in place, since
// adjacency slices can share backing arrays after appends, and an in-place
// removal would corrupt other nodes' neighbor lists.
func removeID(ids []uint64, target uint64) []uint64 {
	out := make([]uint64, 0, len(ids))
	for _, v := range ids {
		if v != target {
			out = append(out, v)
		}
	}
	return out
}

// reassignEntryPoint scans remaining nodes and sets the entry point to the one
// living on the highest layer. Ties are broken by smallest id, so the choice
// is deterministic (Go map iteration order is random, which would otherwise
// make the entry point - and thus search results - non-reproducible).
func (idx *Index) reassignEntryPoint() {
	var bestID uint64
	bestLayer := -1
	for nodeID, n := range idx.nodes {
		nodeLayer := n.layer()
		if nodeLayer > bestLayer || (nodeLayer == bestLayer && nodeID < bestID) {
			bestLayer = nodeLayer
			bestID = nodeID
		}
	}
	if bestLayer < 0 {
		idx.hasEntry = false
		idx.entryPoint = 0
		idx.maxLayer = 0
		return
	}
	idx.entryPoint = bestID
	idx.maxLayer = bestLayer
}
