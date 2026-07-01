package persist

import (
	"bytes"
	"errors"
	"math/rand/v2"
	"testing"

	"naylamp/engine/hnsw"
	"naylamp/engine/vector"
)

// randVector builds a deterministic random vector of the given dimension.
func randVector(rng *rand.Rand, id uint64, dim int) vector.Vector {
	data := make([]float32, dim)
	for i := range data {
		data[i] = float32(rng.NormFloat64())
	}
	return vector.Vector{ID: id, Data: data}
}

// TestCodec_VectorRoundTrip checks that decode(encode(v)) == v for many random
// vectors across a range of dimensions. Equality is exact: float32 bits survive
// the round trip unchanged because we serialize the raw bit pattern.
func TestCodec_VectorRoundTrip(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security
	dims := []int{1, 2, 8, 64, 128, 384, 1536}

	for _, dim := range dims {
		for i := 0; i < 1000; i++ {
			v := randVector(rng, uint64(i+1), dim)
			buf := encodeVector(v)
			got, err := decodeVector(buf)
			if err != nil {
				t.Fatalf("dim %d: decode failed: %v", dim, err)
			}
			if got.ID != v.ID {
				t.Fatalf("dim %d: id mismatch: got %d want %d", dim, got.ID, v.ID)
			}
			if len(got.Data) != len(v.Data) {
				t.Fatalf("dim %d: len mismatch: got %d want %d", dim, len(got.Data), len(v.Data))
			}
			for j := range v.Data {
				if got.Data[j] != v.Data[j] {
					t.Fatalf("dim %d idx %d: data mismatch: got %v want %v", dim, j, got.Data[j], v.Data[j])
				}
			}
		}
	}
}

// TestCodec_VectorTruncated checks that a truncated vector payload returns a
// typed error instead of panicking.
func TestCodec_VectorTruncated(t *testing.T) {
	v := vector.Vector{ID: 7, Data: []float32{1, 2, 3, 4}}
	buf := encodeVector(v)

	// Cut the buffer short in several places.
	for _, cut := range []int{0, 4, 11, 13, len(buf) - 1} {
		_, err := decodeVector(buf[:cut])
		if err == nil {
			t.Fatalf("cut at %d: expected error, got nil", cut)
		}
		if !errors.Is(err, ErrTruncatedPayload) {
			t.Fatalf("cut at %d: expected ErrTruncatedPayload, got %v", cut, err)
		}
	}
}

// TestCodec_NodeRoundTrip checks that a graph node snapshot survives encode and
// decode unchanged, including its per-layer neighbor lists.
func TestCodec_NodeRoundTrip(t *testing.T) {
	rng := rand.New(rand.NewPCG(2, 0)) //nolint:gosec // deterministic RNG for reproducible test data, not security

	for i := 0; i < 1000; i++ {
		numLayers := rng.IntN(4) + 1
		neighbors := make([][]uint64, numLayers)
		for l := range neighbors {
			cnt := rng.IntN(40)
			layer := make([]uint64, cnt)
			for j := range layer {
				layer[j] = rng.Uint64()
			}
			neighbors[l] = layer
		}
		dim := rng.IntN(128) + 1
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}

		n := hnsw.NodeSnapshot{
			ID:        uint64(i + 1),
			Data:      data,
			Norm:      float32(rng.NormFloat64()),
			Neighbors: neighbors,
		}

		buf := encodeNode(n)
		got, err := decodeNode(buf)
		if err != nil {
			t.Fatalf("decode node failed: %v", err)
		}
		if got.ID != n.ID || got.Norm != n.Norm {
			t.Fatalf("id/norm mismatch: got (%d,%v) want (%d,%v)", got.ID, got.Norm, n.ID, n.Norm)
		}
		if len(got.Neighbors) != len(n.Neighbors) {
			t.Fatalf("layer count mismatch: got %d want %d", len(got.Neighbors), len(n.Neighbors))
		}
		for l := range n.Neighbors {
			if len(got.Neighbors[l]) != len(n.Neighbors[l]) {
				t.Fatalf("layer %d neighbor count mismatch", l)
			}
			for j := range n.Neighbors[l] {
				if got.Neighbors[l][j] != n.Neighbors[l][j] {
					t.Fatalf("layer %d idx %d neighbor mismatch", l, j)
				}
			}
		}
		for j := range n.Data {
			if got.Data[j] != n.Data[j] {
				t.Fatalf("data idx %d mismatch", j)
			}
		}
	}
}

