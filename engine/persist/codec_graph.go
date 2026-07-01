package persist

import (
	"encoding/binary"
	"fmt"

	"naylamp/engine/hnsw"
)

// maxNeighbors and maxLayers are sanity ceilings to avoid allocating huge
// slices from a corrupted length field. Real graphs stay far below these.
const (
	maxLayers    = 1 << 16 // 65,536 layers (HNSW uses a handful in practice)
	maxNeighbors = 1 << 24 // per-layer neighbor cap, generous but bounded
)

// encodeNode serializes one HNSW node snapshot. Layout, all little-endian:
//
//	id        uint64
//	norm      float32 (as uint32 bits)
//	numLayers uint32
//	for each layer:
//	    numNeighbors uint32
//	    neighbor ids  numNeighbors * uint64
//	dim       uint32
//	data      dim * float32 (as uint32 bits)
func encodeNode(n hnsw.NodeSnapshot) []byte {
	// Pre-compute size: id + norm + numLayers.
	size := 8 + 4 + 4
	for _, layer := range n.Neighbors {
		size += 4 + len(layer)*8 // numNeighbors + ids
	}
	size += 4 + len(n.Data)*4 // dim + data

	buf := make([]byte, size)
	off := 0
	binary.LittleEndian.PutUint64(buf[off:], n.ID)
	off += 8
	binary.LittleEndian.PutUint32(buf[off:], float32bits(n.Norm))
	off += 4
	binary.LittleEndian.PutUint32(buf[off:], uint32(len(n.Neighbors))) //nolint:gosec // layer count is a slice length, bounded by maxLayers on decode
	off += 4

	for _, layer := range n.Neighbors {
		binary.LittleEndian.PutUint32(buf[off:], uint32(len(layer))) //nolint:gosec // neighbor count is a slice length, bounded by maxNeighbors on decode
		off += 4
		for _, id := range layer {
			binary.LittleEndian.PutUint64(buf[off:], id)
			off += 8
		}
	}

	binary.LittleEndian.PutUint32(buf[off:], uint32(len(n.Data))) //nolint:gosec // dim is a slice length, bounded by maxDims on decode
	off += 4
	for _, x := range n.Data {
		binary.LittleEndian.PutUint32(buf[off:], float32bits(x))
		off += 4
	}

	return buf
}

// decodeNode reconstructs a node snapshot from bytes produced by encodeNode,
// validating the buffer length at every step so a short or corrupt payload
// returns a typed error instead of panicking.
func decodeNode(buf []byte) (hnsw.NodeSnapshot, error) {
	var n hnsw.NodeSnapshot
	off := 0

	if len(buf) < 16 { // id(8) + norm(4) + numLayers(4)
		return n, fmt.Errorf("%w: node header needs 16 bytes, got %d", ErrTruncatedPayload, len(buf))
	}
	n.ID = binary.LittleEndian.Uint64(buf[off:])
	off += 8
	n.Norm = float32frombits(binary.LittleEndian.Uint32(buf[off:]))
	off += 4
	numLayers := binary.LittleEndian.Uint32(buf[off:])
	off += 4
	if numLayers > maxLayers {
		return n, fmt.Errorf("%w: %d layers", ErrTooManyDims, numLayers)
	}

	n.Neighbors = make([][]uint64, numLayers)
	for l := uint32(0); l < numLayers; l++ {
		if len(buf) < off+4 {
			return n, fmt.Errorf("%w: missing neighbor count for layer %d", ErrTruncatedPayload, l)
		}
		numN := binary.LittleEndian.Uint32(buf[off:])
		off += 4
		if numN > maxNeighbors {
			return n, fmt.Errorf("%w: %d neighbors", ErrTooManyDims, numN)
		}
		if len(buf) < off+int(numN)*8 {
			return n, fmt.Errorf("%w: missing %d neighbor ids for layer %d", ErrTruncatedPayload, numN, l)
		}
		ids := make([]uint64, numN)
		for i := range ids {
			ids[i] = binary.LittleEndian.Uint64(buf[off:])
			off += 8
		}
		n.Neighbors[l] = ids
	}

	if len(buf) < off+4 {
		return n, fmt.Errorf("%w: missing dim", ErrTruncatedPayload)
	}
	dim := binary.LittleEndian.Uint32(buf[off:])
	off += 4
	if dim > maxDims {
		return n, fmt.Errorf("%w: %d dims", ErrTooManyDims, dim)
	}
	if len(buf) < off+int(dim)*4 {
		return n, fmt.Errorf("%w: missing %d data floats", ErrTruncatedPayload, dim)
	}
	data := make([]float32, dim)
	for i := range data {
		data[i] = float32frombits(binary.LittleEndian.Uint32(buf[off:]))
		off += 4
	}
	n.Data = data

	return n, nil
}

