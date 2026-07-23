package cluster

import "testing"

// TestSimNet_DropsByEdge_BlocksDirected pins the core semantics: a DropsByEdge
// block kills the directed link it names and only that direction, so the reverse
// keeps flowing, the same asymmetry Partition has. This is the fabric-level shape
// of muting a node's egress to a client while its inbound stays open.
func TestSimNet_DropsByEdge_BlocksDirected(t *testing.T) {
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

	fab.DropsByEdge(1, 2)
	if serr := ep1.Send(2, []byte("blocked")); serr != nil {
		t.Fatalf("send blocked: %v", serr)
	}
	if serr := ep2.Send(1, []byte("reverse")); serr != nil {
		t.Fatalf("send reverse: %v", serr)
	}
	fab.RunTicks(10)

	if len(got2) != 0 {
		t.Fatalf("frame crossed the dropped edge 1->2: %v", got2)
	}
	if len(got1) != 1 || got1[0] != "reverse" {
		t.Fatalf("2->1 should flow while only 1->2 is dropped, got %v", got1)
	}
	if s := fab.Stats(); s.DroppedByEdge != 1 {
		t.Fatalf("DroppedByEdge = %d, want 1", s.DroppedByEdge)
	}
}

// TestSimNet_DropsByEdge_CounterDistinct proves the two fault families never
// bleed into each other's counter: a Partition drop lands only in
// DroppedByPartition and a DropsByEdge drop lands only in DroppedByEdge, so a
// coverage gate can tell a client-edge mute apart from a peer partition.
func TestSimNet_DropsByEdge_CounterDistinct(t *testing.T) {
	fab := NewSimNet(2, DefaultSimConfig())
	defer fab.Close()

	mk := func(id NodeID) Transport {
		ep, err := fab.Endpoint(id, func(NodeID, []byte) {})
		if err != nil {
			t.Fatalf("endpoint %d: %v", id, err)
		}
		return ep
	}
	ep1 := mk(1)
	mk(2)
	ep3 := mk(3)
	mk(4)

	fab.Partition(1, 2)   // a peer-to-peer partition
	fab.DropsByEdge(3, 4) // a directed edge drop

	if err := ep1.Send(2, []byte("p")); err != nil {
		t.Fatalf("send over partition: %v", err)
	}
	if err := ep3.Send(4, []byte("e")); err != nil {
		t.Fatalf("send over dropped edge: %v", err)
	}
	fab.RunTicks(10)

	s := fab.Stats()
	if s.DroppedByPartition != 1 {
		t.Fatalf("DroppedByPartition = %d, want 1", s.DroppedByPartition)
	}
	if s.DroppedByEdge != 1 {
		t.Fatalf("DroppedByEdge = %d, want 1", s.DroppedByEdge)
	}
}

// TestSimNet_DropsByEdge_InFlightDiesAtDelivery pins parity with Partition on the
// timing: the block is enforced at delivery, so a frame already queued when the
// edge drops still dies instead of sneaking through.
func TestSimNet_DropsByEdge_InFlightDiesAtDelivery(t *testing.T) {
	fab := NewSimNet(3, DefaultSimConfig())
	defer fab.Close()

	var got []string
	if _, err := fab.Endpoint(2, func(_ NodeID, data []byte) { got = append(got, string(data)) }); err != nil {
		t.Fatalf("endpoint 2: %v", err)
	}
	ep1, err := fab.Endpoint(1, func(NodeID, []byte) {})
	if err != nil {
		t.Fatalf("endpoint 1: %v", err)
	}

	if serr := ep1.Send(2, []byte("inflight")); serr != nil {
		t.Fatalf("send inflight: %v", serr)
	}
	fab.DropsByEdge(1, 2) // dropped AFTER the frame is already in flight
	fab.RunTicks(10)

	if len(got) != 0 {
		t.Fatalf("in-flight frame crossed the dropped edge: %v", got)
	}
	if s := fab.Stats(); s.DroppedByEdge != 1 {
		t.Fatalf("DroppedByEdge = %d, want 1", s.DroppedByEdge)
	}
}

