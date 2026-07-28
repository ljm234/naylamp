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
// the client router's timeout rotation are one feature, so every arm that stands
// for a deployment drives them together, the rotation being what keeps a redirect
// hint from bouncing a stuck client straight back to the mute leader. Three arms
// drive them apart on purpose and each says why where it does it: the multi-shard
// probe test, which needs both muted leaders to hold office, and the targeting
// grid and the aim-placement measurement, which need the client's target to stop
// moving on a timeout. The harness brings its own pump that ticks the RouterHost,
// exactly as the router's silent-target retransmit test does, so the sealed
// 500-seed sweep in cluster_dst_test.go stays untouched.

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

// reachLayers selects which of the two halves a run drives: signal is the core's
// client-reach step-down, rotate is the client router's timeout rotation and hint
// suppression. A deployment gets both or neither, and the option comments in the
// node and the router say so, because the signal alone deadlocks the recovery and
// the rotation alone reopens the redirect bounce. featureOn and featureOff are
// those two configurations. A mismatched pair is NOT a supported deployment; it is
// an isolation instrument. The pairing the grid uses, signal on and rotation off,
// stops a timeout from moving the client's target, though a redirect the client
// can still hear moves it anyway, so it pins the aim only where no answer reaches
// the client; the grid says where. The multi-shard probe uses the other pairing.
type reachLayers struct {
	signal bool
	rotate bool
}

func featureOn() reachLayers  { return reachLayers{signal: true, rotate: true} }
func featureOff() reachLayers { return reachLayers{} }

func nodeOptsReach(on bool, p reachParams) NodeOptions {
	if !on {
		return NodeOptions{}
	}
	return NodeOptions{ServiceHealth: true, ServiceHealthWindows: p.windows}
}

// routerOptsReach builds the client router's options. With the rotation off it
// returns the zero value, so the coordinator falls back to its constructor
// defaults, and those happen to be defaultReachParams: an arm that toggles the
// rotation alone does not also move the cadence. That only holds while p is the
// default one, which is the only p any arm uses with the rotation off.
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

// muteScope selects which client edges a recovery run drops. The four scopes are
// different faults, not degrees of one fault, and the signal is meant to tell them
// apart: it can only hand a client to a node that is still able to answer it.
type muteScope int

const (
	// muteLeaderAnswers drops the leader's answers to the client and leaves the
	// client's requests to the leader flowing. The leader keeps framing answers it
	// cannot deliver, so its own bit stays lit until the router stops feeding it.
	muteLeaderAnswers muteScope = iota
	// muteLeaderBothWays drops both directions between the leader and the client.
	// Every peer keeps its client edge, so the client is still reachable by a node
	// other than the leader: one node is cut off, and the rest can take over. This
	// is the deadlock the hint suppression was built for, not a client that nobody
	// can reach.
	muteLeaderBothWays
	// muteEveryNodeAnswersOnly drops every node's answers to the client while the
	// client keeps sending. It is the regime the availability study named as the
	// one where a step-down is pure loss: no node can complete a request, so a
	// leader that steps down hands the client to a successor that is equally
	// unable to serve it, and every OTHER client pays for the churn. Because the
	// client still gets through, every node keeps framing answers it cannot
	// deliver, so this is NOT the same fault as cutting the client off entirely.
	muteEveryNodeAnswersOnly
	// muteEveryNodeBothWays isolates the client from every node in both
	// directions, so nothing it sends arrives and nothing sent to it lands.
	muteEveryNodeBothWays
)

// clientEdges lists the node ends of the client edges a scope drops.
func (m muteScope) clientEdges(lead cluster.NodeID, ids []cluster.NodeID) []cluster.NodeID {
	if m == muteEveryNodeAnswersOnly || m == muteEveryNodeBothWays {
		return ids
	}
	return []cluster.NodeID{lead}
}

// bothWays reports whether the scope also drops the client's requests to a node,
// rather than only that node's answers.
func (m muteScope) bothWays() bool {
	return m == muteLeaderBothWays || m == muteEveryNodeBothWays
}

