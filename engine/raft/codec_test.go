package raft

import (
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
		{Kind: MsgApp, From: 1, To: 3, Term: 7, LogIndex: 45, LogTerm: 7, Commit: 45}, // heartbeat
		{Kind: MsgAppResp, From: 3, To: 1, Term: 7, Granted: true, LastIndex: 45},
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
	lie[43] = 200 // claims 200 entries, zero bytes behind them
	if _, err := DecodeMsgEnvelope(cluster.Envelope{From: 1, To: 2, Kind: EnvelopeKind,
		Payload: lie}); !errors.Is(err, ErrMalformedMessage) {
		t.Fatalf("impossible entry count accepted: %v", err)
	}

	// Invalid granted flag.
	badFlag := make([]byte, msgHeaderSize)
	badFlag[42] = 2
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
