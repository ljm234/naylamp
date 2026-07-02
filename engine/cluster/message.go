package cluster

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"

	"naylamp/engine/persist"
)

// Kind distinguishes message families carried over the transport. Raft
// defines its own kinds in 3.2; the substrate only moves them.
type Kind uint16

// Envelope is the unit that crosses the wire: who sent it, who it is for,
// which family it belongs to, and an opaque payload owned by that family.
// From and To travel inside the frame so a transport can verify routing and
// a receiver never has to trust connection state alone.
type Envelope struct {
	From    NodeID
	To      NodeID
	Kind    Kind
	Payload []byte
}

const (
	// envelopeHeader is From(8) + To(8) + Kind(2) + payload length(4).
	envelopeHeader = 8 + 8 + 2 + 4

	// maxMessagePayload bounds a single wire message. Large transfers (e.g.
	// snapshot installation) must chunk below this limit.
	maxMessagePayload = 1 << 24 // 16 MiB
)

// Errors returned when encoding or decoding a cluster message envelope.
var (
	ErrPayloadTooLarge  = errors.New("cluster: message payload exceeds limit")
	ErrTruncatedMessage = errors.New("cluster: truncated message envelope")
	ErrWrongBlockType   = errors.New("cluster: block is not a cluster message")
	ErrInvalidNode      = errors.New("cluster: message with reserved node id 0")
)

// EncodeMessage frames an envelope with the same CRC block format used on
// disk. Zero node ids are rejected so a forgotten field fails loudly here
// instead of surfacing later as a misrouted message.
func EncodeMessage(env Envelope) ([]byte, error) {
	if env.From == None || env.To == None {
		return nil, ErrInvalidNode
	}
	if len(env.Payload) > maxMessagePayload {
		return nil, fmt.Errorf("%w: %d bytes", ErrPayloadTooLarge, len(env.Payload))
	}
	body := make([]byte, envelopeHeader+len(env.Payload))
	binary.LittleEndian.PutUint64(body[0:8], uint64(env.From))
	binary.LittleEndian.PutUint64(body[8:16], uint64(env.To))
	binary.LittleEndian.PutUint16(body[16:18], uint16(env.Kind))
	binary.LittleEndian.PutUint32(body[18:22], uint32(len(env.Payload))) //nolint:gosec // bounded by maxMessagePayload check above
	copy(body[envelopeHeader:], env.Payload)

	var buf bytes.Buffer
	if _, err := persist.WriteBlock(&buf, persist.BlockClusterMessage, body); err != nil {
		return nil, fmt.Errorf("cluster: encode message: %w", err)
	}
	return buf.Bytes(), nil
}

// DecodeMessage parses exactly one framed envelope, verifying the CRC
// framing, the block type, the declared payload length, and that no trailing
// bytes follow the frame (a concatenation bug should fail loudly).
func DecodeMessage(data []byte) (Envelope, error) {
	r := bytes.NewReader(data)
	typ, body, err := persist.ReadBlock(r)
	if err != nil {
		return Envelope{}, fmt.Errorf("cluster: decode message: %w", err)
	}
	if typ != persist.BlockClusterMessage {
		return Envelope{}, fmt.Errorf("%w: got type %d", ErrWrongBlockType, typ)
	}
	if r.Len() != 0 {
		return Envelope{}, fmt.Errorf("cluster: decode message: %d trailing bytes after frame", r.Len())
	}
	if len(body) < envelopeHeader {
		return Envelope{}, ErrTruncatedMessage
	}
	payloadLen := binary.LittleEndian.Uint32(body[18:22])
	if payloadLen > maxMessagePayload {
		return Envelope{}, fmt.Errorf("%w: %d bytes", ErrPayloadTooLarge, payloadLen)
	}
	if len(body) != envelopeHeader+int(payloadLen) {
		return Envelope{}, ErrTruncatedMessage
	}
	env := Envelope{
		From: NodeID(binary.LittleEndian.Uint64(body[0:8])),
		To:   NodeID(binary.LittleEndian.Uint64(body[8:16])),
		Kind: Kind(binary.LittleEndian.Uint16(body[16:18])),
	}
	if env.From == None || env.To == None {
		return Envelope{}, ErrInvalidNode
	}
	env.Payload = make([]byte, payloadLen)
	copy(env.Payload, body[envelopeHeader:])
	return env, nil
}
