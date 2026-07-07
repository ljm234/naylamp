package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// sendVia sends every frame through a transport, routing by the To in each
// frame's own envelope. A send loss would be normal on this fabric, but the
// config here drops nothing, so a decode failure is the only fault worth
// stopping for.
func sendVia(t *testing.T, tr cluster.Transport, frames [][]byte) {
	t.Helper()
	for _, frame := range frames {
		env, err := cluster.DecodeMessage(frame)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		_ = tr.Send(env.To, frame)
	}
}

func TestRouter_LeaderFailoverMidQuery(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	// A lossless, duplication-free fabric with a fixed one-tick latency, seeded.
	// Client traffic has no retransmission of its own yet; the timeouts arrive
	// in a later piece with the fabric's clock. This test isolates the failover
	// property, and the client path's tolerance to loss will be exercised once
	// the mechanism that pays for it exists.
	net := cluster.NewSimNet(314, cluster.SimConfig{MinLatency: 1, MaxLatency: 1})
	defer net.Close()

	hosts := newHostCluster(t, net, cfg, ids, 3000)
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	vecs := map[uint64][]float32{1: {1, 0, 0}, 2: {0, 1, 0}, 3: {0, 0, 1}}
	for id := uint64(1); id <= 3; id++ {
		if _, err := hosts[lead].Upsert(id, vecs[id]); err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		driveHosts(t, net, hosts, ids, 15)
	}
	if !driveHostsUntilConverged(t, net, hosts, ids, 400) {
		t.Fatalf("cluster did not converge before the query")
	}

	// One shard whose first target is the current leader, so the search's first
	// attempt lands on it directly.
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: leaderAtIndex(cfg.Nodes, lead, 0)}}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// The router joins the fabric as one more endpoint; under SimNet a single
	// goroutine runs everything, so the order is deterministic. Its handler
	// feeds each inbound frame to the router and dispatches whatever the router
	// re-emits by the To in the envelope.
	var routerTr cluster.Transport
	routerTr, err = net.Endpoint(routerID, func(_ cluster.NodeID, data []byte) {
		out, herr := router.HandleMessage(data)
		if herr != nil {
			t.Fatalf("router handle: %v", herr)
		}
		sendVia(t, routerTr, out)
	})
	if err != nil {
		t.Fatalf("router endpoint: %v", err)
	}

	// Send the search, then drive until the leader has parked it with its
	// ReadIndex round in flight. Reading the node's internal state directly is
	// valid in this same package and free of data races, because a single
	// goroutine runs everything under SimNet.
	op, frames, err := router.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	sendVia(t, routerTr, frames)
	parked := false
	for i := 0; i < 100; i++ {
		tickHosts(t, hosts, ids)
		net.Tick()
		if len(hosts[lead].node.pendingSearches) == 1 {
			parked = true
			break
		}
	}
	if !parked {
		t.Fatalf("leader never parked the search with its round in flight")
	}

	// Before any further delivery, cut the leader off both followers in both
	// directions: the in-flight round drops by partition and the search stays
	// parked mid query.
	for _, id := range ids {
		if id != lead {
			net.Partition(lead, id)
			net.Partition(id, lead)
		}
	}

	survivors := make([]cluster.NodeID, 0, 2)
	for _, id := range ids {
		if id != lead {
			survivors = append(survivors, id)
		}
	}

	// The surviving majority elects a new leader. No result may exist before the
	// heal: the old leader cannot confirm its round and no one else holds the
	// search.
	newLead := cluster.None
	for i := 0; i < 600; i++ {
		tickHosts(t, hosts, ids)
		net.Tick()
		if _, ok := router.Result(op); ok {
			t.Fatalf("search result delivered before the heal")
		}
		if l := hostLeaderOf(hosts, survivors); l != cluster.None {
			newLead = l
			break
		}
	}
	if newLead == cluster.None {
		t.Fatalf("no survivor took leadership")
	}

	// Heal. The new leader deposes the old one, whose deposition flush answers
	// the parked search NotLeader; the router obeys the hint, or probes the next
	// member, and lands on the new leader, whose round confirms with the healthy
	// majority.
	net.HealAll()
	var res RouteResult
	done := false
	for i := 0; i < 600; i++ {
		tickHosts(t, hosts, ids)
		net.Tick()
		if r, ok := router.Result(op); ok {
			res = r
			done = true
			break
		}
	}
	if !done {
		t.Fatalf("search never completed after the heal")
	}

	if res.Status != StatusOK || res.Exhausted || res.Index != 0 {
		t.Fatalf("search did not complete OK: %+v", res)
	}
	if len(res.Neighbors) != 1 || res.Neighbors[0].ID != 1 {
		t.Fatalf("search returned the wrong nearest: %+v", res.Neighbors)
	}
	// The failover costs exactly one retry when the flush travels with a hint
	// (deposed by the new leader's heartbeat) and at most two when the
	// deposition arrives first by a higher-term response with no hint; outside
	// that range there is thrash or an unforeseen path.
	if router.reqSeq < 2 || router.reqSeq > 3 {
		t.Fatalf("failover cost %d attempts, want 2 or 3", router.reqSeq)
	}
	if hosts[lead].Role() != raft.RoleFollower {
		t.Fatalf("old leader did not step down: role=%v", hosts[lead].Role())
	}
	if !driveHostsUntilConverged(t, net, hosts, ids, 400) {
		t.Fatalf("cluster did not reconverge after the failover")
	}
	for _, id := range ids {
		if herr := hosts[id].Err(); herr != nil {
			t.Fatalf("host %d poisoned: %v", id, herr)
		}
	}
}
