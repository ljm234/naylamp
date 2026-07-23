package naylamp

import (
	"os"
	"strconv"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// This file is the deterministic-simulation net for the service-health recovery:
// a leader that has gone mute toward a client, while still holding quorum with its
// peers, steps down so a peer that can reach the client takes over. The signal and
// the client router's timeout rotation are one feature and are always driven
// together here, since the rotation is what keeps a redirect hint from bouncing a
// stuck client straight back to the mute leader. The harness brings its own pump
// that ticks the RouterHost, exactly as the router's silent-target retransmit test
// does, so the sealed 500-seed sweep in cluster_dst_test.go stays untouched.

// reachParams are the tunable knobs of the recovery. windows is the leader-side
// hysteresis H; rotateK is the router's consecutive-timeout threshold K before it
// abandons a target; retransmit is the unanswered-attempt timeout R_rot; probe is
// the paced peer-probe cadence; cooldown is how long a hint back to an abandoned
// target is ignored.
type reachParams struct {
	windows    int
	rotateK    int
	retransmit cluster.Tick
	probe      cluster.Tick
	cooldown   cluster.Tick
}

// defaultReachParams is the triple the parameter sweep selected, with the two
// derived cadences: hysteresis two windows, rotate after two silent timeouts, a fifty-tick
// retransmit, a ten-tick (about one election window) probe cadence, and a cooldown
// scaled to the retransmit budget.
func defaultReachParams() reachParams {
	return reachParams{windows: 2, rotateK: 2, retransmit: 50, probe: 10, cooldown: 50}
}

func nodeOptsReach(on bool, p reachParams) NodeOptions {
	if !on {
		return NodeOptions{}
	}
	return NodeOptions{ServiceHealth: true, ServiceHealthWindows: p.windows}
}

func routerOptsReach(on bool, p reachParams) RouterOptions {
	if !on {
		return RouterOptions{}
	}
	return RouterOptions{
		RotateOnTimeout:     true,
		RotateAfterTimeouts: p.rotateK,
		RetransmitTicks:     p.retransmit,
		ProbeTicks:          p.probe,
		SuppressCooldown:    p.cooldown,
	}
}

// openReachHosts opens a shard of hosts wired to net, each with the reach signal
// on or off. Node election generators are seeded apart from the fabric, the
// discipline the whole harness family uses.
func openReachHosts(t *testing.T, net *cluster.SimNet, cfg cluster.Config, ids []cluster.NodeID, seed uint64, on bool, p reachParams) map[cluster.NodeID]*Host {
	t.Helper()
	hosts := map[cluster.NodeID]*Host{}
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(seed*0x9E3779B97F4A7C15+uint64(id)*0x100000001B3), nodeOptsReach(on, p))
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("seed %d: endpoint %d: %v", seed, hid, terr)
			}
			return tr
		})
		if err != nil {
			t.Fatalf("seed %d: host %d: %v", seed, id, err)
		}
		hosts[id] = host
	}
	return hosts
}

func newReachRouterHost(t *testing.T, net *cluster.SimNet, sm cluster.ShardMap, seed uint64, on bool, p reachParams) *RouterHost {
	t.Helper()
	router, err := NewRouterWithOptions(routerID, sm, routerOptsReach(on, p))
	if err != nil {
		t.Fatalf("seed %d: new router: %v", seed, err)
	}
	rh, err := NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("seed %d: router endpoint: %v", seed, terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("seed %d: router host: %v", seed, err)
	}
	return rh
}

// reachOutcome is one recovery run's measured conclusion.
type reachOutcome struct {
	leader        cluster.NodeID
	newLeader     cluster.NodeID
	ceded         bool
	sameTermCede  bool
	cedeRound     int
	served        bool
	servedRound   int
	reWins        int
	droppedByEdge uint64
}

// reachRecoverBudget bounds the rounds a signal-on run drives before giving up. It
// sits far above the cede horizon so the slow tail resolves: because the aggregate
// signal lets a mute leader re-win the election it just released, recovery can take
// several re-win cycles, each stretched by the pre-existing metastable pre-vote
// case that sustained client probing aggravates. Recovery is eventually live, not
// bounded fast, and this budget is generous enough for the worst observed tail.
// reachHoldBudget is the shorter budget a signal-off control needs: with the signal
// off the leader never cedes, a deterministic outcome that a few windows confirm.
const (
	reachRecoverBudget = 8000
	reachHoldBudget    = 400
)

