package naylamp

import (
	"errors"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// newHostCluster opens n nodes over a shared SimNet and wraps each in a Host,
// using the bind-factory to attach every Host to its endpoint at construction.
func newHostCluster(t *testing.T, net *cluster.SimNet, cfg cluster.Config, ids []cluster.NodeID, rngBase uint64) map[cluster.NodeID]*Host {
	t.Helper()
	hosts := map[cluster.NodeID]*Host{}
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+rngBase), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			return tr
		})
		if err != nil {
			t.Fatalf("host %d: %v", id, err)
		}
		hosts[id] = host
	}
	return hosts
}

// tickHosts ticks every host once in id order, failing on any poison.
func tickHosts(t *testing.T, hosts map[cluster.NodeID]*Host, ids []cluster.NodeID) {
	t.Helper()
	for _, id := range ids {
		if h, ok := hosts[id]; ok {
			if err := h.Tick(); err != nil {
				t.Fatalf("host %d tick: %v", id, err)
			}
		}
	}
}

// driveHosts advances the cluster: each round ticks every host once (node
// time), then ticks the fabric once (deliveries land here). Hosts in id order,
// then the fabric: one deterministic schedule.
func driveHosts(t *testing.T, net *cluster.SimNet, hosts map[cluster.NodeID]*Host, ids []cluster.NodeID, rounds int) {
	t.Helper()
	for i := 0; i < rounds; i++ {
		tickHosts(t, hosts, ids)
		net.Tick()
	}
}

// hostLeaderOf returns the id of a host that currently believes it leads.
func hostLeaderOf(hosts map[cluster.NodeID]*Host, ids []cluster.NodeID) cluster.NodeID {
	for _, id := range ids {
		if h, ok := hosts[id]; ok && h.Role() == raft.RoleLeader {
			return id
		}
	}
	return cluster.None
}

// driveHostsUntilLeader drives until a host takes office.
func driveHostsUntilLeader(t *testing.T, net *cluster.SimNet, hosts map[cluster.NodeID]*Host, ids []cluster.NodeID, budget int) cluster.NodeID {
	t.Helper()
	for i := 0; i < budget; i++ {
		if lead := hostLeaderOf(hosts, ids); lead != cluster.None {
			return lead
		}
		tickHosts(t, hosts, ids)
		net.Tick()
	}
	if lead := hostLeaderOf(hosts, ids); lead != cluster.None {
		return lead
	}
	t.Fatalf("no host leader after %d rounds", budget)
	return cluster.None
}

// hostsConverged reports whether every host shares the same last log index and
// committed-data hash.
func hostsConverged(hosts map[cluster.NodeID]*Host, ids []cluster.NodeID) bool {
	var li uint64
	var hh [32]byte
	have := false
	for _, id := range ids {
		h, ok := hosts[id]
		if !ok {
			continue
		}
		if !have {
			li, hh, have = h.LastIndex(), h.StateHash(), true
			continue
		}
		if h.LastIndex() != li || h.StateHash() != hh {
			return false
		}
	}
	return have
}

// driveHostsUntilConverged drives until every host converges or the budget is
// spent.
func driveHostsUntilConverged(t *testing.T, net *cluster.SimNet, hosts map[cluster.NodeID]*Host, ids []cluster.NodeID, budget int) bool {
	t.Helper()
	for i := 0; i < budget; i++ {
		tickHosts(t, hosts, ids)
		net.Tick()
		if hostsConverged(hosts, ids) {
			return true
		}
	}
	return hostsConverged(hosts, ids)
}

func TestHost_ThreeReplicasConvergeOverSimNet(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(90, cluster.DefaultSimConfig())
	defer net.Close()
	hosts := newHostCluster(t, net, cfg, ids, 600)
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	vecs := map[uint64][]float32{
		1: {1, 0, 0}, 2: {0, 1, 0}, 3: {0, 0, 1}, 4: {1, 1, 0}, 5: {0, 1, 1},
	}
	for id := uint64(1); id <= 5; id++ {
		if _, err := hosts[lead].Upsert(id, vecs[id]); err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		driveHosts(t, net, hosts, ids, 15)
	}
	if !driveHostsUntilConverged(t, net, hosts, ids, 400) {
		t.Fatalf("hosts did not converge over the fabric")
	}

	// A follower answers a search from its own replicated copy.
	for _, id := range ids {
		if id == lead {
			continue
		}
		res, err := hosts[id].Search([]float32{1, 0, 0}, 1)
		if err != nil {
			t.Fatalf("follower %d search: %v", id, err)
		}
		if len(res) != 1 || res[0].ID != 1 {
			t.Fatalf("follower %d wrong nearest: %+v", id, res)
		}
		break
	}
	for _, id := range ids {
		if err := hosts[id].Err(); err != nil {
			t.Fatalf("host %d poisoned: %v", id, err)
		}
	}
}