// reachOutcome is one recovery run's measured conclusion. firstTarget is the
// member the client's first attempt aims at, index 0 of the write's shard group,
// recorded because whether the leader sits there decides who ever frames an
// answer once the client is stuck aiming at one member.
type reachOutcome struct {
	leader        cluster.NodeID
	firstTarget   cluster.NodeID
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

// naturalOrder leaves the client's view of the group in configuration order, so
// where the leader sits in that view is whatever the election decided. Every arm
// that drives a recovery wants that except the aim-placement one; the healthy
// control reorders its own view for a different reason, and says so there.
const naturalOrder = -1

// runReachRecovery drives one mute-leader recovery with the client seeing the
// group in configuration order. It elects a leader, drops the client edges the
// scope names, issues one client write and re-issues a fresh one whenever the
// current attempt exhausts, and measures whether the leader ceded at its own term
// and whether the client was served WITHOUT any edge being healed. It then heals
// and reconverges, asserting the durability and equality invariants, so safety is
// checked whatever the cede decision was.
func runReachRecovery(t *testing.T, seed uint64, p reachParams, mute muteScope, layers reachLayers, budget int) reachOutcome {
	t.Helper()
	return runReachRecoveryAt(t, seed, p, mute, layers, naturalOrder, budget)
}

// runReachRecoveryAt is the same run with the client's view of the group rotated
// so the leader sits at leaderAt, which is how the aim-placement arm sets what
// the grid could only observe. Only the client's view moves; the replicas keep
// their configuration order.
func runReachRecoveryAt(t *testing.T, seed uint64, p reachParams, mute muteScope, layers reachLayers, leaderAt, budget int) reachOutcome {
	t.Helper()
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 2 + cluster.Tick(seed%4)})
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	ids := []cluster.NodeID{1, 2, 3}
	hosts := openReachHosts(t, net, cfg, ids, seed, layers.signal, p)
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

	// Drop the client edges this scope names. DropsByEdge, not Partition, so the
	// drops land in DroppedByEdge and prove a client edge fired, distinct from any
	// peer partition.
	muted := mute.clientEdges(lead, ids)
	for _, id := range muted {
		net.DropsByEdge(id, routerID)
		if mute.bothWays() {
			net.DropsByEdge(routerID, id)
		}
	}

	view := cfg.Nodes
	if leaderAt != naturalOrder {
		view = leaderAtIndex(cfg.Nodes, lead, leaderAt)
	}
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: view}}}
	rh = newReachRouterHost(t, net, sm, seed, layers.rotate, p)

	advance := func() {
		tickHosts(t, hosts, ids)
		net.Tick()
		if err := rh.Tick(net.Clock().Now()); err != nil {
			t.Fatalf("seed %d: router host tick: %v", seed, err)
		}
	}

	const writeID uint64 = 7
	// The first attempt of every operation aims at index 0 of the write's own
	// shard group, so the member that sits there is read off the map the same way
	// the router reads it rather than assumed to be the first node.
	out := reachOutcome{leader: lead, firstTarget: sm.Groups[sm.ShardFor(writeID)].Nodes[0].ID}
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
	for _, id := range muted {
		net.RestoreEdge(id, routerID)
		if mute.bothWays() {
			net.RestoreEdge(routerID, id)
		}
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
func measureHealthyCedes(t *testing.T, seed uint64, p reachParams, layers reachLayers) bool {
	t.Helper()
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 2 + cluster.Tick(seed%4)})
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	ids := []cluster.NodeID{1, 2, 3}
	hosts := openReachHosts(t, net, cfg, ids, seed, layers.signal, p)
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
	rh = newReachRouterHost(t, net, sm, seed, layers.rotate, p)
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
		if measureHealthyCedes(t, seed, p, featureOn()) {
			t.Fatalf("seed %d: a healthy, actively served leader ceded by reach", seed)
		}
	}
}

