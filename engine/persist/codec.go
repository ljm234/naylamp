package persist

import (
	"encoding/binary"
	"errors"
	"fmt"

	"naylamp/engine/vector"
)

// Codec errors.
var (
	// ErrTruncatedPayload means a payload ended before all expected fields were
	// read (a malformed or corrupted block that still passed the CRC, or a bug).
	ErrTruncatedPayload = errors.New("persist: truncated payload")
	// ErrTooManyDims guards against an absurd dimension count (likely corruption
	// or a malicious file) that would try to allocate a huge slice.
	ErrTooManyDims = errors.New("persist: dimension count exceeds sane limit")
)

// maxDims is a sanity ceiling on vector dimensionality, to avoid allocating
// gigabytes from a corrupted length field. Real embeddings are well under this.
const maxDims = 1 << 20 // 1,048,576

// encodeVector serializes a vector to bytes. Layout, all little-endian:
//
//	id   uint64 (8 bytes)
//	dim  uint32 (4 bytes)
//	data dim * float32 (4 bytes each)
//
// float32 bits are written with math.Float32bits via binary.LittleEndian, so
// the byte order is fixed and portable across architectures.
func encodeVector(v vector.Vector) []byte {
	dim := len(v.Data)
	buf := make([]byte, 8+4+dim*4)
	binary.LittleEndian.PutUint64(buf[0:], v.ID)
	binary.LittleEndian.PutUint32(buf[8:], uint32(dim)) //nolint:gosec // dim is a slice length, bounded by maxDims on decode
	off := 12
	for _, x := range v.Data {
		binary.LittleEndian.PutUint32(buf[off:], float32bits(x))
		off += 4
	}
	return buf
}

// decodeVector reconstructs a vector from bytes produced by encodeVector. It
// validates that the buffer is long enough at each step, returning a typed
// error rather than panicking on a short or corrupt payload.
func decodeVector(buf []byte) (vector.Vector, error) {
	if len(buf) < 12 {
		return vector.Vector{}, fmt.Errorf("%w: header needs 12 bytes, got %d", ErrTruncatedPayload, len(buf))
	}
	id := binary.LittleEndian.Uint64(buf[0:])
	dim := binary.LittleEndian.Uint32(buf[8:])
	if dim > maxDims {
		return vector.Vector{}, fmt.Errorf("%w: %d", ErrTooManyDims, dim)
	}

	need := 12 + int(dim)*4
	if len(buf) < need {
		return vector.Vector{}, fmt.Errorf("%w: need %d bytes for %d dims, got %d", ErrTruncatedPayload, need, dim, len(buf))
	}

	data := make([]float32, dim)
	off := 12
	for i := range data {
		data[i] = float32frombits(binary.LittleEndian.Uint32(buf[off:]))
		off += 4
	}
	return vector.Vector{ID: id, Data: data}, nil
}
