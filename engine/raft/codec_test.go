package raft

import (
	"encoding/binary"
	"errors"
	"reflect"
	"testing"

	"naylamp/engine/cluster"
)

func TestCodec_RoundTripAllKinds(t *testing.T) {
	msgs := []Message{
		{Kind: MsgVote, From: 1, To: 2, Term: 7, LogIndex: 42, LogTerm: 6},
		{Kind: MsgVoteResp, From: 2, To: 1, Term: 7, Granted: true},
		{Kind: MsgVoteResp, From: 3, To: 1, Term: 7, Granted: false},
		{Kind: MsgApp, From: 1, To: 3, Term: 7, LogIndex: 42, LogTerm: 6, Commit: 40,
			Entries: []Entry{
				{Index: 43, Term: 7, Data: []byte("upsert")},
				{Index: 44, Term: 7}, // empty data survives
				{Index: 45, Term: 7, Data: []byte{0x00, 0xFF}},
			}},
		{Kind: MsgApp, From: 1, To: 3, Term: 7, LogIndex: 45, LogTerm: 7, Commit: 45},             // heartbeat
		{Kind: MsgApp, From: 1, To: 3, Term: 7, LogIndex: 45, LogTerm: 7, Commit: 45, ReadCtx: 7}, // read-carrying heartbeat
		{Kind: MsgAppResp, From: 3, To: 1, Term: 7, Granted: true, LastIndex: 45},
		{Kind: MsgAppResp, From: 3, To: 1, Term: 7, Granted: true, LastIndex: 45, ReadCtx: 7},
		{Kind: MsgAppResp, From: 3, To: 1, Term: 7, Granted: true, LastIndex: 45, Reached: true},
		{Kind: MsgAppResp, From: 3, To: 1, Term: 7, Granted: true, LastIndex: 45, ReadCtx: 7, Reached: true},
	}
	for _, want := range msgs {
		raw, err := EncodeMsg(want)
		if err != nil {
			t.Fatalf("encode %+v: %v", want, err)
		}
		got, err := DecodeMsg(raw)
		if err != nil {
			t.Fatalf("decode %+v: %v", want, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
		}
	}
}

func TestCodec_SnapshotRoundTripAndBounds(t *testing.T) {
	msgs := []Message{
		{Kind: MsgSnap, From: 1, To: 2, Term: 9, LogIndex: 120, LogTerm: 7, Commit: 130,
			Offset: 0, Chunk: []byte("first-chunk")},
		{Kind: MsgSnap, From: 1, To: 2, Term: 9, LogIndex: 120, LogTerm: 7,
			Offset: 11, Chunk: []byte{0x00, 0xFF}, Done: true},
		{Kind: MsgSnap, From: 1, To: 2, Term: 9, LogIndex: 120, LogTerm: 7,
			Offset: 13, Done: true}, // empty final chunk survives
		{Kind: MsgSnapResp, From: 2, To: 1, Term: 9, LogIndex: 120, Granted: true, Offset: 11},
		{Kind: MsgSnapResp, From: 2, To: 1, Term: 9, LogIndex: 120, Offset: 0},
	}
	for _, want := range msgs {
		raw, err := EncodeMsg(want)
		if err != nil {
			t.Fatalf("encode %+v: %v", want, err)
		}
		got, err := DecodeMsg(raw)
		if err != nil {
			t.Fatalf("decode %+v: %v", want, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
		}
	}

	// The reached bit (bit 2) decodes as a valid flag; a bit above it still
	// fails loudly instead of being silently ignored.
	raw, err := EncodeMsg(msgs[0])
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	env, err := cluster.DecodeMessage(raw)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	env.Payload[58] |= 1 << 2
	got, derr := DecodeMsgEnvelope(env)
	if derr != nil {
		t.Fatalf("reached bit rejected as invalid: %v", derr)
	}
	if !got.Reached {
		t.Fatalf("reached bit did not decode: %+v", got)
	}
	env.Payload[58] |= 1 << 3
	if _, derr := DecodeMsgEnvelope(env); !errors.Is(derr, ErrMalformedMessage) {
		t.Fatalf("flag bit above the reached bit accepted: %v", derr)
	}
	env.Payload[58] &^= (1 << 2) | (1 << 3) // restore valid flags before reusing the payload

	// A chunk length lying beyond the payload is rejected before any
	// allocation sized by it.
	lie := make([]byte, msgHeaderSize)
	binary.LittleEndian.PutUint32(lie[63:67], 500)
	if _, derr := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: lie}); !errors.Is(derr, ErrMalformedMessage) {
		t.Fatalf("impossible chunk length accepted: %v", derr)
	}

	// Entries and chunk together must account for every byte: a trailing
	// byte after the declared chunk is a framing bug and fails loudly.
	trailing := append(append([]byte(nil), env.Payload...), 0xAA)
	if _, derr := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: trailing}); !errors.Is(derr, ErrMalformedMessage) {
		t.Fatalf("trailing byte after chunk accepted: %v", derr)
	}
}

func TestCodec_CorruptionDetected(t *testing.T) {
	raw, err := EncodeMsg(Message{Kind: MsgApp, From: 1, To: 2, Term: 3,
		Entries: []Entry{{Index: 1, Term: 3, Data: []byte("x")}}})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	raw[len(raw)/2] ^= 0xFF
	if _, err := DecodeMsg(raw); err == nil {
		t.Fatalf("corrupted frame decoded without error")
	}
}

func TestCodec_WrongEnvelopeKind(t *testing.T) {
	raw, err := cluster.EncodeMessage(cluster.Envelope{From: 1, To: 2, Kind: 99, Payload: []byte("not raft")})
	if err != nil {
		t.Fatalf("encode envelope: %v", err)
	}
	if _, err := DecodeMsg(raw); !errors.Is(err, ErrWrongEnvelopeKind) {
		t.Fatalf("foreign envelope accepted: %v", err)
	}
}

func TestCodec_MalformedBodies(t *testing.T) {
	// Short body.
	if _, err := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: make([]byte, msgHeaderSize-1)}); !errors.Is(err, ErrMalformedMessage) {
		t.Fatalf("short body accepted: %v", err)
	}

	// Entry count that cannot fit in the payload.
	lie := make([]byte, msgHeaderSize)
	lie[59] = 200 // claims 200 entries, zero bytes behind them
	if _, err := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: lie}); !errors.Is(err, ErrMalformedMessage) {
		t.Fatalf("impossible entry count accepted: %v", err)
	}

	// A flag bit above the defined ones (bit 3 here) is invalid. The reached bit
	// (bit 2) is exercised as a valid flag in TestCodec_SnapshotRoundTripAndBounds.
	badFlag := make([]byte, msgHeaderSize)
	badFlag[58] = 1 << 3
	if _, err := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: badFlag}); !errors.Is(err, ErrMalformedMessage) {
		t.Fatalf("invalid flag accepted: %v", err)
	}

	// Trailing bytes after a valid body.
	raw, err := EncodeMsg(Message{Kind: MsgVote, From: 1, To: 2, Term: 1})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	env, err := cluster.DecodeMessage(raw)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	env.Payload = append(env.Payload, 0xAA)
	if _, err := DecodeMsgEnvelope(env); !errors.Is(err, ErrMalformedMessage) {
		t.Fatalf("trailing bytes accepted: %v", err)
	}
}
