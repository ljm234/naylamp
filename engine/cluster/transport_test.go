package cluster

import (
	"errors"
	"fmt"
	"testing"
	"time"
)

// runSeededHistory drives a scripted workload over a faulty fabric and
// returns the exact delivery history (tick, from, to, payload). Two runs with
// the same seed must produce identical histories.
func runSeededHistory(t *testing.T, seed uint64) []string {
	t.Helper()
	cfg := SimConfig{MinLatency: 1, MaxLatency: 7, DropProb: 0.2, DupProb: 0.2}
	fab := NewSimNet(seed, cfg)
	defer fab.Close()

	var history []string
	eps := make(map[NodeID]Transport)
	for id := NodeID(1); id <= 3; id++ {
		self := id
		ep, err := fab.Endpoint(self, func(from NodeID, data []byte) {
			history = append(history, fmt.Sprintf("t%d %d->%d %x", fab.Clock().Now(), from, self, data))
		})
		if err != nil {
			t.Fatalf("endpoint %d: %v", self, err)
		}
		eps[self] = ep
	}

	payload := byte(0)
	for round := 0; round < 10; round++ {
		for i := 0; i < 6; i++ {
			from := NodeID(i%3) + 1
			to := NodeID((i+1)%3) + 1
			if err := eps[from].Send(to, []byte{payload}); err != nil {
				t.Fatalf("send: %v", err)
			}
			payload++
		}
		fab.RunTicks(3)
	}
	fab.RunTicks(20) // drain everything still in flight
	return history
}

// TestSimNet_DeterministicSchedule is the gate of 3.1: same seed, same exact
// delivery history; different seed, different history (proving the seeded
// generator actually drives the schedule).
func TestSimNet_DeterministicSchedule(t *testing.T) {
	h1 := runSeededHistory(t, 42)
	h2 := runSeededHistory(t, 42)
	if len(h1) == 0 {
		t.Fatalf("no deliveries at all; workload or fabric broken")
	}
	if len(h1) != len(h2) {
		t.Fatalf("history lengths differ: %d vs %d", len(h1), len(h2))
	}
	for i := range h1 {
		if h1[i] != h2[i] {
			t.Fatalf("histories diverge at %d: %q vs %q", i, h1[i], h2[i])
		}
	}
	h3 := runSeededHistory(t, 43)
	same := len(h3) == len(h1)
	if same {
		for i := range h1 {
			if h1[i] != h3[i] {
				same = false
				break
			}
		}
	}
	if same {
		t.Fatalf("different seeds produced identical histories; rng is not wired into the schedule")
	}
}

// TestSimNet_PartitionAndHeal checks the delivery-time semantics: nothing
// crosses a cut link (not even messages already in flight), the primitive is
// asymmetric, and heal restores new deliveries without resurrecting dropped
// ones (at-most-once).
func TestSimNet_PartitionAndHeal(t *testing.T) {
	fab := NewSimNet(1, DefaultSimConfig())
	defer fab.Close()

	var got1, got2 []string
	ep1, err := fab.Endpoint(1, func(_ NodeID, data []byte) { got1 = append(got1, string(data)) })
	if err != nil {
		t.Fatalf("endpoint 1: %v", err)
	}
	ep2, err := fab.Endpoint(2, func(_ NodeID, data []byte) { got2 = append(got2, string(data)) })
	if err != nil {
		t.Fatalf("endpoint 2: %v", err)
	}

	// A message already in flight must also be blocked by a later cut.
	if err := ep1.Send(2, []byte("inflight")); err != nil {
		t.Fatalf("send inflight: %v", err)
	}
	fab.Partition(1, 2)
	fab.RunTicks(10)
	if len(got2) != 0 {
		t.Fatalf("in-flight message crossed the partition: %v", got2)
	}

	// Asymmetric: 1->2 is cut, 2->1 must still flow.
	if err := ep1.Send(2, []byte("blocked")); err != nil {
		t.Fatalf("send blocked: %v", err)
	}
	if err := ep2.Send(1, []byte("reverse")); err != nil {
		t.Fatalf("send reverse: %v", err)
	}
	fab.RunTicks(10)
	if len(got2) != 0 {
		t.Fatalf("message crossed 1->2 during partition: %v", got2)
	}
	if len(got1) != 1 || got1[0] != "reverse" {
		t.Fatalf("2->1 should flow during asymmetric partition, got %v", got1)
	}
	if s := fab.Stats(); s.DroppedByPartition != 2 {
		t.Fatalf("expected 2 partition drops (inflight+blocked), got %d", s.DroppedByPartition)
	}

	// Heal: new sends arrive; the dropped ones are gone forever.
	fab.Heal(1, 2)
	if err := ep1.Send(2, []byte("after")); err != nil {
		t.Fatalf("send after heal: %v", err)
	}
	fab.RunTicks(10)
	if len(got2) != 1 || got2[0] != "after" {
		t.Fatalf("post-heal delivery failed, got %v", got2)
	}
}