// TestClusterDST_MuteLeaderCedesAndRecovers cuts ONE node off from the client in
// both directions and leaves every peer's client edge intact, so the client is
// still reachable by a node other than the leader. The leader cedes at its own
// term, a peer takes over, and the client's write is served by the new leader
// WITHOUT the edge being healed, with the client-edge drops counted apart from any
// peer partition. This is the arm the hint suppression was built for. It is not a
// client that no node can reach; that case is measured separately below.
func TestClusterDST_MuteLeaderCedesAndRecovers(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(2)
	if testing.Short() {
		seeds = 1
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, muteLeaderBothWays, featureOn(), reachRecoverBudget)
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

// TestClusterDST_MuteLeaderAnswersOnlyIsMeasured runs the arm where only the
// leader's answers are dropped and its inbound path stays open. An earlier design
// note held that this case never cedes, detection lost but safe. This measures it
// under the rotation-and-signal design and asserts only safety (any cede keeps the
// term, the edge really dropped, and the cluster reconverges); the outcome itself
// is logged as the finding, never forced green.
func TestClusterDST_MuteLeaderAnswersOnlyIsMeasured(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(2)
	if testing.Short() {
		seeds = 1
	}
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, muteLeaderAnswers, featureOn(), reachRecoverBudget)
		t.Logf("seed %d answers-only: ceded=%v sameTerm=%v served=%v newLeader=%d cedeRound=%d servedRound=%d reWins=%d droppedByEdge=%d",
			seed, out.ceded, out.sameTermCede, out.served, out.newLeader, out.cedeRound, out.servedRound, out.reWins, out.droppedByEdge)
		if out.ceded && !out.sameTermCede {
			t.Fatalf("seed %d: an answers-only cede inflated the term", seed)
		}
		if out.droppedByEdge == 0 {
			t.Fatalf("seed %d: the answers-only mute never dropped a frame", seed)
		}
	}
}

// TestClusterDST_ServiceHealthSeeded sweeps the one-node-cut-off recovery across
// many seeds with the signal ON and OFF. With it on, every seed cedes at term and
// the client is served without a heal; with it off, the leader holds and the mute
// is never recovered, the pre-signal status quo, which is what proves the option
// gates the whole behavior. NAYLAMP_REACH_SEEDS overrides the count for the seal
// gate. Every seed logs its own cede and serve rounds, so the tail of the
// distribution is read off a saved run instead of a remembered one, and the two
// arms carry unequal budgets by design: the on arm must be given room for the slow
// tail, while the off arm only has to show the leader holding.
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
	worstCede, worstServe, worstReWins := 0, 0, 0
	worstCedeSeed, worstServeSeed, worstReWinsSeed := uint64(0), uint64(0), uint64(0)
	for s := 1; s <= seeds; s++ {
		seed := uint64(s) //nolint:gosec // s ranges over positive seed numbers
		on := runReachRecovery(t, seed, p, muteLeaderBothWays, featureOn(), reachRecoverBudget)
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
		if on.cedeRound > worstCede {
			worstCede, worstCedeSeed = on.cedeRound, seed
		}
		if on.servedRound > worstServe {
			worstServe, worstServeSeed = on.servedRound, seed
		}
		if on.reWins > worstReWins {
			worstReWins, worstReWinsSeed = on.reWins, seed
		}

		off := runReachRecovery(t, seed, p, muteLeaderBothWays, featureOff(), reachHoldBudget)
		if off.ceded {
			t.Fatalf("seed %d: signal off but the leader ceded anyway", seed)
		}
		if off.served {
			t.Fatalf("seed %d: signal off but the mute was recovered; the option did not gate the behavior", seed)
		}
		// One line per seed, so a tail figure quoted anywhere can be traced back to
		// the seed that produced it and replayed.
		t.Logf("seed %d on: cedeRound=%d servedRound=%d reWins=%d droppedByEdge=%d newLeader=%d | off: ceded=%v served=%v heldRounds=%d",
			seed, on.cedeRound, on.servedRound, on.reWins, on.droppedByEdge, on.newLeader,
			off.ceded, off.served, reachHoldBudget)
	}
	t.Logf("service-health seeded: seeds=%d cededOn=%d servedOn=%d onBudget=%d offBudget=%d (signal off: never ceded, never recovered)",
		seeds, cededOn, servedOn, reachRecoverBudget, reachHoldBudget)
	t.Logf("service-health tail: worstCedeRound=%d (seed %d) worstServedRound=%d (seed %d) worstReWins=%d (seed %d)",
		worstCede, worstCedeSeed, worstServe, worstServeSeed, worstReWins, worstReWinsSeed)
}