// runReachRecovery drives one mute-leader recovery. It elects a leader, mutes its
// edge to the client (both directions when bidir, only leader->client otherwise),
// issues one client write and re-issues a fresh one whenever the current attempt
// exhausts, and measures whether the leader ceded at its own term and whether the
// client was served WITHOUT the edge being healed. It then heals and reconverges,
// asserting the durability and equality invariants, so safety is checked whatever
// the cede decision was.
func runReachRecovery(t *testing.T, seed uint64, p reachParams, bidir, on bool, budget int) reachOutcome {
	t.Helper()
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 2 + cluster.Tick(seed%4)})
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	ids := []cluster.NodeID{1, 2, 3}
	hosts := openReachHosts(t, net, cfg, ids, seed, on, p)
	var rh *RouterHost
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range ids {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	lead := driveHostsUntilLeader(t, net, hosts, ids, 600)
	leadTerm := hosts[lead].node.core.Term()

	// Mute the leader's client edge. DropsByEdge, not Partition, so the drops land
	// in DroppedByEdge and prove the client edge fired, distinct from any peer
	// partition. Bidirectional is the recoverable case: the leader neither hears
	// the client nor answers it. Unidirectional drops only the leader's answer.
	net.DropsByEdge(lead, routerID)
	if bidir {
		net.DropsByEdge(routerID, lead)
	}

	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: cfg.Nodes}}}
	rh = newReachRouterHost(t, net, sm, seed, on, p)

	advance := func() {
		tickHosts(t, hosts, ids)
		net.Tick()
		if err := rh.Tick(net.Clock().Now()); err != nil {
			t.Fatalf("seed %d: router host tick: %v", seed, err)
		}
	}

	out := reachOutcome{leader: lead}
	const writeID uint64 = 7
	vec := vecFor(writeID)
	opID, err := rh.Upsert(writeID, vec)
	if err != nil {
		t.Fatalf("seed %d: upsert: %v", seed, err)
	}

	leaderNow := true // the tracked leader starts in office
	for i := 0; i < budget && !out.served; i++ {
		advance()
		isLead := hosts[lead].Role() == raft.RoleLeader
		if !out.ceded && !isLead {
			out.ceded = true
			out.cedeRound = i
			// The step-down keeps the term: the moment the leader is no longer a
			// leader, no higher-term leader exists yet (the election it releases has
			// not run), so its term still reads leadTerm on a clean cede.
			out.sameTermCede = hosts[lead].node.core.Term() == leadTerm
		}
		if isLead && !leaderNow {
			out.reWins++ // the mute leader took office again: aggregate-signal churn
		}
		leaderNow = isLead
		if out.newLeader == cluster.None {
			for _, id := range ids {
				if id != lead && hosts[id].Role() == raft.RoleLeader {
					out.newLeader = id
				}
			}
		}
		if res, ok := rh.Result(opID); ok {
			if res.Status == StatusOK && !res.Exhausted && res.Index != 0 {
				out.served = true
				out.servedRound = i
				break
			}
			// Exhausted (or any non-terminal answer): re-issue a fresh operation,
			// exactly as the RouterHost contract expects of a caller past a budget.
			opID, err = rh.Upsert(writeID, vec)
			if err != nil {
				t.Fatalf("seed %d: re-issue upsert: %v", seed, err)
			}
		}
	}
	out.droppedByEdge = net.Stats().DroppedByEdge

	// Safety: heal the edge and drive to convergence, so every replica holds the
	// same committed state and the write is durable, whatever the cede decision.
	net.RestoreEdge(lead, routerID)
	if bidir {
		net.RestoreEdge(routerID, lead)
	}
	converged := false
	for i := 0; i < 1000; i++ {
		advance()
		if hostsConverged(hosts, ids) {
			converged = true
			break
		}
	}
	if !converged {
		t.Fatalf("seed %d: cluster did not reconverge after healing the edge", seed)
	}
	for _, id := range ids {
		if herr := hosts[id].Err(); herr != nil {
			t.Fatalf("seed %d: host %d poisoned: %v", seed, id, herr)
		}
	}
	if herr := rh.Err(); herr != nil {
		t.Fatalf("seed %d: router host poisoned: %v", seed, herr)
	}
	return out
}

