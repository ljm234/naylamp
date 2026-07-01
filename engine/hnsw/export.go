package hnsw

import (
	"math"

	"naylamp/engine/vector"
)

// This file defines the exported, serialization-friendly view of an index's
// state, plus Export/Restore. The persistence layer cannot read the index's
// private fields (nodes, neighbors, entry point), so the index exposes its
// state through these public types and reconstructs itself from them. This
// keeps graph internals encapsulated while letting an outside package save and
// load the graph.

// NodeSnapshot is the exported state of a single graph node: its id, cached
// data and norm, and its per-layer neighbor id lists. neighbors[layer] holds
// the ids this node links to on that layer.
type NodeSnapshot struct {
	ID        uint64
	Data      []float32
	Norm      float32
	Neighbors [][]uint64
}

// IndexSnapshot is the exported state of an entire index: its parameters, the
// entry point and layer bookkeeping, and every node. It is everything needed
// to rebuild the graph exactly, with no dependency on the original process.
type IndexSnapshot struct {
	M              int
	EfConstruction int
	EfSearch       int

	EntryPoint uint64
	MaxLayer   int
	HasEntry   bool

	Nodes []NodeSnapshot
}

// Export returns a snapshot of the index's current state under a read lock.
// Nodes are emitted in ascending id order so the output is deterministic (Go
// map iteration order is random, which would otherwise make snapshots differ
// byte-for-byte between runs).
func (idx *Index) Export() IndexSnapshot {
	idx.mu.RLock()
	defer idx.mu.RUnlock()

	ids := make([]uint64, 0, len(idx.nodes))
	for id := range idx.nodes {
		ids = append(ids, id)
	}
	sortUint64(ids)

	nodes := make([]NodeSnapshot, 0, len(ids))
	for _, id := range ids {
		n := idx.nodes[id]
		neighbors := make([][]uint64, len(n.neighbors))
		for layer := range n.neighbors {
			layerCopy := make([]uint64, len(n.neighbors[layer]))
			copy(layerCopy, n.neighbors[layer])
			neighbors[layer] = layerCopy
		}
		dataCopy := make([]float32, len(n.data))
		copy(dataCopy, n.data)

		nodes = append(nodes, NodeSnapshot{
			ID:        n.id,
			Data:      dataCopy,
			Norm:      n.norm,
			Neighbors: neighbors,
		})
	}

	return IndexSnapshot{
		M:              idx.params.M,
		EfConstruction: idx.params.EfConstruction,
		EfSearch:       idx.params.EfSearch,
		EntryPoint:     idx.entryPoint,
		MaxLayer:       idx.maxLayer,
		HasEntry:       idx.hasEntry,
		Nodes:          nodes,
	}
}

// RestoreIndex rebuilds an index from a snapshot produced by Export. The metric
// and vectorData closure are not part of the snapshot (they are functions, not
// data), so the caller supplies them, exactly as when constructing a fresh
// index. The reconstructed graph is identical to the original: same nodes, same
// neighbor lists, same entry point, so searches return the same results.
func RestoreIndex(snap IndexSnapshot, metric vector.MetricFunc, vectorData func(id uint64) ([]float32, bool)) *Index {
	params := Params{
		M:              snap.M,
		EfConstruction: snap.EfConstruction,
		EfSearch:       snap.EfSearch,
	}

	idx := &Index{
		params:        params,
		metric:        metric,
		useCosineFast: sameFunc(metric, vector.CosineDistance),
		vectorData:    vectorData,
		nodes:         make(map[uint64]*node, len(snap.Nodes)),
		entryPoint:    snap.EntryPoint,
		maxLayer:      snap.MaxLayer,
		hasEntry:      snap.HasEntry,
		levelMult:     1.0 / math.Log(float64(params.M)),
	}

	for _, ns := range snap.Nodes {
		neighbors := make([][]uint64, len(ns.Neighbors))
		for layer := range ns.Neighbors {
			layerCopy := make([]uint64, len(ns.Neighbors[layer]))
			copy(layerCopy, ns.Neighbors[layer])
			neighbors[layer] = layerCopy
		}
		dataCopy := make([]float32, len(ns.Data))
		copy(dataCopy, ns.Data)

		idx.nodes[ns.ID] = &node{
			id:        ns.ID,
			data:      dataCopy,
			norm:      ns.Norm,
			neighbors: neighbors,
		}
	}

	return idx
}

// sortUint64 sorts a slice of uint64 ascending with a simple insertion sort.
// Export is not on the hot path (it runs once per snapshot), so this is fine.
func sortUint64(s []uint64) {
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