// TestClusterDST_NoNodeAnswersClientIsMeasured runs the regime where a step-down
// is pure loss: every node's answers to the client are dropped while the client
// KEEPS SENDING, so no node can complete a request and handing the client to a
// successor gains nothing while every other client pays the churn.
//
// The measured answer is that the leader steps down here in all but a handful of
// seeds, 95 of 100 in the grid run below and 478 of 500 in a longer one, so the
// signal does not tell this regime apart from the one where a peer could take over.
// The reason is that the bit is set when a node FRAMES an answer, not when one
// arrives: a follower that receives the request frames a redirect it can never
// deliver and lights its bit all the same. The leader's own bit then goes dark
// simply because the client's router stopped aiming at it, either because the
// first attempt went to another member or because the timeout rotation moved on.
// So the asymmetry that fires the step-down is produced by the client's targeting,
// not by any difference in who can serve. Contrast the arm below, where the
// client's requests are dropped too: there no node frames anything, no peer bit
// lights, and the leader correctly holds. What the signal actually separates is
// whether SOME node received a client request this window, which is a broken
// client send path, not a broken client receive path.
//
// The cede decision is measured and logged, never asserted, so this test records
// the behavior instead of freezing a claim about it. Safety is asserted.
func TestClusterDST_NoNodeAnswersClientIsMeasured(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(30)
	if testing.Short() {
		seeds = 3
	}
	if env := os.Getenv("NAYLAMP_REACH_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_REACH_SEEDS=%q invalid", env)
		}
		seeds = uint64(v) //nolint:gosec // v is checked positive above
	}
	cedes, serves, totalReWins := 0, 0, 0
	worstReWins := 0
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, muteEveryNodeAnswersOnly, featureOn(), reachRecoverBudget)
		if out.ceded {
			cedes++
		}
		if out.served {
			serves++
		}
		totalReWins += out.reWins
		if out.reWins > worstReWins {
			worstReWins = out.reWins
		}
		// Safety is asserted; the cede decision is measured, never forced green.
		if out.ceded && !out.sameTermCede {
			t.Fatalf("seed %d: a cede in this regime inflated the term", seed)
		}
		if out.served {
			t.Fatalf("seed %d: the client was served while every node's answers were dropped", seed)
		}
		if out.droppedByEdge == 0 {
			t.Fatalf("seed %d: no client edge dropped a frame; the mute was a no-op", seed)
		}
		t.Logf("seed %d no-node-answers: ceded=%v sameTerm=%v served=%v cedeRound=%d reWins=%d droppedByEdge=%d budget=%d",
			seed, out.ceded, out.sameTermCede, out.served, out.cedeRound, out.reWins, out.droppedByEdge, reachRecoverBudget)
	}
	t.Logf("no-node-answers: seeds=%d cedes=%d serves=%d totalReWins=%d worstReWins=%d budget=%d",
		seeds, cedes, serves, totalReWins, worstReWins, reachRecoverBudget)
}

