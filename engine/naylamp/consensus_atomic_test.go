package naylamp

import (
	"errors"
	"sync"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// This file pins the atomicity of the consensus read: role, leader and term
// must come from ONE acquisition of the host's mutex, so the three always
// describe the same instant.
//
// The predicate that makes a torn read visible is an invariant of the core: a
// replica that reports the leader role always names ITSELF as the leader,
// because becomeLeader sets both together and nothing separates them. Sampling
// the fields one at a time can break that pairing without any bug in the core:
// read the role while this node still leads, let a higher term depose it
// between the two calls, then read the leader and get somebody else. The
// combination role=leader with a foreign leader never existed, yet a caller
// that took two locks can print it.
//
// The tests below run a real leadership churn on one goroutine while another
// samples, so the interleaving the invariant guards against is actually
// available to the scheduler. They are strongest under the race detector.

// TestHost_ConsensusIsOneAcquisition is the pin with teeth, and it is built to
// FAIL if the accessor is ever rewritten as separate reads. A natural election
// churn is not enough: the gap between two back-to-back acquisitions is a few
// nanoseconds, and a real transition almost never lands inside it, so a torn
// implementation survives hundreds of thousands of samples. This test removes
// the luck. A writer goroutine does nothing but take the mutex, swap the whole
// node the host reads from, and release, in the tightest loop the runtime
// allows, so the two states alternate faster than a sampler can straddle them.
//
// The two states are chosen to have no field in common: a freshly opened node
// is a follower of nobody at term zero, and the elected node is a leader of
// itself at a nonzero term. Every legitimate observation is therefore exactly
// one of those two triples, and ANY mixture proves the fields were read at
// different instants.
func TestHost_ConsensusIsOneAcquisition(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(44, cluster.DefaultSimConfig())
	defer net.Close()

	hosts := map[cluster.NodeID]*Host{}
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+2100), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		hid := id
		host, herr := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			return tr
		})
		if herr != nil {
			t.Fatalf("host %d: %v", id, herr)
		}
		hosts[id] = host
	}

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	if lead == cluster.None {
		t.Fatal("no leader emerged")
	}

	// The two states the writer alternates between, captured once so the
	// expectations below are facts about this run and not assumptions.
	elected := hosts[lead].node
	fresh, ferr := OpenNode(t.TempDir(), ids[0], cfg, 3, testRNG(2200), NodeOptions{})
	if ferr != nil {
		t.Fatalf("open fresh: %v", ferr)
	}
	electedState, freshState := elected.Consensus(), fresh.Consensus()
	if electedState.Role != raft.RoleLeader || electedState.Leader != lead || electedState.Term == 0 {
		t.Fatalf("elected node is not a leader of itself at a nonzero term: %+v", electedState)
	}
	if freshState.Role != raft.RoleFollower || freshState.Leader != cluster.None || freshState.Term != 0 {
		t.Fatalf("fresh node is not a follower of nobody at term zero: %+v", freshState)
	}

	// The host under test is the elected leader's own host, and the writer swaps
	// the node pointer it reads from. Nothing ticks it for the rest of the run
	// and SimNet delivers only inside net.Tick(), which this loop never calls,
	// so the swaps are the ONLY thing that changes what a sample can see. That
	// is what makes every mixed observation attributable to the read itself.
	victim := hosts[lead]

	const swaps = 200000
	var wg sync.WaitGroup
	done := make(chan struct{})
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(done)
		for i := 0; i < swaps; i++ {
			victim.mu.Lock()
			if i%2 == 0 {
				victim.node = fresh
			} else {
				victim.node = elected
			}
			victim.mu.Unlock()
		}
		// Leave the host holding the node it started with, so the deferred
		// Close releases what this test opened and nothing else.
		victim.mu.Lock()
		victim.node = elected
		victim.mu.Unlock()
	}()

	samples, sawElected, sawFresh := 0, 0, 0
	for {
		select {
		case <-done:
			wg.Wait()
			if sawElected == 0 || sawFresh == 0 {
				t.Fatalf("vacuous run: the sampler saw elected=%d fresh=%d; it must observe both states for a mixture to have been possible", sawElected, sawFresh)
			}
			t.Logf("single-acquisition pin: samples=%d elected=%d fresh=%d", samples, sawElected, sawFresh)
			_ = fresh.Close()
			return
		default:
		}
		st := victim.Consensus()
		samples++
		switch st {
		case electedState:
			sawElected++
		case freshState:
			sawFresh++
		default:
			t.Fatalf("torn read: observed role=%v leader=%v term=%d, which is neither the elected state %+v nor the fresh state %+v; the three fields came from different acquisitions",
				st.Role, st.Leader, st.Term, electedState, freshState)
		}
	}
}

