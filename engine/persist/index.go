package persist

import (
	"bytes"
	"fmt"
	"io"

	"naylamp/engine/hnsw"
)

// EncodeIndex serializes an entire index snapshot to a byte stream: one meta
// block followed by one node block per node. The meta block records how many
// node blocks follow, so DecodeIndex knows exactly how many to read. Each block
// carries its own CRC via writeBlock, so corruption of any block is detected.
func EncodeIndex(w io.Writer, snap hnsw.IndexSnapshot) error {
	meta := encodeIndexMeta(snap)
	if _, err := writeBlock(w, BlockIndexMeta, meta); err != nil {
		return fmt.Errorf("persist: write index meta: %w", err)
	}
	for i := range snap.Nodes {
		nodeBytes := encodeNode(snap.Nodes[i])
		if _, err := writeBlock(w, BlockNode, nodeBytes); err != nil {
			return fmt.Errorf("persist: write node %d: %w", i, err)
		}
	}
	return nil
}

// DecodeIndex reads a stream produced by EncodeIndex back into an index
// snapshot: first the meta block, then the exact number of node blocks it
// announced. It returns a typed error if a block is the wrong type, corrupt, or
// truncated.
func DecodeIndex(r io.Reader) (hnsw.IndexSnapshot, error) {
	var snap hnsw.IndexSnapshot

	typ, payload, err := readBlock(r)
	if err != nil {
		return snap, fmt.Errorf("persist: read index meta: %w", err)
	}
	if typ != BlockIndexMeta {
		return snap, fmt.Errorf("persist: expected index meta block, got type %d", typ)
	}
	snap, numNodes, err := decodeIndexMeta(payload)
	if err != nil {
		return snap, err
	}

	snap.Nodes = make([]hnsw.NodeSnapshot, 0, numNodes)
	for i := uint64(0); i < numNodes; i++ {
		typ, payload, err := readBlock(r)
		if err != nil {
			return snap, fmt.Errorf("persist: read node %d: %w", i, err)
		}
		if typ != BlockNode {
			return snap, fmt.Errorf("persist: expected node block, got type %d", typ)
		}
		n, err := decodeNode(payload)
		if err != nil {
			return snap, fmt.Errorf("persist: decode node %d: %w", i, err)
		}
		snap.Nodes = append(snap.Nodes, n)
	}

	return snap, nil
}

// EncodeIndexToBytes is a convenience wrapper that serializes a snapshot to a
// byte slice, used in tests and small callers.
func EncodeIndexToBytes(snap hnsw.IndexSnapshot) ([]byte, error) {
	var buf bytes.Buffer
	if err := EncodeIndex(&buf, snap); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// DecodeIndexFromBytes is the inverse of EncodeIndexToBytes.
func DecodeIndexFromBytes(b []byte) (hnsw.IndexSnapshot, error) {
	return DecodeIndex(bytes.NewReader(b))
}
