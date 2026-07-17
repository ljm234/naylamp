package naylamp

import (
	"sync"
	"testing"

	"naylamp/engine/cluster"
)

// This file is the system-level half of the io-under-lock net: it reproduces,
// inside the deterministic simulation, the symptom the real TCP gate exposed.
// Under a partition the leader makes a blocking Send toward the cut peer while
// holding its mutex, which wedges the whole node; the client then never hears
// back and dies on its deadline, even though the cluster still holds a healthy
// write quorum. The seam itself is pinned by lock_probe_test.go; the tests
// here prove the client-visible consequence, once for a write and once for a
// linearizable search.
//
// The model: the fabric cannot see the host's mutex, so the trigger lives in a
// test-owned transport decorator. When a Send is issued while the owner holds
// its mutex AND the destination edge is cut, the decorator freezes the sender
// on the fabric (block 2 mechanics): its deliveries defer and the driver skips
// its tick, exactly what a thread stuck in a 30 second socket write looks like
// from the outside. A fixed host sends outside its lock, the TryLock probe
// succeeds, the freeze never arms, and the same schedule completes the write.
//
// Honesty notes. The stall constant deliberately OVERESTIMATES the real
// outage: a real blocked write returns within the 30 second socket timeout and
// then recurs per redial, while this freeze simply outlives the client budget,
// which is the worst case the client actually observed at the gate (its 20
// second deadline expired first). The client budget was calibrated
// empirically: the healthy path resolves in well under 30 rounds (pre-vote
// keeps the cut follower from deposing the leader, so the leader commits with
// the reachable follower), and 120 rounds also spans two router retransmit
// windows, proving retransmission alone cannot rescue a client pinned on a
// frozen target. The test never gates on Freezes moving: after the fix the
// freeze legitimately never arms, and that silence is the pass condition; the
// non-vacuity witness is traffic toward the cut edge, which both the buggy and
// the fixed host keep producing.

// freezeOnUnderMuSendTransport is the active sibling of lockProbeTransport
// (which stays a pure observer so the seam pin keeps its exact counts). It
// adds the trigger: a Send under the owner's mutex toward a cut edge freezes
// the sender on the fabric for stall ticks. The cut edges are test-owned: the
// test itself calls Partition, so it hands the decorator the same set instead
// of asking the fabric. The mutex is late-bound after NewHost returns, for the
// same reason as in lock_probe_test.go.
type freezeOnUnderMuSendTransport struct {
	inner cluster.Transport
	net   *cluster.SimNet
	self  cluster.NodeID
	mu    *sync.Mutex // late-bound owner mutex; nil until the host exists
	stall cluster.Tick

	blockedTo map[cluster.NodeID]bool // cut edges out of self, armed by the test

	sendsTotal       int64
	underMuSends     int64
	blockedEdgeSends int64 // sends aimed at a cut edge, the non-vacuity witness
}

// Send probes the owner's mutex, arms the freeze when a locked send targets a
// cut edge, and always forwards so the fabric sees identical traffic.
func (p *freezeOnUnderMuSendTransport) Send(to cluster.NodeID, data []byte) error {
	p.sendsTotal++
	underMu := false
	if p.mu != nil {
		if p.mu.TryLock() {
			p.mu.Unlock()
		} else {
			underMu = true
			p.underMuSends++
		}
	}
	if p.blockedTo[to] {
		p.blockedEdgeSends++
		if underMu {
			// The blocking write: the sender's one thread is now stuck inside
			// its critical section. Freeze acts at delivery time and the
			// driver skips frozen ticks, so nothing this node owns makes
			// progress until the window ends.
			p.net.Freeze(p.self, p.stall)
		}
	}
	return p.inner.Send(to, data)
}

// Close releases the wrapped endpoint.
func (p *freezeOnUnderMuSendTransport) Close() error { return p.inner.Close() }

// blockedSenderOutcome is one scenario run's observable result, compared
// across the double replay. The neighbor fields stay zero for the put flavor;
// the search flavor fills them from the completed result, so the replay pins
// the returned data and not just the status.
type blockedSenderOutcome struct {
	leader           cluster.NodeID
	done             bool
	status           ClientStatus
	exhausted        bool
	index            uint64
	neighborCount    int
	topNeighborID    uint64
	blockedEdgeSends int64
	underMuSends     int64
}

// blockedSenderOp selects which client operation the scenario pushes through
// the router once the partition is up and the trigger is armed. The put
// flavor is the original gate reproduction; the search flavor is its
// linearizable-read twin, added because the real gate stalled on Search and
// the system-level test only exercised a write.
type blockedSenderOp int