// TestHost_ConsensusReadIsAtomic samples the atomic accessor while a separate
// goroutine drives real elections, and fails if any sample is internally
// impossible or if the term ever moves backwards. This is the realistic-traffic
// companion to the pin above: it cannot force the interleaving, so it is
// coverage under a genuine schedule rather than the thing that catches a
// regression.
func TestHost_ConsensusReadIsAtomic(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(41, cluster.DefaultSimConfig())
	defer net.Close()

	hosts := map[cluster.NodeID]*Host{}
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1700), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		hid := id
		host, herr := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			return tr
		})
		if herr != nil {
			t.Fatalf("host %d: %v", id, herr)
		}
		hosts[id] = host
	}

	// The driver churns leadership as hard as the cluster allows: it ticks every
	// host so elections run, isolates whoever holds office the moment one
	// appears, and heals shortly after so the next election can resolve. Density
	// is the whole point. A tear is only OBSERVABLE when a transition lands
	// between two of the sampler's reads, so a run with a handful of transitions
	// proves nothing however many times it samples.
	const rounds = 20000
	var wg sync.WaitGroup
	done := make(chan struct{})
	transitions := 0
	wg.Add(1)
	go func() {
		defer wg.Done()
		defer close(done)
		isolated := cluster.None
		for i := 0; i < rounds; i++ {
			for _, id := range ids {
				_ = hosts[id].Tick()
			}
			net.Tick()
			if isolated != cluster.None {
				net.HealAll()
				isolated = cluster.None
				continue
			}
			for _, id := range ids {
				if hosts[id].Role() != raft.RoleLeader {
					continue
				}
				for _, other := range ids {
					if other != id {
						net.Partition(id, other)
						net.Partition(other, id)
					}
				}
				isolated = id
				transitions++
				break
			}
		}
	}()

	// The sampler reads until the driver finishes. Terms are monotonic per
	// replica, so a term going backwards is a torn read too.
	samples, leaderSamples := 0, 0
	highest := map[cluster.NodeID]uint64{}
	for {
		select {
		case <-done:
			wg.Wait()
			// Non-vacuity: a run that never sampled a leader would pass without
			// having tested the predicate that matters.
			if samples == 0 || leaderSamples == 0 {
				t.Fatalf("vacuous run: %d samples, %d of them leaders; the churn never produced an observable leader", samples, leaderSamples)
			}
			// The transition count is the coverage floor that makes the sample
			// count mean anything: without deposings there is no window for a
			// torn read to fall into, and a green run would say nothing.
			if transitions < 50 {
				t.Fatalf("insufficient coverage: only %d leader deposings in %d rounds; a torn read has almost no window to appear in", transitions, rounds)
			}
			t.Logf("consensus atomicity: samples=%d leaderSamples=%d deposings=%d", samples, leaderSamples, transitions)
			return
		default:
		}
		for _, id := range ids {
			st := hosts[id].Consensus()
			samples++
			if st.Role == raft.RoleLeader {
				leaderSamples++
				if st.Leader != id {
					t.Fatalf("torn read on node %d: role=leader but leader=%v term=%d; a leader always names itself, so the fields came from different instants", id, st.Leader, st.Term)
				}
			}
			if st.Term < highest[id] {
				t.Fatalf("torn read on node %d: term went backwards, %d after %d", id, st.Term, highest[id])
			}
			highest[id] = st.Term
		}
	}
}

// TestHost_ConsensusMatchesTheSeparateAccessors fixes that the atomic accessor
// reports the same values the individual accessors do on a quiescent host, so
// the new read is a consistent view of the existing ones and not a second,
// divergent source of truth.
func TestHost_ConsensusMatchesTheSeparateAccessors(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(42, cluster.DefaultSimConfig())
	defer net.Close()

	hosts := map[cluster.NodeID]*Host{}
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1800), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		hid := id
		host, herr := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			return tr
		})
		if herr != nil {
			t.Fatalf("host %d: %v", id, herr)
		}
		hosts[id] = host
	}

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	if lead == cluster.None {
		t.Fatal("no leader emerged")
	}

	for _, id := range ids {
		h := hosts[id]
		st := h.Consensus()
		if got := h.Role(); got != st.Role {
			t.Fatalf("node %d: Consensus reports role %v, Role reports %v", id, st.Role, got)
		}
		if got := h.Leader(); got != st.Leader {
			t.Fatalf("node %d: Consensus reports leader %v, Leader reports %v", id, st.Leader, got)
		}
	}

	// The elected leader must be at a nonzero term, which is what makes the new
	// field worth logging: a term of zero would mean no election ever resolved.
	if st := hosts[lead].Consensus(); st.Term == 0 {
		t.Fatalf("leader %d reports term 0 after an election", lead)
	}
}

// TestHost_ConsensusOnPoisonedHostMatchesTheSeparateAccessors fixes the poisoned
// path: a Host that has latched an error reports a follower of nobody at term
// zero, the same standing its individual accessors report, so a caller reading
// the atomic value sees no different story on a dead host.
func TestHost_ConsensusOnPoisonedHostMatchesTheSeparateAccessors(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(43, cluster.DefaultSimConfig())
	defer net.Close()

	node, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(1900), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	host, herr := NewHost(node, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(1, h)
		if terr != nil {
			t.Fatalf("endpoint: %v", terr)
		}
		return tr
	})
	if herr != nil {
		t.Fatalf("host: %v", herr)
	}
	defer func() { _ = host.Close() }()

	// Latch the poison directly: the point is the accessor's behaviour once err
	// is set, not the route that sets it.
	host.mu.Lock()
	host.err = errors.New("poisoned for this test")
	host.mu.Unlock()

	st := host.Consensus()
	if st.Role != raft.RoleFollower || st.Leader != cluster.None || st.Term != 0 {
		t.Fatalf("poisoned host reports role=%v leader=%v term=%d, want follower of none at term 0", st.Role, st.Leader, st.Term)
	}
	if got := host.Role(); got != st.Role {
		t.Fatalf("poisoned host: Consensus reports role %v, Role reports %v", st.Role, got)
	}
	if got := host.Leader(); got != st.Leader {
		t.Fatalf("poisoned host: Consensus reports leader %v, Leader reports %v", st.Leader, got)
	}
}
