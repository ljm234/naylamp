package naylamp

import (
	"encoding/binary"
	"errors"
	"math"
	"reflect"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

func TestClientWire_RequestRoundTrips(t *testing.T) {
	reqs := []ClientRequest{
		// Upsert with edge floats (zero, negative, smallest subnormal, max
		// finite) and the maximum id, all bit-exact.
		{Op: ReqUpsert, ReqID: 7, ID: ^uint64(0), Vec: []float32{
			0, -1.5, math.Float32frombits(1), math.Float32frombits(0x7f7fffff),
		}},
		{Op: ReqDelete, ReqID: 8, ID: 42},
		{Op: ReqSearch, ReqID: 9, K: 1 << 20, Vec: []float32{1, 2, 3}},
	}
	for _, want := range reqs {
		raw, err := EncodeClientRequest(1, 2, want)
		if err != nil {
			t.Fatalf("encode %+v: %v", want, err)
		}
		env, err := cluster.DecodeMessage(raw)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		got, err := DecodeClientRequest(env)
		if err != nil {
			t.Fatalf("decode %+v: %v", want, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
		}
	}
}

func TestClientWire_ResponseRoundTrips(t *testing.T) {
	resps := []ClientResponse{
		{ReqID: 1, Status: StatusOK, Index: 42}, // write ok
		{ReqID: 2, Status: StatusOK, Neighbors: []vector.Neighbor{
			{ID: 5, Distance: 0.25}, {ID: 6, Distance: -1.5},
		}}, // search ok with neighbors
		{ReqID: 3, Status: StatusOK},                   // empty search ok
		{ReqID: 4, Status: StatusNotLeader, Leader: 7}, // redirect with a hint
		{ReqID: 5, Status: StatusNotLeader},            // redirect, leader unknown
		{ReqID: 6, Status: StatusNotReady},             // retryable
		{ReqID: 7, Status: StatusInvalidArgument},      // caller mistake
	}
	for _, want := range resps {
		raw, err := EncodeClientResponse(2, 1, want)
		if err != nil {
			t.Fatalf("encode %+v: %v", want, err)
		}
		env, err := cluster.DecodeMessage(raw)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		got, err := DecodeClientResponse(env)
		if err != nil {
			t.Fatalf("decode %+v: %v", want, err)
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("round-trip mismatch:\n got %+v\nwant %+v", got, want)
		}
	}
}

func TestClientWire_MalformedFailsLoudly(t *testing.T) {
	reqBody := func(op byte, reqID, id uint64, k, count uint32, tail []byte) []byte {
		b := make([]byte, clientReqHeaderSize)
		b[0] = op
		binary.LittleEndian.PutUint64(b[1:9], reqID)
		binary.LittleEndian.PutUint64(b[9:17], id)
		binary.LittleEndian.PutUint32(b[17:21], k)
		binary.LittleEndian.PutUint32(b[21:25], count)
		return append(b, tail...)
	}
	respBody := func(reqID uint64, status byte, leader, index uint64, count uint32, tail []byte) []byte {
		b := make([]byte, clientRespHeaderSize)
		binary.LittleEndian.PutUint64(b[0:8], reqID)
		b[8] = status
		binary.LittleEndian.PutUint64(b[9:17], leader)
		binary.LittleEndian.PutUint64(b[17:25], index)
		binary.LittleEndian.PutUint32(b[25:29], count)
		return append(b, tail...)
	}
	oneFloat := make([]byte, 4)
	oneNeighbor := make([]byte, neighborFixedSize)
	env := func(payload []byte) cluster.Envelope {
		return cluster.Envelope{From: 1, To: 2, Kind: ClientKind, Payload: payload}
	}

	reqCases := []struct {
		name string
		body []byte
	}{
		{"short body", make([]byte, clientReqHeaderSize-1)},
		{"unknown op", reqBody(99, 1, 0, 0, 0, nil)},
		{"count lying high", reqBody(byte(ReqSearch), 1, 0, 0, 1<<28, oneFloat)},
		{"count lying low", reqBody(byte(ReqSearch), 1, 0, 0, 1, append(oneFloat, oneFloat...))},
		{"trailing bytes", reqBody(byte(ReqUpsert), 1, 0, 0, 0, []byte{0xAA})},
		{"delete with a vector", reqBody(byte(ReqDelete), 1, 5, 0, 1, oneFloat)},
		{"upsert with a k", reqBody(byte(ReqUpsert), 1, 5, 3, 0, nil)},
		{"search with an id", reqBody(byte(ReqSearch), 1, 9, 0, 0, nil)},
	}
	for _, c := range reqCases {
		if _, err := DecodeClientRequest(env(c.body)); !errors.Is(err, ErrMalformedClientMessage) {
			t.Fatalf("request %q: got %v, want ErrMalformedClientMessage", c.name, err)
		}
	}

	respCases := []struct {
		name string
		body []byte
	}{
		{"short body", make([]byte, clientRespHeaderSize-1)},
		{"unknown status", respBody(1, 99, 0, 0, 0, nil)},
		{"count lying high", respBody(1, byte(StatusOK), 0, 0, 1<<28, oneNeighbor)},
		{"count lying low", respBody(1, byte(StatusOK), 0, 0, 1, append(oneNeighbor, oneNeighbor...))},
		{"trailing bytes", respBody(1, byte(StatusNotReady), 0, 0, 0, []byte{0xAA})},
		{"not-ready with an index", respBody(1, byte(StatusNotReady), 0, 5, 0, nil)},
		{"ok with a leader hint", respBody(1, byte(StatusOK), 7, 42, 0, nil)},
		{"ok both write and search", respBody(1, byte(StatusOK), 0, 42, 1, oneNeighbor)},
		{"not-leader with an index", respBody(1, byte(StatusNotLeader), 7, 5, 0, nil)},
	}
	for _, c := range respCases {
		if _, err := DecodeClientResponse(env(c.body)); !errors.Is(err, ErrMalformedClientMessage) {
			t.Fatalf("response %q: got %v, want ErrMalformedClientMessage", c.name, err)
		}
	}

	// A foreign envelope kind is rejected before the body is even read.
	foreign := cluster.Envelope{From: 1, To: 2, Kind: 99, Payload: reqBody(byte(ReqDelete), 1, 5, 0, 0, nil)}
	if _, err := DecodeClientRequest(foreign); !errors.Is(err, ErrWrongClientKind) {
		t.Fatalf("wrong-kind request: got %v, want ErrWrongClientKind", err)
	}
	if _, err := DecodeClientResponse(foreign); !errors.Is(err, ErrWrongClientKind) {
		t.Fatalf("wrong-kind response: got %v, want ErrWrongClientKind", err)
	}
}