func TestHost_PartitionHealLeaderHolds(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(91, cluster.DefaultSimConfig())
	defer net.Close()
	hosts := newHostCluster(t, net, cfg, ids, 700)
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	if _, err := hosts[lead].Upsert(1, []float32{1, 0, 0}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if !driveHostsUntilConverged(t, net, hosts, ids, 400) {
		t.Fatalf("cluster did not converge before the partition")
	}

	// Isolate a follower in both directions.
	var iso cluster.NodeID
	for _, id := range ids {
		if id != lead {
			iso = id
			break
		}
	}
	for _, id := range ids {
		if id != iso {
			net.Partition(iso, id)
			net.Partition(id, iso)
		}
	}
	// Several election timeouts pass. Pre-vote keeps the isolated node from
	// inflating its term, so the leader keeps its majority and its office.
	driveHosts(t, net, hosts, ids, 200)
	if hosts[lead].Role() != raft.RoleLeader {
		t.Fatalf("leader lost office while a follower was isolated")
	}

	// Heal and let the cluster settle.
	net.HealAll()
	driveHosts(t, net, hosts, ids, 200)
	if hosts[lead].Role() != raft.RoleLeader {
		t.Fatalf("leader disrupted after heal")
	}
	if hosts[iso].Role() != raft.RoleFollower {
		t.Fatalf("rejoiner is not a follower: role=%v", hosts[iso].Role())
	}
	if !driveHostsUntilConverged(t, net, hosts, ids, 400) {
		t.Fatalf("cluster did not reconverge after heal")
	}
}

func TestHost_NodeErrorPoisonsLoudly(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(92, cluster.DefaultSimConfig())
	defer net.Close()
	node, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(92), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	var captured cluster.Handler
	host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
		captured = h
		tr, terr := net.Endpoint(1, h)
		if terr != nil {
			t.Fatalf("endpoint: %v", terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("host: %v", err)
	}
	defer func() { _ = host.Close() }()

	// Caller mistakes are rejected before any proposal and never poison: the
	// state machine is untouched, so the host stays healthy and usable.
	if _, uerr := host.Upsert(1, []float32{1, 0}); !errors.Is(uerr, ErrInvalidArgument) {
		t.Fatalf("wrong-dim upsert error = %v, want ErrInvalidArgument", uerr)
	}
	if host.Err() != nil {
		t.Fatalf("invalid upsert poisoned the host: %v", host.Err())
	}
	if _, serr := host.Search([]float32{1, 0, 0}, 0); !errors.Is(serr, ErrInvalidArgument) {
		t.Fatalf("k=0 search error = %v, want ErrInvalidArgument", serr)
	}
	if host.Err() != nil {
		t.Fatalf("invalid search poisoned the host: %v", host.Err())
	}
	if terr := host.Tick(); terr != nil {
		t.Fatalf("host not operational after caller mistakes: %v", terr)
	}

	// A garbage frame the Node cannot decode is a fatal fault: it poisons.
	captured(2, []byte("this is not a framed cluster message"))

	poisoned := host.Err()
	if poisoned == nil {
		t.Fatalf("garbage frame did not poison the host")
	}
	// Every later call returns the SAME sticky error without touching the Node.
	if _, uerr := host.Upsert(1, []float32{1, 0, 0}); uerr != poisoned {
		t.Fatalf("poisoned Upsert returned %v, want the sticky %v", uerr, poisoned)
	}
	if terr := host.Tick(); terr != poisoned {
		t.Fatalf("poisoned Tick returned %v, want the sticky %v", terr, poisoned)
	}

	// A frame arriving after Close is dropped without touching the released
	// node: no panic, and the original poison is not replaced.
	if cerr := host.Close(); cerr != nil {
		t.Fatalf("close: %v", cerr)
	}
	captured(2, []byte("late frame after close"))
	if host.Err() != poisoned {
		t.Fatalf("close replaced the sticky poison: %v", host.Err())
	}
}