// measureHealthyCedes runs a healthy, actively served cluster where every client
// op's first attempt lands on group[0], a follower, which frames a redirect and
// turns its reach bit on: the first-contact burst the hysteresis must absorb. It
// returns whether the tracked leader ever ceded (or left its term), which a
// healthy leader must never do.
func measureHealthyCedes(t *testing.T, seed uint64, p reachParams, on bool) bool {
	t.Helper()
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 2 + cluster.Tick(seed%4)})
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	ids := []cluster.NodeID{1, 2, 3}
	hosts := openReachHosts(t, net, cfg, ids, seed, on, p)
	var rh *RouterHost
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range ids {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	lead := driveHostsUntilLeader(t, net, hosts, ids, 600)
	// Put the leader at index 1 so group[0] is a follower and every first attempt
	// is a healthy first contact that redirects.
	group := leaderAtIndex(cfg.Nodes, lead, 1)
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: group}}}
	rh = newReachRouterHost(t, net, sm, seed, on, p)
	leadTerm := hosts[lead].node.core.Term()

	advance := func() {
		tickHosts(t, hosts, ids)
		net.Tick()
		if err := rh.Tick(net.Clock().Now()); err != nil {
			t.Fatalf("seed %d: router host tick: %v", seed, err)
		}
	}

	const et = 10
	windows := 12
	if testing.Short() {
		windows = 6
	}
	for round := 0; round < windows*et; round++ {
		// A fresh search every round is the first-contact burst: its leg's first
		// attempt lands on group[0], a follower, which frames a NotLeader and turns
		// its bit on, while the leader serving the read keeps its own bit on. A read
		// appends no log entry, so this stresses the signal without an fsync a round.
		id := uint64(1) + uint64(round%clusterIDRange) //nolint:gosec // a small positive id
		if _, err := rh.Search(vecFor(id), 1); err != nil {
			t.Fatalf("seed %d: search: %v", seed, err)
		}
		advance()
		if hosts[lead].Role() != raft.RoleLeader || hosts[lead].node.core.Term() != leadTerm {
			return true
		}
	}
	return false
}

// TestClusterDST_HealthyLeaderNeverCedesByReach is the dedicated negative control:
// a healthy leader serving clients, under a churn of first-contact bursts to a
// follower at group[0], never cedes. This is the property the hard rule requires
// before any hardware run: a healthy leader must never be unseated by this signal.
func TestClusterDST_HealthyLeaderNeverCedesByReach(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(2)
	if testing.Short() {
		seeds = 1
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		if measureHealthyCedes(t, seed, p, true) {
			t.Fatalf("seed %d: a healthy, actively served leader ceded by reach", seed)
		}
	}
}

// TestClusterDST_MuteLeaderCedesAndRecovers is the bidirectional scenario: a
// leader mute toward the client in both directions cedes at its own term, a peer
// takes over, and the client's write is served by the new leader WITHOUT the edge
// being healed, with the client-edge drops counted apart from any peer partition.
func TestClusterDST_MuteLeaderCedesAndRecovers(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(2)
	if testing.Short() {
		seeds = 1
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, true, true, reachRecoverBudget)
		if !out.ceded {
			t.Fatalf("seed %d: the mute leader never ceded", seed)
		}
		if !out.sameTermCede {
			t.Fatalf("seed %d: the leader ceded but did not keep its term", seed)
		}
		if out.newLeader == cluster.None {
			t.Fatalf("seed %d: no peer took leadership after the cede", seed)
		}
		if !out.served {
			t.Fatalf("seed %d: the client was never served by the new leader", seed)
		}
		if out.droppedByEdge == 0 {
			t.Fatalf("seed %d: the client edge never dropped a frame; the mute was a no-op", seed)
		}
	}
}

