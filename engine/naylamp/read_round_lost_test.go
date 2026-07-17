package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// This file documents the read-round asymmetry and pins its recovery.
//
// The asymmetry: raft.RequestRead is the ONLY point that stamps a nonzero
// ReadCtx onto an append round. Heartbeats out of Tick and the repair resends
// out of handleAppResp go out with ReadCtx zero, and a follower echoes the
// ReadCtx of exactly the append it answers, so only an answer to the stamped
// frame itself can confirm the round. A write is self-repairing, every later
// MsgApp re-offers the entries until matchIndex moves; a read round is not:
// lose the one stamped frame toward the only follower able to confirm it and
// the round is dead, its context sits in pendingReads unanswered and the
// search riding on it stays parked on the leader.
//
// Why that does not break correctness: recovery is the CLIENT layer's job.
// The router re-emits an attempt that has gone unanswered for
// retransmitTimeout ticks (DEFER-011) as a FRESH request, and the node
// registers a FRESH read round for it; the production client above the
// router (naylampd) re-emits on a rotated view every reemitInterval on top
// of that. The test below kills exactly one read round with a targeted drop
// and shows the re-emission completing the search within its budget, which
// is the documented contract: the server does not retransmit read rounds,
// the client recovers them.
//
// This test is DOCUMENTARY and green. It is not the reproducer of the
// remaining real-infra Search hang, which is a transport bug pinned red by
// the TCP tests under engine/cluster. An optional server-side fix,
// re-stamping pending read contexts onto heartbeat appends so a lost round
// heals within one heartbeat interval with no client involved, is recorded
// as a DEFER and deliberately not built here: it would buy recovery latency,
// not correctness, at the price of touching the sealed raft core.

// dropStampedAppendTransport swallows exactly one MsgApp carrying a nonzero
// ReadCtx toward one destination and forwards everything else untouched. The
// scenario cuts the other follower off with a partition, so this single drop
// kills the whole read round. dropped witnesses the kill and stampedAfter
// witnesses the next round's stamped frame crossing later, so a pass cannot
// be vacuous. While dropTo is None the decorator is passive, which keeps the
// election and the seeding write on an undisturbed path.
type dropStampedAppendTransport struct {
	inner cluster.Transport

	dropTo       cluster.NodeID // armed destination; None keeps the decorator passive
	dropped      int            // stamped appends swallowed; the scenario expects exactly one
	stampedAfter int            // stamped appends forwarded to dropTo after the kill
}

// Send inspects raft appends toward the armed destination and swallows the
// first one stamped with a read context. The inspection is read-only and the
// swallowed frame is the same one on every replay, so the fabric's seeded
// history stays a pure function of the seed; frames that are not raft
// appends are forwarded untouched.
func (p *dropStampedAppendTransport) Send(to cluster.NodeID, data []byte) error {
	if p.dropTo != cluster.None && to == p.dropTo {
		if env, err := cluster.DecodeMessage(data); err == nil && env.Kind == raft.EnvelopeKind {
			if m, merr := raft.DecodeMsgEnvelope(env); merr == nil && m.Kind == raft.MsgApp && m.ReadCtx != 0 {
				if p.dropped == 0 {
					p.dropped++
					return nil // the round's one stamped frame dies here
				}
				p.stampedAfter++
			}
		}
	}
	return p.inner.Send(to, data)
}

// Close releases the wrapped endpoint.
func (p *dropStampedAppendTransport) Close() error { return p.inner.Close() }

// readRoundSeedID is the vector seeded on the healthy path so the search has
// a neighbor to return.
const readRoundSeedID uint64 = 7

// readRoundLostOutcome is one scenario run's observable result, compared
// across the double replay. rounds is how many poll rounds the search took,
// which the judging test uses to prove the completion waited for the
// client-layer re-emission window.
type readRoundLostOutcome struct {
	leader        cluster.NodeID
	healthy       cluster.NodeID
	done          bool
	status        ClientStatus
	exhausted     bool
	index         uint64
	neighborCount int
	topNeighborID uint64
	rounds        int
	dropped       int
	stampedAfter  int
}