// TestClusterDST_NoNodeReachesClientIsMeasured runs the neighboring fault: the
// client is cut off from EVERY node in BOTH directions, so nothing it sends
// arrives either. Every muting arm before the one above cut a single node off and
// left its peers' client edges intact, so a peer could always take over. The
// leader must hold, and here it does. The cede condition needs positive
// evidence that some peer FRAMED an answer to the client this window, and with the
// client's own requests dropped no node ever receives one, so no bit anywhere
// lights and the condition cannot be met. It holds by construction rather than by
// timing. It is the same outcome as the arm above but for the opposite reason, and
// the pair is what pins down that the signal keys on a client request ARRIVING,
// not on an answer reaching the client.
// The arm runs on the same budget the recoverable arm gets, so "did not cede" is
// measured over the window in which the recoverable arm cedes and recovers many
// times over, not over a short one.
func TestClusterDST_NoNodeReachesClientIsMeasured(t *testing.T) {
	p := defaultReachParams()
	seeds := uint64(30)
	if testing.Short() {
		seeds = 3
	}
	if env := os.Getenv("NAYLAMP_REACH_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_REACH_SEEDS=%q invalid", env)
		}
		seeds = uint64(v) //nolint:gosec // v is checked positive above
	}
	cedes, serves := 0, 0
	for seed := uint64(1); seed <= seeds; seed++ {
		out := runReachRecovery(t, seed, p, muteEveryNodeBothWays, featureOn(), reachRecoverBudget)
		if out.ceded {
			cedes++
		}
		if out.served {
			serves++
		}
		if out.ceded {
			t.Fatalf("seed %d: the leader ceded although no node could reach the client, so the term was spent on a successor that cannot serve it either", seed)
		}
		if out.served {
			t.Fatalf("seed %d: the client was served while every node's client edge was dropped", seed)
		}
		if out.droppedByEdge == 0 {
			t.Fatalf("seed %d: no client edge dropped a frame; the mute was a no-op", seed)
		}
		t.Logf("seed %d no-node-reaches: ceded=%v served=%v reWins=%d droppedByEdge=%d heldRounds=%d",
			seed, out.ceded, out.served, out.reWins, out.droppedByEdge, reachRecoverBudget)
	}
	t.Logf("no-node-reaches: seeds=%d cedes=%d serves=%d budget=%d", seeds, cedes, serves, reachRecoverBudget)
}

// reachMeasurementSeeds gates the three arms that exist to MEASURE rather than to
// guard: the targeting grid and its two controls. They only run when
// NAYLAMP_REACH_SEEDS names a seed count, which is what the saved runs pass, and
// the reason is arithmetic rather than taste. This package already sits near the
// ten minute default the go tool allows a test binary under the race detector,
// and these arms drive their full budget on every seed, so leaving them in the
// default set pushed the package past it. The shared driver they exercise is
// covered by the arms above, which do run every time.
func reachMeasurementSeeds(t *testing.T) uint64 {
	t.Helper()
	env := os.Getenv("NAYLAMP_REACH_SEEDS")
	if env == "" {
		t.Skip("set NAYLAMP_REACH_SEEDS to a seed count to run this measurement")
	}
	v, err := strconv.Atoi(env)
	if err != nil || v < 1 {
		t.Fatalf("NAYLAMP_REACH_SEEDS=%q invalid", env)
	}
	return uint64(v) //nolint:gosec // v is checked positive above
}

// reachGridCell is one cell of the targeting grid: which client answers the fault
// drops, crossed with how the client aims.
type reachGridCell struct {
	name   string
	mute   muteScope
	layers reachLayers
}