// TestClusterDST_MuteLeaderUnidirectionalIsMeasuredFailSafe runs the third arm: a
// leader whose answer to the client is dropped but whose inbound path is open. An
// earlier design note held that this case never cedes, detection lost but safe.
// This measures it under the rotation-and-signal design and asserts only safety
// (any cede keeps the term, the edge really dropped, and the cluster reconverges);
// the cede-and-recover outcome is logged as the finding, never forced green.
func TestClusterDST_MuteLeaderUnidirectionalIsMeasuredFailSafe(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(2)
	if testing.Short() {
		seeds = 1
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, false, true, reachRecoverBudget)
		t.Logf("seed %d unidirectional: ceded=%v sameTerm=%v served=%v newLeader=%d cedeRound=%d servedRound=%d reWins=%d droppedByEdge=%d",
			seed, out.ceded, out.sameTermCede, out.served, out.newLeader, out.cedeRound, out.servedRound, out.reWins, out.droppedByEdge)
		if out.ceded && !out.sameTermCede {
			t.Fatalf("seed %d: a unidirectional cede inflated the term", seed)
		}
		if out.droppedByEdge == 0 {
			t.Fatalf("seed %d: the unidirectional mute never dropped a frame", seed)
		}
	}
}

// TestClusterDST_ServiceHealthSeeded sweeps the bidirectional recovery across many
// seeds with the signal ON and OFF. With it on, every seed cedes at term and the
// client is served without a heal; with it off, the leader holds and the mute is
// never recovered, the pre-signal status quo, which is what proves the option gates
// the whole behavior. NAYLAMP_REACH_SEEDS overrides the count for the seal gate.
func TestClusterDST_ServiceHealthSeeded(t *testing.T) {
	seeds := 4
	if testing.Short() {
		seeds = 2
	}
	if env := os.Getenv("NAYLAMP_REACH_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_REACH_SEEDS=%q invalid", env)
		}
		seeds = v
	}
	p := defaultReachParams()
	cededOn, servedOn := 0, 0
	for s := 1; s <= seeds; s++ {
		seed := uint64(s) //nolint:gosec // s ranges over positive seed numbers
		on := runReachRecovery(t, seed, p, true, true, reachRecoverBudget)
		if !on.ceded || !on.sameTermCede {
			t.Fatalf("seed %d: signal on but the mute leader did not cede at term", seed)
		}
		if !on.served {
			t.Fatalf("seed %d: signal on but the client was never served", seed)
		}
		if on.droppedByEdge == 0 {
			t.Fatalf("seed %d: signal on but the client edge never dropped", seed)
		}
		cededOn++
		servedOn++

		off := runReachRecovery(t, seed, p, true, false, reachHoldBudget)
		if off.ceded {
			t.Fatalf("seed %d: signal off but the leader ceded anyway", seed)
		}
		if off.served {
			t.Fatalf("seed %d: signal off but the mute was recovered; the option did not gate the behavior", seed)
		}
	}
	t.Logf("service-health seeded: seeds=%d cededOn=%d servedOn=%d (signal off: never ceded, never recovered)", seeds, cededOn, servedOn)
}

// TestClusterDST_MultiShardSearchProbeNoPanic exercises the paced-probe path with a
// MULTI-shard search, the one shape the single-group recovery harnesses never hit:
// a search fans one leg per shard, and two legs of the same operation can be parked
// and re-probed together, so when one leg exhausts its budget and retires the whole
// operation its sibling must not be dereferenced through the now-absent operation.
// Both shard leaders are muted toward the client with the rotation on and the cede
// signal off, so neither leader steps down and both legs probe until they exhaust,
// driving many parked-sibling re-probes. The assertion is simply that no probe ever
// panics or poisons the host, and that the cluster stays healthy.
func TestClusterDST_MultiShardSearchProbeNoPanic(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(4)
	if testing.Short() {
		seeds = 2
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		runMultiShardSearchProbe(t, seed, p)
	}
}

