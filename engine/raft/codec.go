package raft

import (
	"encoding/binary"
	"errors"
	"fmt"

	"naylamp/engine/cluster"
)

// EnvelopeKind is the cluster envelope family for Raft consensus traffic.
const EnvelopeKind cluster.Kind = 1

// Wire layout of a Message body, little-endian. From and To are not in the
// body: they travel in the cluster envelope, which already frames and
// checksums the whole message; carrying them twice would create two sources
// of truth that could disagree.
//
//	kind      uint16
//	term      uint64
//	logIndex  uint64
//	logTerm   uint64
//	commit    uint64
//	lastIndex uint64
//	offset    uint64
//	flags     uint8 (bit 0 granted, bit 1 done; any other bit is invalid)
//	nEntries  uint32
//	chunkLen  uint32
//	entries   nEntries times: index uint64, term uint64, dataLen uint32, data
//	chunk     chunkLen bytes
const (
	msgHeaderSize  = 2 + 8 + 8 + 8 + 8 + 8 + 8 + 1 + 4 + 4
	entryFixedSize = 8 + 8 + 4

	flagGranted = 1 << 0
	flagDone    = 1 << 1
)

var (
	// ErrWrongEnvelopeKind reports an envelope that is not raft traffic.
	ErrWrongEnvelopeKind = errors.New("raft: envelope does not carry raft traffic")
	// ErrMalformedMessage reports a body that does not parse cleanly.
	ErrMalformedMessage = errors.New("raft: malformed message body")
)

// EncodeMsg frames a raft message for the transport: a fixed-layout body
// wrapped in a cluster envelope, which adds routing and CRC integrity. The
// envelope's payload cap bounds the whole thing, so oversize batches and
// chunks fail here instead of on the wire.
func EncodeMsg(m Message) ([]byte, error) {
	size := msgHeaderSize + len(m.Chunk)
	for _, e := range m.Entries {
		size += entryFixedSize + len(e.Data)
	}
	body := make([]byte, 0, size)
	var scratch [8]byte

	binary.LittleEndian.PutUint16(scratch[:2], uint16(m.Kind))
	body = append(body, scratch[:2]...)
	for _, v := range []uint64{m.Term, m.LogIndex, m.LogTerm, m.Commit, m.LastIndex, m.Offset} {
		binary.LittleEndian.PutUint64(scratch[:8], v)
		body = append(body, scratch[:8]...)
	}
	var flags byte
	if m.Granted {
		flags |= flagGranted
	}
	if m.Done {
		flags |= flagDone
	}
	body = append(body, flags)
	binary.LittleEndian.PutUint32(scratch[:4], uint32(len(m.Entries))) //nolint:gosec // bounded by the envelope payload cap at wrap time
	body = append(body, scratch[:4]...)
	binary.LittleEndian.PutUint32(scratch[:4], uint32(len(m.Chunk))) //nolint:gosec // bounded by the envelope payload cap at wrap time
	body = append(body, scratch[:4]...)
	for _, e := range m.Entries {
		binary.LittleEndian.PutUint64(scratch[:8], e.Index)
		body = append(body, scratch[:8]...)
		binary.LittleEndian.PutUint64(scratch[:8], e.Term)
		body = append(body, scratch[:8]...)
		binary.LittleEndian.PutUint32(scratch[:4], uint32(len(e.Data))) //nolint:gosec // bounded by the envelope payload cap at wrap time
		body = append(body, scratch[:4]...)
		body = append(body, e.Data...)
	}
	body = append(body, m.Chunk...)
	return cluster.EncodeMessage(cluster.Envelope{From: m.From, To: m.To, Kind: EnvelopeKind, Payload: body})
}

// DecodeMsg parses one framed raft message: envelope first (routing, CRC),
// then the body.
func DecodeMsg(data []byte) (Message, error) {
	env, err := cluster.DecodeMessage(data)
	if err != nil {
		return Message{}, err
	}
	return DecodeMsgEnvelope(env)
}

// DecodeMsgEnvelope parses the raft body out of an already-decoded envelope.
// Every length is checked before it is trusted: a claimed entry count or
// chunk length that cannot fit in the payload is rejected before any
// allocation sized by it, and unknown flag bits fail loudly instead of being
// silently ignored.
func DecodeMsgEnvelope(env cluster.Envelope) (Message, error) {
	if env.Kind != EnvelopeKind {
		return Message{}, fmt.Errorf("%w: kind %d", ErrWrongEnvelopeKind, env.Kind)
	}
	b := env.Payload
	if len(b) < msgHeaderSize {
		return Message{}, ErrMalformedMessage
	}
	m := Message{From: env.From, To: env.To}
	m.Kind = MsgKind(binary.LittleEndian.Uint16(b[0:2]))
	m.Term = binary.LittleEndian.Uint64(b[2:10])
	m.LogIndex = binary.LittleEndian.Uint64(b[10:18])
	m.LogTerm = binary.LittleEndian.Uint64(b[18:26])
	m.Commit = binary.LittleEndian.Uint64(b[26:34])
	m.LastIndex = binary.LittleEndian.Uint64(b[34:42])
	m.Offset = binary.LittleEndian.Uint64(b[42:50])
	flags := b[50]
	if flags&^(byte(flagGranted)|byte(flagDone)) != 0 {
		return Message{}, fmt.Errorf("%w: invalid flags %#x", ErrMalformedMessage, flags)
	}
	m.Granted = flags&flagGranted != 0
	m.Done = flags&flagDone != 0
	n := binary.LittleEndian.Uint32(b[51:55])
	chunkLen := binary.LittleEndian.Uint32(b[55:59])
	rest := len(b) - msgHeaderSize
	if uint64(n)*entryFixedSize+uint64(chunkLen) > uint64(rest) { //nolint:gosec // rest >= 0 by the length check above, so the conversion cannot wrap
		return Message{}, ErrMalformedMessage
	}
	off := msgHeaderSize
	if n > 0 {
		m.Entries = make([]Entry, 0, n)
	}
	for i := uint32(0); i < n; i++ {
		if len(b)-off < entryFixedSize {
			return Message{}, ErrMalformedMessage
		}
		var e Entry
		e.Index = binary.LittleEndian.Uint64(b[off : off+8])
		e.Term = binary.LittleEndian.Uint64(b[off+8 : off+16])
		dataLen := int(binary.LittleEndian.Uint32(b[off+16 : off+20]))
		off += entryFixedSize
		if len(b)-off < dataLen {
			return Message{}, ErrMalformedMessage
		}
		if dataLen > 0 {
			e.Data = make([]byte, dataLen)
			copy(e.Data, b[off:off+dataLen])
		}
		off += dataLen
		m.Entries = append(m.Entries, e)
	}
	if len(b)-off != int(chunkLen) {
		return Message{}, fmt.Errorf("%w: %d bytes after entries, chunk header says %d", ErrMalformedMessage, len(b)-off, chunkLen)
	}
	if chunkLen > 0 {
		m.Chunk = make([]byte, chunkLen)
		copy(m.Chunk, b[off:])
	}
	return m, nil
}