const (
	blockedSenderPut blockedSenderOp = iota
	blockedSenderSearch
)

// blockedSenderSeedID is the vector the search flavor seeds on the healthy
// path, so the Search under partition has a neighbor to return.
const blockedSenderSeedID uint64 = 7

// runBlockedSenderScenario drives one full scenario: elect a single-shard
// leader, cut the leader's edge toward one follower and arm the trigger on it,
// then push one client operation (a put or a search, per op) through the
// router and poll it for the client budget. The search flavor first seeds one
// vector on the healthy path, before the partition exists, so the data it
// queries is infrastructure and never part of the outcome under test; the put
// flavor skips the seeding and keeps its original schedule untouched.
// Infrastructure failures fatal immediately; the client outcome is returned
// for the caller to judge, so the replay can run twice.
func runBlockedSenderScenario(t *testing.T, op blockedSenderOp) blockedSenderOutcome {
	t.Helper()

	// seed is a runtime var so the per-node mix wraps mod 2^64 exactly as the
	// sealed sweep's does; a const would overflow at compile time.
	var seed uint64 = 0xB10C3

	// Latency jitters so deliveries reorder, but nothing drops or duplicates
	// at random: the freeze must be the only fault in the run.
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 4})

	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	shard := []cluster.NodeID{1, 2, 3}

	hosts := map[cluster.NodeID]*Host{}
	probes := map[cluster.NodeID]*freezeOnUnderMuSendTransport{}
	var rh *RouterHost
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range shard {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	// stallTicks outlives the whole client budget on purpose: the real 30
	// second socket write outlives the real 20 second client deadline. See the
	// file comment for why this overestimates the bounded real outage.
	const stallTicks cluster.Tick = 5000

	nodeSeed := func(id cluster.NodeID) uint64 {
		return seed*0x9E3779B97F4A7C15 + uint64(id)*0x100000001B3
	}
	for _, id := range shard {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(nodeSeed(id)), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		probe := &freezeOnUnderMuSendTransport{
			net:       net,
			self:      id,
			stall:     stallTicks,
			blockedTo: map[cluster.NodeID]bool{},
		}
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
		probe.mu = &host.mu // late binding, as in lock_probe_test.go
		probes[id] = probe
		hosts[id] = host
	}

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	rh, err = NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("router endpoint: %v", terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("router host: %v", err)
	}

	// advance is the SilentTarget round extended with the freeze contract: a
	// frozen node's tick is skipped, because its one thread is stuck inside
	// the blocking send. The fabric already defers its deliveries.
	advance := func() {
		for _, id := range shard {
			if net.Frozen(id) {
				continue
			}
			if terr := hosts[id].Tick(); terr != nil {
				t.Fatalf("host %d tick: %v", id, terr)
			}
		}
		net.Tick()
		if terr := rh.Tick(net.Clock().Now()); terr != nil {
			t.Fatalf("router host tick: %v", terr)
		}
	}
	drivePoll := func(opID uint64, budget int) (RouteResult, bool) {
		for i := 0; i < budget; i++ {
			advance()
			if res, ok := rh.Result(opID); ok {
				return res, true
			}
		}
		return RouteResult{}, false
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

	// The search flavor needs data to return. It is seeded HERE, after the
	// election and before the partition, so the seeding Upsert completes on
	// the healthy path and cannot interact with the trigger.
	if op == blockedSenderSearch {
		seedOp, serr := rh.Upsert(blockedSenderSeedID, []float32{1, 0, 0})
		if serr != nil {
			t.Fatalf("seed upsert: %v", serr)
		}
		if res, ok := drivePoll(seedOp, 300); !ok || res.Status != StatusOK || res.Index == 0 {
			t.Fatalf("seed upsert did not complete on the healthy path: done=%v %+v", ok, res)
		}
	}

	// Cut the leader's outbound edge toward one follower and arm the trigger
	// on exactly that edge. Outbound only: the leader keeps hearing everyone
	// and keeps a healthy write quorum through the other follower, which is
	// the gate's shape: correctness intact, the client starved anyway.
	victim := cluster.None
	for _, id := range shard {
		if id != leader {
			victim = id
			break
		}
	}
	net.Partition(leader, victim)
	probes[leader].blockedTo[victim] = true

	// Three rounds cover at least one heartbeat interval, so the buggy leader
	// has sent into the cut edge under its lock and frozen before the client
	// op is issued. Against a fixed host these rounds are just quiet traffic.
	for i := 0; i < 3; i++ {
		advance()
	}

	// The client: exactly ONE operation, never re-issued. The budget spans two
	// router retransmit windows (2 x 50 ticks) plus the whole healthy
	// resolution path, so only a node that never answers can exhaust it.
	const clientBudget = 120
	var opID uint64
	switch op {
	case blockedSenderPut:
		opID, err = rh.Upsert(9, []float32{1, 0, 0})
	case blockedSenderSearch:
		opID, err = rh.Search([]float32{1, 0, 0}, 1)
	}
	if err != nil {
		t.Fatalf("router host client op: %v", err)
	}
	res, done := drivePoll(opID, clientBudget)

	out := blockedSenderOutcome{
		leader:           leader,
		done:             done,
		status:           res.Status,
		exhausted:        res.Exhausted,
		index:            res.Index,
		blockedEdgeSends: probes[leader].blockedEdgeSends,
		underMuSends:     probes[leader].underMuSends,
	}
	out.neighborCount = len(res.Neighbors)
	if out.neighborCount > 0 {
		out.topNeighborID = res.Neighbors[0].ID
	}
	return out
}

// TestClusterDST_BlockedSenderStarvesClient reproduces the gate symptom in
// simulation: with one leader edge cut, a client write through the router must
// still complete, because the leader holds quorum through the reachable
// follower and pre-vote keeps the cut follower from deposing it. A leader that
// blocks inside its lock freezes instead, answers nobody, and the client
// starves past a budget no healthy schedule comes near. The scenario runs
// twice on one seed, the SilentTarget replay discipline, so the outcome is
// pinned as deterministic before it is judged.
func TestClusterDST_BlockedSenderStarvesClient(t *testing.T) {
	first := runBlockedSenderScenario(t, blockedSenderPut)
	second := runBlockedSenderScenario(t, blockedSenderPut)

	if first != second {
		t.Fatalf("replay diverged on one seed:\nfirst:  %+v\nsecond: %+v", first, second)
	}
	if first.blockedEdgeSends == 0 {
		t.Fatalf("no traffic toward the cut edge: the scenario never exercised the seam, outcome %+v", first)
	}
	if !first.done || first.status != StatusOK || first.exhausted || first.index == 0 {
		t.Fatalf("client Upsert did not complete under partition: done=%v status=%v exhausted=%v index=%d (leader %d, %d sends under its lock); the leader stalled doing network I/O under its lock and never answered, expected StatusOK",
			first.done, first.status, first.exhausted, first.index, first.leader, first.underMuSends)
	}
}

// TestClusterDST_BlockedSenderStarvesClientSearch is the Search twin of the
// put test above, and it is COVERAGE, not a reproducer of anything still
// open. With the fixed host deployed, sends happen outside the lock, the
// TryLock probe always succeeds, the freeze never arms, and this test is
// green today. Its value is the hole it closes: the system-level test only
// pushed a write through the frozen-leader schedule, so a pre-fix host that
// starved the linearizable READ path (a Search parks on a read round the
// wedged leader can never confirm) had no system-level witness. Run against
// the pre-fix host, the same freeze arms on the same edge and this Search
// starves exactly as the put did. The remaining real-infra Search hang is a
// TRANSPORT bug and lives in the TCP pin under engine/cluster, not here:
// SimNet cannot reproduce it and this test does not try.
func TestClusterDST_BlockedSenderStarvesClientSearch(t *testing.T) {
	first := runBlockedSenderScenario(t, blockedSenderSearch)
	second := runBlockedSenderScenario(t, blockedSenderSearch)

	if first != second {
		t.Fatalf("replay diverged on one seed:\nfirst:  %+v\nsecond: %+v", first, second)
	}
	if first.blockedEdgeSends == 0 {
		t.Fatalf("no traffic toward the cut edge: the scenario never exercised the seam, outcome %+v", first)
	}
	if !first.done || first.status != StatusOK || first.exhausted {
		t.Fatalf("client Search did not complete under partition: done=%v status=%v exhausted=%v (leader %d, %d sends under its lock); a leader that stalls doing network I/O under its lock parks the read round forever, expected StatusOK",
			first.done, first.status, first.exhausted, first.leader, first.underMuSends)
	}
	if first.index != 0 {
		t.Fatalf("a search resolves with a zero index, got %d: this can only be a crossed write ack", first.index)
	}
	if first.neighborCount != 1 || first.topNeighborID != blockedSenderSeedID {
		t.Fatalf("search under partition returned the wrong data: %d neighbors, top id %d, want exactly vector %d seeded on the healthy path",
			first.neighborCount, first.topNeighborID, blockedSenderSeedID)
	}
}