func runMultiShardSearchProbe(t *testing.T, seed uint64, p reachParams) {
	t.Helper()
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 2 + cluster.Tick(seed%3)})
	cfg0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	cfg1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 4}, {ID: 5}, {ID: 6}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg0, cfg1}}
	shardIDs := [][]cluster.NodeID{{1, 2, 3}, {4, 5, 6}}
	allIDs := []cluster.NodeID{1, 2, 3, 4, 5, 6}
	groupCfg := map[cluster.NodeID]cluster.Config{1: cfg0, 2: cfg0, 3: cfg0, 4: cfg1, 5: cfg1, 6: cfg1}

	hosts := map[cluster.NodeID]*Host{}
	for _, id := range allIDs {
		node, err := OpenNode(t.TempDir(), id, groupCfg[id], 3, testRNG(seed*0x9E3779B97F4A7C15+uint64(id)*0x100000001B3), nodeOptsReach(false, p))
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("seed %d: endpoint %d: %v", seed, hid, terr)
			}
			return tr
		})
		if err != nil {
			t.Fatalf("seed %d: host %d: %v", seed, id, err)
		}
		hosts[id] = host
	}
	var rh *RouterHost
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range allIDs {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	l0 := driveHostsUntilLeader(t, net, hosts, shardIDs[0], 600)
	l1 := driveHostsUntilLeader(t, net, hosts, shardIDs[1], 600)
	for _, l := range []cluster.NodeID{l0, l1} {
		net.DropsByEdge(l, routerID)
		net.DropsByEdge(routerID, l)
	}
	// The router runs with rotation on; the nodes run with the cede signal off, so
	// both muted leaders hold office and both search legs probe to exhaustion.
	rh = newReachRouterHost(t, net, sm, seed, true, p)

	advance := func() {
		tickHosts(t, hosts, allIDs)
		net.Tick()
		if err := rh.Tick(net.Clock().Now()); err != nil {
			t.Fatalf("seed %d: router host tick: %v", seed, err)
		}
	}

	opID, err := rh.Search(vecFor(7), 3)
	if err != nil {
		t.Fatalf("seed %d: search: %v", seed, err)
	}
	resolved := false
	for i := 0; i < 3000 && !resolved; i++ {
		advance()
		if herr := rh.Err(); herr != nil {
			t.Fatalf("seed %d: router host poisoned during a multi-shard probe: %v", seed, herr)
		}
		if _, ok := rh.Result(opID); ok {
			resolved = true
		}
	}
	if !resolved {
		t.Fatalf("seed %d: the multi-shard search never resolved (expected an exhaust under the persistent mute)", seed)
	}

	net.RestoreEdge(l0, routerID)
	net.RestoreEdge(routerID, l0)
	net.RestoreEdge(l1, routerID)
	net.RestoreEdge(routerID, l1)
	for sh := range shardIDs {
		converged := false
		for i := 0; i < 800; i++ {
			advance()
			if hostsConverged(hosts, shardIDs[sh]) {
				converged = true
				break
			}
		}
		if !converged {
			t.Fatalf("seed %d: shard %d did not reconverge after healing", seed, sh)
		}
	}
	for _, id := range allIDs {
		if herr := hosts[id].Err(); herr != nil {
			t.Fatalf("seed %d: host %d poisoned: %v", seed, id, herr)
		}
	}
}

