package naylamp

import (
	"sync"
	"testing"

	"naylamp/engine/cluster"
)

// This file pins the io-under-lock seam: a transport Send must never run while
// the caller holds the host's mutex. Under the TCP transport a Send toward a
// silently partitioned peer blocks in the socket write for the full socket
// timeout, so a Send made inside the critical section wedges the whole host:
// deliveries, ticks and client calls all queue on the same mutex behind one
// dead peer. The probe below observes exactly that predicate, with no
// partition and no extra machinery.
//
// The observation trick: every test here drives its cluster from one
// goroutine, and sync.Mutex is not reentrant, so mu.TryLock() on that
// goroutine fails if and only if the current call stack holds mu. Probing at
// the Send boundary therefore reports precisely "this frame was sent from
// inside the host's critical section", the one observable that separates a
// host doing network I/O under its lock from one that hands frames out first
// and sends after releasing it.

// lockProbeTransport decorates a real transport with the TryLock probe. The
// probed mutex is bound late, AFTER NewHost or NewRouterHost returns, because
// both constructors hold their mutex across bind; a probe armed at bind time
// would report the constructor, not a send path. While mu is nil the probe
// only counts traffic. Counters are plain integers because everything in
// these tests runs on the single driving goroutine.
type lockProbeTransport struct {
	inner cluster.Transport
	mu    *sync.Mutex // late-bound owner mutex; nil until the host exists

	sendsTotal   int64 // every Send observed, the non-vacuity witness
	underMuSends int64 // Sends made while the owner held its mutex
}

// Send probes the owner's mutex, then always forwards: the fabric sees the
// exact same traffic as an undecorated run, so seeded histories cannot shift
// under the probe.
func (p *lockProbeTransport) Send(to cluster.NodeID, data []byte) error {
	p.sendsTotal++
	if p.mu != nil {
		if p.mu.TryLock() {
			p.mu.Unlock()
		} else {
			p.underMuSends++
		}
	}
	return p.inner.Send(to, data)
}

// Close releases the wrapped endpoint.
func (p *lockProbeTransport) Close() error { return p.inner.Close() }

// TestHost_NeverSendsWhileHoldingItsLock is the seam pin for the Host half of
// the invariant. Three replicas run a plain healthy schedule over a SimNet:
// election, a couple of writes, then steady heartbeats. Every frame a Host
// hands its transport from inside the critical section is a violation; the
// count must be zero. No fault is injected, so a red result indicts the send
// path itself, not a schedule.
func TestHost_NeverSendsWhileHoldingItsLock(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	net := cluster.NewSimNet(93, cluster.DefaultSimConfig())
	defer net.Close()

	probes := map[cluster.NodeID]*lockProbeTransport{}
	hosts := map[cluster.NodeID]*Host{}
	defer func() {
		for _, h := range hosts {
			_ = h.Close()
		}
	}()
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+800), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		probe := &lockProbeTransport{}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			probe.inner = tr
			return probe
		})
		if err != nil {
			t.Fatalf("host %d: %v", id, err)
		}
		probe.mu = &host.mu // late binding, see the type comment
		probes[id] = probe
		hosts[id] = host
	}

	lead := driveHostsUntilLeader(t, net, hosts, ids, 400)
	if _, err := hosts[lead].Upsert(1, []float32{1, 0, 0}); err != nil {
		t.Fatalf("upsert 1: %v", err)
	}
	driveHosts(t, net, hosts, ids, 15)
	if _, err := hosts[lead].Upsert(2, []float32{0, 1, 0}); err != nil {
		t.Fatalf("upsert 2: %v", err)
	}
	driveHosts(t, net, hosts, ids, 100)

	var sends, violations int64
	for _, id := range ids {
		sends += probes[id].sendsTotal
		violations += probes[id].underMuSends
	}
	if sends == 0 {
		t.Fatalf("the probe saw no sends at all: the schedule produced no traffic, so the invariant was never exercised")
	}
	if violations != 0 {
		t.Fatalf("Host sent %d of %d frames while holding its mutex; the consensus host must never do network I/O under its lock", violations, sends)
	}
}

// TestRouterHost_NeverSendsWhileHoldingItsLock is the RouterHost half. The
// router is the client-facing gateway and serializes on its own mutex exactly
// as Host does, so the same io-under-lock seam exists in its send path. One
// probed RouterHost drives a healthy single-shard cluster through a full
// write: issue, redirect or ack in deliver, retransmit in Tick. Every one of
// those paths crosses the router's sendAll; the violation count must be zero.
func TestRouterHost_NeverSendsWhileHoldingItsLock(t *testing.T) {
	shard := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	net := cluster.NewSimNet(94, cluster.DefaultSimConfig())
	defer net.Close()

	hosts := map[cluster.NodeID]*Host{}
	var rh *RouterHost
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, h := range hosts {
			_ = h.Close()
		}
	}()

	for _, id := range shard {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+900), NodeOptions{})
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

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	probe := &lockProbeTransport{}
	rh, err = NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("router endpoint: %v", terr)
		}
		probe.inner = tr
		return probe
	})
	if err != nil {
		t.Fatalf("router host: %v", err)
	}
	probe.mu = &rh.mu // late binding, see the type comment

	// advance mirrors the SilentTarget harness: nodes, fabric, then the router
	// host on the fabric clock so its retransmit timer is live.
	advance := func() {
		tickHosts(t, hosts, shard)
		net.Tick()
		if terr := rh.Tick(net.Clock().Now()); terr != nil {
			t.Fatalf("router host tick: %v", terr)
		}
	}

	const electBudget = 600
	leader := cluster.None
	for i := 0; i < electBudget; i++ {
		advance()
		if leader = hostLeaderOf(hosts, shard); leader != cluster.None {
			break
		}
	}
	if leader == cluster.None {
		t.Fatalf("shard did not elect a leader within %d rounds", electBudget)
	}

	// One full client write through the router, driven to a terminal result so
	// the issue path, the deliver path and the tick path all had their chance
	// to send.
	opID, err := rh.Upsert(1, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("router host upsert: %v", err)
	}
	var res RouteResult
	done := false
	for i := 0; i < 300 && !done; i++ {
		advance()
		res, done = rh.Result(opID)
	}
	if !done || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("upsert did not complete OK: done=%v %+v", done, res)
	}

	if probe.sendsTotal == 0 {
		t.Fatalf("the probe saw no sends at all: the router issued no traffic, so the invariant was never exercised")
	}
	if probe.underMuSends != 0 {
		t.Fatalf("RouterHost sent %d of %d frames while holding its mutex; the router gateway must never do network I/O under its lock", probe.underMuSends, probe.sendsTotal)
	}
}