// TestSimNet_DropsByEdge_RestoreDelivers checks the reverse: after RestoreEdge a
// new send crosses again, and at-most-once holds because the frame dropped while
// the edge was down is gone for good, not resurrected.
func TestSimNet_DropsByEdge_RestoreDelivers(t *testing.T) {
	fab := NewSimNet(4, DefaultSimConfig())
	defer fab.Close()

	var got []string
	if _, err := fab.Endpoint(2, func(_ NodeID, data []byte) { got = append(got, string(data)) }); err != nil {
		t.Fatalf("endpoint 2: %v", err)
	}
	ep1, err := fab.Endpoint(1, func(NodeID, []byte) {})
	if err != nil {
		t.Fatalf("endpoint 1: %v", err)
	}

	fab.DropsByEdge(1, 2)
	if serr := ep1.Send(2, []byte("lost")); serr != nil {
		t.Fatalf("send lost: %v", serr)
	}
	fab.RunTicks(10)
	if len(got) != 0 {
		t.Fatalf("frame crossed the dropped edge: %v", got)
	}

	fab.RestoreEdge(1, 2)
	if serr := ep1.Send(2, []byte("after")); serr != nil {
		t.Fatalf("send after restore: %v", serr)
	}
	fab.RunTicks(10)
	if len(got) != 1 || got[0] != "after" {
		t.Fatalf("post-restore delivery failed (a dropped frame must not resurrect), got %v", got)
	}
	if s := fab.Stats(); s.DroppedByEdge != 1 {
		t.Fatalf("DroppedByEdge = %d, want 1", s.DroppedByEdge)
	}
}

// TestSimNet_DropsByEdge_PeerEdgesUntouched is the orthogonality anchor at the
// fabric level: dropping a leader's egress to a client (leader -> client) leaves
// every leader-to-peer link flowing, so the fault cannot pass for the loss of the
// quorum traffic CheckQuorum reads. Ids 1..3 stand in for a shard and id 90 for
// the client endpoint, the same router id the DST harness uses.
func TestSimNet_DropsByEdge_PeerEdgesUntouched(t *testing.T) {
	fab := NewSimNet(5, DefaultSimConfig())
	defer fab.Close()

	const leader NodeID = 1
	const client NodeID = 90
	peers := []NodeID{2, 3}

	got := map[NodeID][]string{}
	mk := func(id NodeID) Transport {
		ep, err := fab.Endpoint(id, func(_ NodeID, data []byte) { got[id] = append(got[id], string(data)) })
		if err != nil {
			t.Fatalf("endpoint %d: %v", id, err)
		}
		return ep
	}
	leaderEp := mk(leader)
	for _, p := range peers {
		mk(p)
	}
	mk(client)

	fab.DropsByEdge(leader, client)

	// The leader's heartbeats to its peers must still land...
	for _, p := range peers {
		if err := leaderEp.Send(p, []byte("hb")); err != nil {
			t.Fatalf("send heartbeat to %d: %v", p, err)
		}
	}
	// ...while its answer to the client is swallowed.
	if err := leaderEp.Send(client, []byte("ack")); err != nil {
		t.Fatalf("send client ack: %v", err)
	}
	fab.RunTicks(10)

	for _, p := range peers {
		if len(got[p]) != 1 || got[p][0] != "hb" {
			t.Fatalf("leader->peer %d heartbeat should flow, got %v", p, got[p])
		}
	}
	if len(got[client]) != 0 {
		t.Fatalf("leader->client ack should be dropped, got %v", got[client])
	}
	if s := fab.Stats(); s.DroppedByEdge != 1 {
		t.Fatalf("DroppedByEdge = %d, want 1", s.DroppedByEdge)
	}
}

// TestSimNet_DropsByEdge_PartitionTakesPrecedence pins the deterministic tie
// break for an edge blocked by BOTH primitives: Partition is checked first, so
// the drop counts once as DroppedByPartition and never as DroppedByEdge. Keeping
// Partition ahead means an edge already partitioned behaves exactly as it did
// before DropsByEdge existed.
func TestSimNet_DropsByEdge_PartitionTakesPrecedence(t *testing.T) {
	fab := NewSimNet(6, DefaultSimConfig())
	defer fab.Close()

	if _, err := fab.Endpoint(2, func(NodeID, []byte) {}); err != nil {
		t.Fatalf("endpoint 2: %v", err)
	}
	ep1, err := fab.Endpoint(1, func(NodeID, []byte) {})
	if err != nil {
		t.Fatalf("endpoint 1: %v", err)
	}

	fab.Partition(1, 2)
	fab.DropsByEdge(1, 2) // the same edge under both faults
	if serr := ep1.Send(2, []byte("x")); serr != nil {
		t.Fatalf("send: %v", serr)
	}
	fab.RunTicks(10)

	s := fab.Stats()
	if s.DroppedByPartition != 1 {
		t.Fatalf("DroppedByPartition = %d, want 1 (partition wins the tie)", s.DroppedByPartition)
	}
	if s.DroppedByEdge != 0 {
		t.Fatalf("DroppedByEdge = %d, want 0 (partition takes precedence)", s.DroppedByEdge)
	}
}