// encodeIndexMeta serializes the index-level metadata (everything in an
// IndexSnapshot except the nodes themselves). Layout, all little-endian:
//
//	M              uint64 (from int)
//	EfConstruction uint64 (from int)
//	EfSearch       uint64 (from int)
//	EntryPoint     uint64
//	MaxLayer       uint64 (from int)
//	HasEntry       uint8 (0 or 1)
//	NumNodes       uint64 (how many node blocks follow, for the reader's sake)
func encodeIndexMeta(snap hnsw.IndexSnapshot) []byte {
	buf := make([]byte, 8*5+1+8)
	off := 0
	binary.LittleEndian.PutUint64(buf[off:], uint64(snap.M)) //nolint:gosec // M is a small positive config value
	off += 8
	binary.LittleEndian.PutUint64(buf[off:], uint64(snap.EfConstruction)) //nolint:gosec // EfConstruction is a small positive config value
	off += 8
	binary.LittleEndian.PutUint64(buf[off:], uint64(snap.EfSearch)) //nolint:gosec // EfSearch is a small positive config value
	off += 8
	binary.LittleEndian.PutUint64(buf[off:], snap.EntryPoint)
	off += 8
	binary.LittleEndian.PutUint64(buf[off:], uint64(snap.MaxLayer)) //nolint:gosec // MaxLayer is a small non-negative value
	off += 8
	if snap.HasEntry {
		buf[off] = 1
	}
	off++
	binary.LittleEndian.PutUint64(buf[off:], uint64(len(snap.Nodes))) //nolint:gosec // node count is a slice length

	return buf
}

// decodeIndexMeta reconstructs the index-level metadata. It returns a partial
// IndexSnapshot with Nodes left nil; the caller fills Nodes from the node
// blocks that follow. NumNodes is returned so the caller knows how many to read.
func decodeIndexMeta(buf []byte) (snap hnsw.IndexSnapshot, numNodes uint64, err error) {
	const need = 8*5 + 1 + 8
	if len(buf) < need {
		return snap, 0, fmt.Errorf("%w: index meta needs %d bytes, got %d", ErrTruncatedPayload, need, len(buf))
	}
	off := 0
	snap.M = int(binary.LittleEndian.Uint64(buf[off:])) //nolint:gosec // round-trips a small positive config value
	off += 8
	snap.EfConstruction = int(binary.LittleEndian.Uint64(buf[off:])) //nolint:gosec // round-trips a small positive config value
	off += 8
	snap.EfSearch = int(binary.LittleEndian.Uint64(buf[off:])) //nolint:gosec // round-trips a small positive config value
	off += 8
	snap.EntryPoint = binary.LittleEndian.Uint64(buf[off:])
	off += 8
	snap.MaxLayer = int(binary.LittleEndian.Uint64(buf[off:])) //nolint:gosec // round-trips a small non-negative value
	off += 8
	snap.HasEntry = buf[off] == 1
	off++
	numNodes = binary.LittleEndian.Uint64(buf[off:])

	return snap, numNodes, nil
}
