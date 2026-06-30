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
// already connected to, respecting the per-layer connection cap.
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
			// Link both directions (each side respects its own cap).
			a.neighbors[layer] = append(a.neighbors[layer], bID)
			if len(b.neighbors[layer]) < maxConn && !containsID(b.neighbors[layer], aID) {
				b.neighbors[layer] = append(b.neighbors[layer], aID)
			}
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