// TestCodec_IndexMetaRoundTrip checks that index-level metadata survives encode
// and decode, and that the node count is reported back correctly.
func TestCodec_IndexMetaRoundTrip(t *testing.T) {
	snap := hnsw.IndexSnapshot{
		M:              32,
		EfConstruction: 400,
		EfSearch:       300,
		EntryPoint:     12345,
		MaxLayer:       7,
		HasEntry:       true,
		Nodes:          make([]hnsw.NodeSnapshot, 91),
	}

	buf := encodeIndexMeta(snap)
	got, numNodes, err := decodeIndexMeta(buf)
	if err != nil {
		t.Fatalf("decode meta failed: %v", err)
	}
	if got.M != snap.M || got.EfConstruction != snap.EfConstruction || got.EfSearch != snap.EfSearch {
		t.Fatalf("params mismatch: got %+v want %+v", got, snap)
	}
	if got.EntryPoint != snap.EntryPoint || got.MaxLayer != snap.MaxLayer || got.HasEntry != snap.HasEntry {
		t.Fatalf("bookkeeping mismatch: got %+v want %+v", got, snap)
	}
	if numNodes != 91 {
		t.Fatalf("node count mismatch: got %d want 91", numNodes)
	}
}

// TestBlock_RoundTrip checks that a payload framed by writeBlock is read back
// intact by readBlock, with the correct block type.
func TestBlock_RoundTrip(t *testing.T) {
	payload := []byte("hello naylamp durability")
	var buf bytes.Buffer
	if _, err := writeBlock(&buf, BlockVector, payload); err != nil {
		t.Fatalf("writeBlock: %v", err)
	}
	typ, got, err := readBlock(&buf)
	if err != nil {
		t.Fatalf("readBlock: %v", err)
	}
	if typ != BlockVector {
		t.Fatalf("type mismatch: got %d want %d", typ, BlockVector)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("payload mismatch: got %q want %q", got, payload)
	}
}

// TestBlock_DetectsCorruption checks that flipping a byte in the payload makes
// the CRC check fail, so corruption is caught instead of silently loaded.
func TestBlock_DetectsCorruption(t *testing.T) {
	payload := []byte("data that must not corrupt silently")
	var buf bytes.Buffer
	if _, err := writeBlock(&buf, BlockVector, payload); err != nil {
		t.Fatalf("writeBlock: %v", err)
	}

	raw := buf.Bytes()
	// Flip a bit in the payload region (after the headerSize-byte header).
	raw[headerSize+5] ^= 0xFF

	_, _, err := readBlock(bytes.NewReader(raw))
	if !errors.Is(err, ErrChecksum) {
		t.Fatalf("expected ErrChecksum, got %v", err)
	}
}

// TestBlock_RejectsBadMagic checks that data not starting with the Naylamp
// magic number is rejected.
func TestBlock_RejectsBadMagic(t *testing.T) {
	raw := make([]byte, headerSize+4)
	// Leave magic as zero (not the Naylamp magic).
	_, _, err := readBlock(bytes.NewReader(raw))
	if !errors.Is(err, ErrBadMagic) {
		t.Fatalf("expected ErrBadMagic, got %v", err)
	}
}

// TestBlock_DetectsShortBlock checks that a truncated block (a torn write, e.g.
// a crash mid-write) is reported as ErrShortBlock rather than misread.
func TestBlock_DetectsShortBlock(t *testing.T) {
	payload := []byte("a reasonably long payload to truncate")
	var buf bytes.Buffer
	if _, err := writeBlock(&buf, BlockVector, payload); err != nil {
		t.Fatalf("writeBlock: %v", err)
	}
	raw := buf.Bytes()

	// Truncate inside the payload (header complete, payload cut).
	_, _, err := readBlock(bytes.NewReader(raw[:headerSize+3]))
	if !errors.Is(err, ErrShortBlock) {
		t.Fatalf("expected ErrShortBlock, got %v", err)
	}
}