// TestMessage_CodecRoundTrip covers the envelope codec: exact round-trip,
// empty payloads, corruption detected by the CRC framing, trailing bytes
// rejected, reserved ids rejected, and the payload bound enforced.
func TestMessage_CodecRoundTrip(t *testing.T) {
	env := Envelope{From: 1, To: 2, Kind: 7, Payload: []byte("naylamp cluster wire")}
	raw, err := EncodeMessage(env)
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	dec, err := DecodeMessage(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if dec.From != env.From || dec.To != env.To || dec.Kind != env.Kind || string(dec.Payload) != string(env.Payload) {
		t.Fatalf("round-trip mismatch: %+v vs %+v", dec, env)
	}

	empty, err := EncodeMessage(Envelope{From: 3, To: 4, Kind: 1})
	if err != nil {
		t.Fatalf("encode empty: %v", err)
	}
	if dec, derr := DecodeMessage(empty); derr != nil || len(dec.Payload) != 0 {
		t.Fatalf("empty payload round-trip: %v %v", dec, derr)
	}

	corrupted := append([]byte(nil), raw...)
	corrupted[len(corrupted)/2] ^= 0xFF
	if _, derr := DecodeMessage(corrupted); derr == nil {
		t.Fatalf("corrupted frame decoded without error")
	}

	trailing := append(append([]byte(nil), raw...), 0xAA)
	if _, derr := DecodeMessage(trailing); derr == nil {
		t.Fatalf("trailing bytes accepted")
	}

	if _, eerr := EncodeMessage(Envelope{From: None, To: 2}); !errors.Is(eerr, ErrInvalidNode) {
		t.Fatalf("zero From accepted: %v", eerr)
	}

	big := make([]byte, maxMessagePayload+1)
	if _, eerr := EncodeMessage(Envelope{From: 1, To: 2, Payload: big}); !errors.Is(eerr, ErrPayloadTooLarge) {
		t.Fatalf("oversize payload accepted: %v", eerr)
	}
}

type recvMsg struct {
	from NodeID
	data []byte
}

// awaitRecv waits for one delivery. With a pump (SimNet) it advances ticks;
// without one (TCP) it blocks on the channel with a timeout.
func awaitRecv(t *testing.T, name string, ch chan recvMsg, pump func()) recvMsg {
	t.Helper()
	if pump == nil {
		select {
		case m := <-ch:
			return m
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: timeout waiting for delivery", name)
		}
	}
	for i := 0; i < 200; i++ {
		select {
		case m := <-ch:
			return m
		default:
			pump()
		}
	}
	t.Fatalf("%s: no delivery after 200 ticks", name)
	return recvMsg{}
}

// runTransportContract is the shared suite of 3.1.8: whatever holds here must
// hold on BOTH transports, so Raft can be developed on SimNet and moved to
// TCP without semantic surprises.
func runTransportContract(t *testing.T, name string, ep1, ep2 Transport, ch1, ch2 chan recvMsg, pump func()) {
	t.Helper()

	// Delivery with correct attribution, and the sender may reuse its buffer.
	buf := []byte("first")
	if err := ep1.Send(2, buf); err != nil {
		t.Fatalf("%s: send: %v", name, err)
	}
	buf[0] = 'X'
	m := awaitRecv(t, name, ch2, pump)
	if m.from != 1 || string(m.data) != "first" {
		t.Fatalf("%s: got from=%d data=%q", name, m.from, m.data)
	}

	// Reverse direction.
	if err := ep2.Send(1, []byte("second")); err != nil {
		t.Fatalf("%s: reverse send: %v", name, err)
	}
	m = awaitRecv(t, name, ch1, pump)
	if m.from != 2 || string(m.data) != "second" {
		t.Fatalf("%s: reverse got from=%d data=%q", name, m.from, m.data)
	}

	// Several messages all arrive on a fault-free link; order is NOT part of
	// the contract, so assert the set.
	for i := 0; i < 5; i++ {
		if err := ep1.Send(2, []byte{byte(i)}); err != nil {
			t.Fatalf("%s: burst send %d: %v", name, i, err)
		}
	}
	seen := make(map[byte]bool)
	for i := 0; i < 5; i++ {
		m = awaitRecv(t, name, ch2, pump)
		seen[m.data[0]] = true
	}
	if len(seen) != 5 {
		t.Fatalf("%s: burst delivered %d distinct of 5", name, len(seen))
	}

	// A closed endpoint refuses to send.
	if err := ep1.Close(); err != nil {
		t.Fatalf("%s: close: %v", name, err)
	}
	if err := ep1.Send(2, []byte("late")); err == nil {
		t.Fatalf("%s: send after close must error", name)
	}
}

// TestTransport_Contract runs the shared suite against SimNet and TCP.
func TestTransport_Contract(t *testing.T) {
	t.Run("SimNet", func(t *testing.T) {
		fab := NewSimNet(9, DefaultSimConfig())
		defer fab.Close()
		ch1 := make(chan recvMsg, 32)
		ch2 := make(chan recvMsg, 32)
		ep1, err := fab.Endpoint(1, func(f NodeID, d []byte) { ch1 <- recvMsg{f, append([]byte(nil), d...)} })
		if err != nil {
			t.Fatalf("endpoint 1: %v", err)
		}
		ep2, err := fab.Endpoint(2, func(f NodeID, d []byte) { ch2 <- recvMsg{f, append([]byte(nil), d...)} })
		if err != nil {
			t.Fatalf("endpoint 2: %v", err)
		}
		runTransportContract(t, "simnet", ep1, ep2, ch1, ch2, fab.Tick)
	})

	t.Run("TCP", func(t *testing.T) {
		ch1 := make(chan recvMsg, 32)
		ch2 := make(chan recvMsg, 32)
		t1, err := NewTCPTransport(1, "127.0.0.1:0", func(f NodeID, d []byte) { ch1 <- recvMsg{f, append([]byte(nil), d...)} })
		if err != nil {
			t.Fatalf("tcp 1: %v", err)
		}
		defer func() { _ = t1.Close() }()
		t2, err := NewTCPTransport(2, "127.0.0.1:0", func(f NodeID, d []byte) { ch2 <- recvMsg{f, append([]byte(nil), d...)} })
		if err != nil {
			t.Fatalf("tcp 2: %v", err)
		}
		defer func() { _ = t2.Close() }()
		t1.AddPeer(2, t2.Addr())
		t2.AddPeer(1, t1.Addr())
		runTransportContract(t, "tcp", t1, t2, ch1, ch2, nil)
	})
}