// TestClusterDST_ClientTargetingGridIsMeasured crosses the two answer-dropping
// faults with the router's timeout rotation on and off. The step-down fires on an
// asymmetry, a peer reporting a framed client answer this window while the leader
// framed none, and the arms above read the code and concluded that the client's
// aim, and not any difference in who can serve, is what produces it. This grid
// measures that instead of arguing it. Rotation off alongside the signal is NOT a
// supported deployment, as the option comments say; here it is the instrument.
//
// Turning the rotation off does NOT do the same thing in both rows, and the rows
// have to be read apart. Only the suppression branch of a redirect is gated by
// the rotation (router.go redirectWrite), so a usable hint is obeyed either way.
// With every node's answers dropped no answer reaches the client at all, so no
// hint exists, the aim stays where the first attempt put it for the whole run,
// and whether the leader sits at group[0] is the only thing that decides who ever
// frames: that row is where the targeting explanation is actually under test.
// With only the leader's answers dropped, a peer's redirect DOES arrive and aims
// the client back at the mute leader, which keeps its bit lit; that row measures
// the redirect bounce that was argued on paper and never measured.
//
// So each seed records whether the leader sat at the member the first attempt
// targets, and each cell counts the cedes both ways. Safety is asserted; the cede
// decision is counted and logged, never required. Every cell carries the same
// budget, though a cell whose client can be served stops at the serve, so the
// cede counts compare across cells and the round and re-win figures do not.
func TestClusterDST_ClientTargetingGridIsMeasured(t *testing.T) {
	seeds := reachMeasurementSeeds(t)
	p := defaultReachParams()
	cells := []reachGridCell{
		{"leader-answers rotation-on", muteLeaderAnswers, featureOn()},
		{"leader-answers rotation-off", muteLeaderAnswers, reachLayers{signal: true}},
		{"every-node-answers rotation-on", muteEveryNodeAnswersOnly, featureOn()},
		{"every-node-answers rotation-off", muteEveryNodeAnswersOnly, reachLayers{signal: true}},
	}
	for _, c := range cells {
		cedes, sameTermCedes, serves := 0, 0, 0
		leaderAimed, cedesAimed, cedesElsewhere, worstCede, totalReWins := 0, 0, 0, 0, 0
		for seed := uint64(1); seed <= seeds; seed++ {
			out := runReachRecovery(t, seed, p, c.mute, c.layers, reachRecoverBudget)
			aimed := out.leader == out.firstTarget
			if aimed {
				leaderAimed++
			}
			if out.ceded {
				cedes++
				if out.sameTermCede {
					sameTermCedes++
				}
				if aimed {
					cedesAimed++
				} else {
					cedesElsewhere++
				}
				if out.cedeRound > worstCede {
					worstCede = out.cedeRound
				}
			}
			if out.served {
				serves++
			}
			totalReWins += out.reWins
			if out.ceded && !out.sameTermCede {
				t.Fatalf("cell %s seed %d: the leader left office without keeping its term", c.name, seed)
			}
			if c.mute == muteEveryNodeAnswersOnly && out.served {
				// No node can deliver an answer in this regime, so a serve would mean
				// the fault did not bite, not that the client recovered.
				t.Fatalf("cell %s seed %d: the client was served while every node's answers were dropped", c.name, seed)
			}
			if out.droppedByEdge == 0 {
				t.Fatalf("cell %s seed %d: no client edge dropped a frame; the mute was a no-op", c.name, seed)
			}
			t.Logf("cell %s seed %d: leader=%d firstTarget=%d leaderAimedAt=%v ceded=%v sameTerm=%v served=%v cedeRound=%d servedRound=%d reWins=%d droppedByEdge=%d",
				c.name, seed, out.leader, out.firstTarget, aimed, out.ceded, out.sameTermCede, out.served,
				out.cedeRound, out.servedRound, out.reWins, out.droppedByEdge)
		}
		t.Logf("grid cell %s: seeds=%d cedes=%d sameTermCedes=%d serves=%d leaderAtFirstTarget=%d cedesWithLeaderAimedAt=%d cedesWithLeaderElsewhere=%d worstCedeRound=%d totalReWins=%d budget=%d",
			c.name, seeds, cedes, sameTermCedes, serves, leaderAimed, cedesAimed, cedesElsewhere, worstCede, totalReWins, reachRecoverBudget)
	}
}

