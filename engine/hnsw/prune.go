package hnsw

// selectNeighbors applies the HNSW paper's heuristic to choose which of the
// candidates a node should connect to, keeping at most m. Instead of blindly
// taking the m closest (which tend to cluster in one direction), it keeps a
// candidate only if that candidate is closer to the base node than it is to any
// already-selected neighbor. This favors a diverse spread of links, making the
// graph far more navigable: searches reach more of the space in fewer hops.
//
// candidates must be sorted nearest-first. The result is also nearest-first.
func (idx *Index) selectNeighbors(candidates []candidate, m int) []candidate {
	if len(candidates) <= m {
		return candidates
	}

	selected := make([]candidate, 0, m)
	for _, cand := range candidates {
		if len(selected) >= m {
			break
		}

		candNode, ok := idx.nodes[cand.id]
		if !ok {
			continue
		}

		// Keep cand only if it is closer to the base node (cand.dist) than to
		// every neighbor already selected. This enforces diversity.
		keep := true
		for _, sel := range selected {
			selNode, ok := idx.nodes[sel.id]
			if !ok {
				continue
			}
			distToSelected := idx.metric(candNode.data, selNode.data)
			if distToSelected < cand.dist {
				keep = false
				break
			}
		}

		if keep {
			selected = append(selected, cand)
		}
	}

	return selected
}

// shrinkNeighbors re-prunes a node's neighbor list on the given layer when it
// has grown past maxConn, keeping only the best, most diverse maxConn links.
//
// Crucially, when a neighbor is dropped, the link is severed on BOTH sides: the
// dropped neighbor also has this node removed from its own list. HNSW edges are
// bidirectional, so dropping one direction only would leave a dangling
// half-edge and, after repeated updates, orphan nodes with no usable links.
// (A node left with zero reachable neighbors is exactly the consistency bug the
// deterministic simulation test exposed.)
func (idx *Index) shrinkNeighbors(id uint64, layer, maxConn int) {
	n, ok := idx.nodes[id]
	if !ok || layer > n.layer() {
		return
	}
	if len(n.neighbors[layer]) <= maxConn {
		return
	}

	// Build candidates: each current neighbor with its distance to this node.
	cands := make([]candidate, 0, len(n.neighbors[layer]))
	for _, nbrID := range n.neighbors[layer] {
		nbr, ok := idx.nodes[nbrID]
		if !ok {
			continue
		}
		d := idx.metric(n.data, nbr.data)
		cands = append(cands, candidate{id: nbrID, dist: d})
	}

	// Sort nearest-first so selectNeighbors sees them in the expected order.
	sortCandidates(cands)

	pruned := idx.selectNeighbors(cands, maxConn)

	// Figure out which neighbors were kept, so we can detect the dropped ones.
	kept := make(map[uint64]struct{}, len(pruned))
	newNeighbors := make([]uint64, 0, len(pruned))
	for _, c := range pruned {
		kept[c.id] = struct{}{}
		newNeighbors = append(newNeighbors, c.id)
	}

	// For every neighbor that was dropped, sever the reverse link too, so the
	// graph stays symmetric and no node is left with a dangling half-edge.
	for _, oldID := range n.neighbors[layer] {
		if _, stillThere := kept[oldID]; stillThere {
			continue
		}
		if dropped, ok := idx.nodes[oldID]; ok && layer <= dropped.layer() {
			dropped.neighbors[layer] = removeID(dropped.neighbors[layer], id)
		}
	}

	n.neighbors[layer] = newNeighbors
}

// sortCandidates sorts a candidate slice by distance, nearest-first. It is a
// small insertion sort, which is efficient for the short lists involved here.
func sortCandidates(c []candidate) {
	for i := 1; i < len(c); i++ {
		key := c[i]
		j := i - 1
		for j >= 0 && c[j].dist > key.dist {
			c[j+1] = c[j]
			j--
		}
		c[j+1] = key
	}
}