// TestRouter_ProbeHeldSiblingLegExhaust pins the sibling-leg guard in the paced
// probe by driving the exact concurrence by hand: a search fans one leg per shard
// under a single op id, and when a re-probe of one held leg exhausts its budget and
// retires the whole search, the sibling leg re-probed in the same tick must not be
// dereferenced through the now-absent op. The multi-shard recovery test above only
// exercises this path incidentally; this one forces it.
func TestRouter_ProbeHeldSiblingLegExhaust(t *testing.T) {
	g0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}}}
	g1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 3}, {ID: 4}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{g0, g1}}
	router, err := NewRouterWithOptions(routerID, sm, RouterOptions{
		RotateOnTimeout: true, RotateAfterTimeouts: 1, RetransmitTicks: 5, ProbeTicks: 5, SuppressCooldown: 1000,
	})
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	opID, frames, err := router.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(frames) != 2 {
		t.Fatalf("expected one first attempt per shard, got %d frames", len(frames))
	}
	origin0, _ := decodeReq(t, frames[0]) // leg 0 -> shard 0 group[0]
	origin1, _ := decodeReq(t, frames[1]) // leg 1 -> shard 1 group[0]

	// Time both first attempts out. With a one-timeout threshold each leg abandons
	// and suppresses its first target and rotates to its group's other member.
	out, err := router.Tick(5)
	if err != nil {
		t.Fatalf("tick: %v", err)
	}
	if len(out) != 2 {
		t.Fatalf("expected two rotated re-emits, got %d", len(out))
	}
	rot0, req0 := decodeReq(t, out[0])
	rot1, req1 := decodeReq(t, out[1])

	// Answer each rotated attempt NotLeader with a hint back to the suppressed first
	// target, so each leg parks for a paced probe rather than obeying the bounce.
	if _, err := router.HandleMessage(mustEncodeRespFrom(t, rot0, ClientResponse{ReqID: req0, Status: StatusNotLeader, Leader: origin0})); err != nil {
		t.Fatalf("leg 0 not-leader: %v", err)
	}
	if _, err := router.HandleMessage(mustEncodeRespFrom(t, rot1, ClientResponse{ReqID: req1, Status: StatusNotLeader, Leader: origin1})); err != nil {
		t.Fatalf("leg 1 not-leader: %v", err)
	}
	op := router.searchOps[opID]
	if op == nil || op.legs[0].rot.holdUntil == 0 || op.legs[1].rot.holdUntil == 0 {
		t.Fatalf("both legs should be parked for a probe: %+v", op)
	}

	// Spend leg 0's budget so its re-probe retires the whole search and deletes the
	// op before the sibling leg 1 is re-probed in the same tick.
	op.legs[0].attemptsLeft = 0

	// The paced probe of both legs fires at this tick. The sibling guard is what
	// keeps leg 1 from dereferencing the op leg 0 just deleted.
	if _, err := router.Tick(10); err != nil {
		t.Fatalf("probe tick: %v", err)
	}
	if _, retired := router.results[opID]; !retired {
		t.Fatalf("the exhausting leg should have retired the search into results")
	}
}

// TestClusterDST_ServiceHealthSweep measures the recovery across a bounded grid of
// (K, H, R_rot), the three named parameters, with the probe cadence and cooldown
// derived. For each triple it counts the healthy-control false cedes (which must be
// zero) and the bidirectional cede-and-serve rate (which must be complete) and
// logs the worst-case cede round. The report reads these lines and either names the
// triple that clears both bars with margin or records the measured impossibility if
// none does. It is env-gated because it is a measurement, not a pass/fail gate.
func TestClusterDST_ServiceHealthSweep(t *testing.T) {
	if os.Getenv("NAYLAMP_REACH_SWEEP") == "" {
		t.Skip("set NAYLAMP_REACH_SWEEP=1 to run the (K,H,R_rot) parameter sweep")
	}
	ks := []int{2, 3}
	hs := []int{2, 3}
	rs := []cluster.Tick{30, 50}
	const perCombo = 4
	for _, k := range ks {
		for _, h := range hs {
			for _, rrot := range rs {
				p := reachParams{windows: h, rotateK: k, retransmit: rrot, probe: 10, cooldown: rrot}
				falseCedes, cedes, served, maxCede := 0, 0, 0, 0
				for s := uint64(1); s <= perCombo; s++ {
					if measureHealthyCedes(t, s, p, true) {
						falseCedes++
					}
					out := runReachRecovery(t, s, p, true, true, 2000)
					if out.ceded {
						cedes++
					}
					if out.served {
						served++
					}
					if out.cedeRound > maxCede {
						maxCede = out.cedeRound
					}
				}
				t.Logf("K=%d H=%d R_rot=%d (probe=%d cooldown=%d) :: healthy falseCedes=%d/%d  mute cedes=%d/%d served=%d/%d maxCedeRound=%d",
					k, h, rrot, p.probe, p.cooldown, falseCedes, perCombo, cedes, perCombo, served, perCombo, maxCede)
			}
		}
	}
}