// TestClusterDST_LeaderHoldsUnderAnswerDropsWithFeatureOff is the baseline every
// cede count in the grid is read against. Both answer-dropping faults are driven
// with the whole feature off, over the SAME long budget the grid gives its cells,
// and the leader must hold office throughout. Without it, a cede in the grid only
// says the leader stopped being leader: the harness reads that from the role, and
// a role change could also come from CheckQuorum, which the node turns on
// unconditionally, or from an election the schedule produced on its own. With the
// baseline flat, a cede under the same fault with the signal on is the signal's.
//
// A red here does not mean the feature regressed. It means the attribution the
// grid rests on is unsound and the grid has to be read again, so it is asserted
// rather than logged.
func TestClusterDST_LeaderHoldsUnderAnswerDropsWithFeatureOff(t *testing.T) {
	seeds := reachMeasurementSeeds(t)
	p := defaultReachParams()
	faults := []struct {
		name string
		mute muteScope
	}{
		{"leader-answers", muteLeaderAnswers},
		{"every-node-answers", muteEveryNodeAnswersOnly},
	}
	for _, f := range faults {
		serves := 0
		for seed := uint64(1); seed <= seeds; seed++ {
			out := runReachRecovery(t, seed, p, f.mute, featureOff(), reachRecoverBudget)
			if out.ceded {
				t.Fatalf("baseline %s seed %d: the leader left office in %d rounds with the feature off, so a role change under this fault is not the signal's alone",
					f.name, seed, out.cedeRound)
			}
			if out.served {
				serves++
			}
			if out.droppedByEdge == 0 {
				t.Fatalf("baseline %s seed %d: no client edge dropped a frame; the mute was a no-op", f.name, seed)
			}
		}
		t.Logf("baseline %s with the feature off: seeds=%d cedes=0 serves=%d heldRounds=%d", f.name, seeds, serves, reachRecoverBudget)
	}
}

// TestClusterDST_ClientAimPlacementIsMeasured sets what the grid could only
// observe. In the grid, whether the leader sat at the member the client's first
// attempt targets was decided by the election, so a cede rate that splits along it
// is a correlation across seeds that differ in everything else too. Here the
// client's view of the group is rotated so the leader sits at that first target,
// and then so it does not, on the SAME seeds, with the same fault and the same
// budget. Nothing else moves.
//
// The fault is every node's answers dropped, because that is the one where no
// redirect can reach the client, so the first attempt fixes the aim for the whole
// run and placement is the entire difference. Under the fault where only the
// leader is mute a peer's redirect arrives and aims the client back at the leader
// whatever the order was, which is why that one is not run here. The router's
// rotation is off for the same reason the grid turns it off, and carries the same
// warning: that pairing is an instrument, not a deployment.
//
// Same discipline as the grid above on what is asserted and what is only counted.
func TestClusterDST_ClientAimPlacementIsMeasured(t *testing.T) {
	seeds := reachMeasurementSeeds(t)
	p := defaultReachParams()
	arms := []struct {
		name     string
		leaderAt int
	}{
		{"leader placed at the first target", 0},
		{"leader placed off the first target", 1},
	}
	for _, a := range arms {
		cedes, sameTermCedes, serves, worstCede := 0, 0, 0, 0
		for seed := uint64(1); seed <= seeds; seed++ {
			out := runReachRecoveryAt(t, seed, p, muteEveryNodeAnswersOnly, reachLayers{signal: true}, a.leaderAt, reachRecoverBudget)
			if out.ceded {
				cedes++
				if out.sameTermCede {
					sameTermCedes++
				}
				if out.cedeRound > worstCede {
					worstCede = out.cedeRound
				}
			}
			if out.served {
				serves++
			}
			if out.ceded && !out.sameTermCede {
				t.Fatalf("placement %s seed %d: the leader left office without keeping its term", a.name, seed)
			}
			if out.served {
				t.Fatalf("placement %s seed %d: the client was served while every node's answers were dropped", a.name, seed)
			}
			if out.droppedByEdge == 0 {
				t.Fatalf("placement %s seed %d: no client edge dropped a frame; the mute was a no-op", a.name, seed)
			}
			t.Logf("placement %s seed %d: leader=%d firstTarget=%d ceded=%v sameTerm=%v cedeRound=%d reWins=%d droppedByEdge=%d",
				a.name, seed, out.leader, out.firstTarget, out.ceded, out.sameTermCede, out.cedeRound, out.reWins, out.droppedByEdge)
		}
		t.Logf("placement %s: seeds=%d cedes=%d sameTermCedes=%d serves=%d worstCedeRound=%d budget=%d",
			a.name, seeds, cedes, sameTermCedes, serves, worstCede, reachRecoverBudget)
	}
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
// zero) and the one-node-cut-off cede-and-serve rate (which must be complete) and
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
					if measureHealthyCedes(t, s, p, featureOn()) {
						falseCedes++
					}
					out := runReachRecovery(t, s, p, muteLeaderBothWays, featureOn(), 2000)
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
