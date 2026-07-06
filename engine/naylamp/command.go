package naylamp

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// Replicated command layout, little-endian. A command is the opaque payload
// of one raft log entry: the consensus layer orders and moves these bytes
// without reading them, and the state machine below decodes and applies
// them. Keeping the language this small, upsert and delete, is what makes
// replicas trivially comparable: equal command sequences produce equal
// engines.
//
//	op     uint8  (1 upsert, 2 delete)
//	id     uint64
//	count  uint32 (upsert only)
//	data   count times float32 bits (upsert only)
const (
	opUpsert byte = 1
	opDelete byte = 2

	cmdHeaderSize   = 1 + 8
	upsertFixedSize = cmdHeaderSize + 4
)

// ErrMalformedCommand reports a log payload that does not parse cleanly.
// Fail loud on purpose: a malformed command inside a committed entry means
// corruption or version skew, and applying a guess would diverge replicas
// silently, which is the one failure a replicated state machine can never
// tolerate.
var ErrMalformedCommand = errors.New("naylamp: malformed replicated command")

// command is one decoded state machine operation.
type command struct {
	Op  byte
	ID  uint64
	Vec []float32
}

// encodeUpsert frames an upsert of one vector under an id. Float bits are
// preserved exactly: the codec is a transport, not a place for numeric
// policy.
func encodeUpsert(id uint64, vec []float32) []byte {
	buf := make([]byte, upsertFixedSize+4*len(vec))
	buf[0] = opUpsert
	binary.LittleEndian.PutUint64(buf[1:9], id)
	binary.LittleEndian.PutUint32(buf[9:13], uint32(len(vec))) //nolint:gosec // the node validates the dimension before encoding, far below uint32
	for i, v := range vec {
		binary.LittleEndian.PutUint32(buf[13+4*i:17+4*i], math.Float32bits(v))
	}
	return buf
}

// encodeDelete frames a delete of one id.
func encodeDelete(id uint64) []byte {
	buf := make([]byte, cmdHeaderSize)
	buf[0] = opDelete
	binary.LittleEndian.PutUint64(buf[1:9], id)
	return buf
}

// decodeCommand parses one replicated command, validating every length
// before trusting it: a lying count is rejected before any allocation is
// sized by it, and trailing bytes fail loudly so a framing bug cannot
// smuggle data past the state machine.
func decodeCommand(b []byte) (command, error) {
	if len(b) < cmdHeaderSize {
		return command{}, fmt.Errorf("%w: %d bytes", ErrMalformedCommand, len(b))
	}
	c := command{Op: b[0], ID: binary.LittleEndian.Uint64(b[1:9])}
	switch c.Op {
	case opDelete:
		if len(b) != cmdHeaderSize {
			return command{}, fmt.Errorf("%w: %d trailing bytes on delete", ErrMalformedCommand, len(b)-cmdHeaderSize)
		}
		return c, nil
	case opUpsert:
		if len(b) < upsertFixedSize {
			return command{}, fmt.Errorf("%w: truncated upsert header", ErrMalformedCommand)
		}
		count := binary.LittleEndian.Uint32(b[9:13])
		if count == 0 {
			return command{}, fmt.Errorf("%w: upsert with zero dimensions", ErrMalformedCommand)
		}
		rest := len(b) - upsertFixedSize
		if uint64(count)*4 != uint64(rest) { //nolint:gosec // rest >= 0 by the length check above, so the conversion cannot wrap
			return command{}, fmt.Errorf("%w: count %d does not match %d payload bytes", ErrMalformedCommand, count, rest)
		}
		c.Vec = make([]float32, count)
		for i := range c.Vec {
			c.Vec[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[upsertFixedSize+4*i : upsertFixedSize+4*i+4]))
		}
		return c, nil
	default:
		return command{}, fmt.Errorf("%w: unknown op %d", ErrMalformedCommand, c.Op)
	}
}
