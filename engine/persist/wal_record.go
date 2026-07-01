package persist

import (
	"encoding/binary"
	"fmt"

	"naylamp/engine/vector"
)

// OpType identifies what kind of mutation a WAL record represents. The log
// replays these in order to rebuild engine state after a restart.
type OpType uint8

const (
	// OpUpsert inserts or updates a vector. Its payload is a serialized vector.
	OpUpsert OpType = 1
	// OpDelete removes a vector by id. Its payload is just the id.
	OpDelete OpType = 2
)

// WALRecord is one logged mutation: a sequence number, an operation type, and
// the data needed to replay it. For OpUpsert the vector carries the full data;
// for OpDelete only ID is meaningful.
type WALRecord struct {
	LSN    uint64 // monotonic log sequence number, assigned on append
	Op     OpType
	Vector vector.Vector // full vector for OpUpsert; ID only for OpDelete
}

// encodeWALRecord serializes a record to bytes. Layout, all little-endian:
//
//	lsn  uint64 (8 bytes)
//	op   uint8  (1 byte)
//	for OpUpsert: an encoded vector (id + dim + data)
//	for OpDelete: id uint64 (8 bytes)
//
// The record is meant to be wrapped by writeBlock (which adds the CRC and
// length framing), so torn writes are detected at the block layer.
func encodeWALRecord(r WALRecord) []byte {
	head := make([]byte, 8+1)
	binary.LittleEndian.PutUint64(head[0:], r.LSN)
	head[8] = byte(r.Op)

	switch r.Op {
	case OpUpsert:
		return append(head, encodeVector(r.Vector)...)
	case OpDelete:
		idBuf := make([]byte, 8)
		binary.LittleEndian.PutUint64(idBuf, r.Vector.ID)
		return append(head, idBuf...)
	default:
		// Unknown op: still emit the header so a reader fails cleanly on decode.
		return head
	}
}

// decodeWALRecord reconstructs a record from bytes produced by encodeWALRecord,
// validating lengths so a short or corrupt payload returns a typed error.
func decodeWALRecord(buf []byte) (WALRecord, error) {
	var r WALRecord
	if len(buf) < 9 { // lsn(8) + op(1)
		return r, fmt.Errorf("%w: wal record header needs 9 bytes, got %d", ErrTruncatedPayload, len(buf))
	}
	r.LSN = binary.LittleEndian.Uint64(buf[0:])
	r.Op = OpType(buf[8])
	rest := buf[9:]

	switch r.Op {
	case OpUpsert:
		v, err := decodeVector(rest)
		if err != nil {
			return r, fmt.Errorf("wal record %d upsert payload: %w", r.LSN, err)
		}
		r.Vector = v
	case OpDelete:
		if len(rest) < 8 {
			return r, fmt.Errorf("%w: wal delete needs an 8-byte id, got %d", ErrTruncatedPayload, len(rest))
		}
		r.Vector = vector.Vector{ID: binary.LittleEndian.Uint64(rest)}
	default:
		return r, fmt.Errorf("persist: unknown wal op type %d at lsn %d", r.Op, r.LSN)
	}

	return r, nil
}