// runReadRoundLostScenario drives one full scenario: elect a single-shard
// leader, seed one vector on the healthy path, cut the leader's edge toward
// one follower, arm the targeted drop toward the other, then push one client
// Search through the router and poll it for the client budget.
// Infrastructure failures fatal immediately; the client outcome is returned
// for the caller to judge, so the replay can run twice.
func runReadRoundLostScenario(t *testing.T) readRoundLostOutcome {
	t.Helper()

	// seed is a runtime var so the per-node mix wraps mod 2^64 exactly as the
	// sealed sweep's does; a const would overflow at compile time.
	var seed uint64 = 0x4EAD

	// Latency jitters so deliveries reorder, but nothing drops or duplicates
	// at random: the targeted drop must be the only loss in the run.
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 4})

	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	shard := []cluster.NodeID{1, 2, 3}

	hosts := map[cluster.NodeID]*Host{}
	drops := map[cluster.NodeID]*dropStampedAppendTransport{}
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

	nodeSeed := func(id cluster.NodeID) uint64 {
		return seed*0x9E3779B97F4A7C15 + uint64(id)*0x100000001B3
	}
	for _, id := range shard {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(nodeSeed(id)), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		drop := &dropStampedAppendTransport{}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(hid, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", hid, terr)
			}
			drop.inner = tr
			return drop
		})
		if err != nil {
			t.Fatalf("host %d: %v", id, err)
		}
		drops[id] = drop
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

	// advance is the SilentTarget round: every node ticks, the fabric moves,
	// and the router host follows the fabric clock so its retransmit timer,
	// the recovery under documentation, is live.
	advance := func() {
		for _, id := range shard {
			if terr := hosts[id].Tick(); terr != nil {
				t.Fatalf("host %d tick: %v", id, terr)
			}
		}
		net.Tick()
		if terr := rh.Tick(net.Clock().Now()); terr != nil {
			t.Fatalf("router host tick: %v", terr)
		}
	}
	drivePoll := func(opID uint64, budget int) (RouteResult, bool, int) {
		for i := 1; i <= budget; i++ {
			advance()
			if res, ok := rh.Result(opID); ok {
				return res, true, i
			}
		}
		return RouteResult{}, false, budget
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

	// Seed one vector on the healthy path, before any fault exists: its
	// completion is infrastructure, not the outcome under test.
	seedOp, err := rh.Upsert(readRoundSeedID, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("seed upsert: %v", err)
	}
	if res, ok, _ := drivePoll(seedOp, 300); !ok || res.Status != StatusOK || res.Index == 0 {
		t.Fatalf("seed upsert did not complete on the healthy path: done=%v %+v", ok, res)
	}

	// victim is the follower the partition cuts off; healthy is the only
	// follower left able to answer a read round, which makes it the one
	// destination whose stamped frame is worth killing.
	victim, healthy := cluster.None, cluster.None
	for _, id := range shard {
		if id == leader {
			continue
		}
		if victim == cluster.None {
			victim = id
			continue
		}
		healthy = id
	}

	// Outbound only, the same shape as the blocked-sender scenario: the
	// leader keeps hearing everyone, keeps its write quorum through healthy,
	// and pre-vote keeps victim from deposing it. The read round's fate now
	// hinges entirely on the one stamped frame toward healthy. Nothing else
	// on this edge carries a ReadCtx: the first stamped frame the decorator
	// sees is our search's round, because RequestRead is the only stamper
	// and no earlier read exists in the schedule.
	net.Partition(leader, victim)
	drops[leader].dropTo = healthy

	// The client: exactly ONE Search through the router. The router itself
	// re-emits an unanswered attempt after retransmitTimeout ticks, which is
	// precisely the client-layer recovery under documentation, so the budget
	// spans several of those windows plus the redirect and resolution paths.
	const clientBudget = 240
	opID, err := rh.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("router host search: %v", err)
	}
	res, done, rounds := drivePoll(opID, clientBudget)

	out := readRoundLostOutcome{
		leader:       leader,
		healthy:      healthy,
		done:         done,
		status:       res.Status,
		exhausted:    res.Exhausted,
		index:        res.Index,
		rounds:       rounds,
		dropped:      drops[leader].dropped,
		stampedAfter: drops[leader].stampedAfter,
	}
	out.neighborCount = len(res.Neighbors)
	if out.neighborCount > 0 {
		out.topNeighborID = res.Neighbors[0].ID
	}
	return out
}

// TestClusterDST_ReadRoundLostRecoversByClientResend kills exactly one read
// round, the stamped append toward the only follower able to confirm it, and
// requires the client Search to complete anyway through the router's
// re-emission. The scenario runs twice on one seed, the replay discipline,
// so the outcome is pinned as deterministic before it is judged. The rounds
// bound then proves the completion cannot have come from the first read
// round: the server never retransmits a read round on its own, so nothing
// can resolve the search before the retransmit window opens, which is the
// asymmetry under documentation. If the completion assertions here ever
// fail, the client re-emission does NOT cover a lost read round and the
// asymmetry is a live bug, not a documented non-issue: treat that as a new
// finding, not a flake.
func TestClusterDST_ReadRoundLostRecoversByClientResend(t *testing.T) {
	first := runReadRoundLostScenario(t)
	second := runReadRoundLostScenario(t)

	if first != second {
		t.Fatalf("replay diverged on one seed:\nfirst:  %+v\nsecond: %+v", first, second)
	}
	if first.dropped != 1 {
		t.Fatalf("the targeted drop swallowed %d stamped appends, want exactly 1: the read round was never lost, so the run proves nothing", first.dropped)
	}
	if first.stampedAfter == 0 {
		t.Fatalf("no later stamped append crossed toward the healthy follower: the client re-emission never raised a fresh read round, outcome %+v", first)
	}
	if !first.done || first.status != StatusOK || first.exhausted {
		t.Fatalf("client Search did not recover from the lost read round: done=%v status=%v exhausted=%v after %d rounds (leader %d); the re-emission was expected to raise a fresh round and complete",
			first.done, first.status, first.exhausted, first.rounds, first.leader)
	}
	if first.index != 0 {
		t.Fatalf("a search resolves with a zero index, got %d: this can only be a crossed write ack", first.index)
	}
	if first.neighborCount != 1 || first.topNeighborID != readRoundSeedID {
		t.Fatalf("search returned the wrong data: %d neighbors, top id %d, want exactly vector %d seeded on the healthy path",
			first.neighborCount, first.topNeighborID, readRoundSeedID)
	}
	if first.rounds <= int(retransmitTimeout) {
		t.Fatalf("search completed in %d rounds, inside the first retransmit window of %d ticks: the first read round must have survived, so the drop missed and the scenario never exercised the asymmetry",
			first.rounds, retransmitTimeout)
	}
}
