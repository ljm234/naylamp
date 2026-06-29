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
// idx.mu. It exists so Insert (which already holds the lock during an update)
// can remove a stale node without trying to lock twice, which would deadlock.
// It drops the node and scrubs every reference to it from its neighbors'
// adjacency lists on all layers. If the removed node was the entry point, a new
// one is chosen from whatever remains.
func (idx *Index) deleteLocked(id uint64) {
	target, ok := idx.nodes[id]
	if !ok {
		return // nothing to delete
	}

	// Remove this id from every neighbor's adjacency list, on every layer it
	// participated in.
	for layer := 0; layer <= target.layer(); layer++ {
		for _, neighborID := range target.neighbors[layer] {
			neighbor, ok := idx.nodes[neighborID]
			if !ok || layer > neighbor.layer() {
				continue
			}
			neighbor.neighbors[layer] = removeID(neighbor.neighbors[layer], id)
		}
	}

	// Remove the node itself.
	delete(idx.nodes, id)

	// If we just removed the entry point, pick a new one (the remaining node
	// with the highest layer), or clear the entry if the graph is now empty.
	if idx.hasEntry && idx.entryPoint == id {
		idx.reassignEntryPoint()
	}
}

// removeID returns the slice with the first occurrence of target removed.
func removeID(ids []uint64, target uint64) []uint64 {
	for i, v := range ids {
		if v == target {
			return append(ids[:i], ids[i+1:]...)
		}
	}
	return ids
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
		// Higher layer wins; on a tie, the smaller id wins (deterministic).
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
