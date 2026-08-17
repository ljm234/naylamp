package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// This file defends the STRONG read claim of 3.5, and names which one on
// purpose, because the choice decides what the seal above it may assert.
//
// The two claims are not the same, and the three places that state them are
// named rather than numbered, for the reason at the bottom of this comment.
// The invariant scope note of Subphase 3.5 promises "linealizabilidad
// read-your-writes"; the Validation Criteria and the Objective of that same
// subphase promise the strong one, "linealizabilidad de ReadIndex contra el
// log" and "toda lectura ReadIndex refleja un prefijo >= su indice". All three
// are in NAYLAMP_PHASE_3.md. checkReadYourWrite in cluster_dst_test.go already
// carries the scope note, and carries it honestly: it reads the client's own
// write back the instant that write acked. What it cannot carry is the
// Validation Criteria, and the reason
// is structural rather than a matter of degree. Replace beginClientSearch
// (node.go) with an immediate answer out of the leader's local index, with no
// majority confirmation round, no applied >= R barrier and no parking, and
// read-your-writes still holds by construction, because the leader's own state
// already contains the write that same client just made. The seeded sweep stays
// green over 60 seeds, 118 reads checked. The strong claim is broken and nothing
// turns red. That gap is what this file closes.
//
// WHY BY NAME AND NOT BY LINE NUMBER, corrected on 17 August 2026. This comment
// cited NAYLAMP_PHASE_3.md by line, and four of its five anchors had the
// document name elided down to a bare ":415", which resolves to nothing at all.
// That document LIVES OUTSIDE THIS REPOSITORY, in the workspace directory
// beside it, so a clone does not carry it and a line number gives a reader with
// a fresh checkout no way to look anything up. Anyone who cannot find the names
// above is missing the workspace and not reading a broken reference. The rule,
// with the rest of its reasoning, is in the hard rule of DEFER-035.
//
// The property, stated so it can fail: A LEADER THAT CANNOT CONFIRM A MAJORITY
// MUST SERVE NO READ. The round is not a formality. At the instant it is asked
// for a read, a leader cannot tell from local state alone whether it has already
// been deposed; only a majority answering the round can tell it. Serving before
// that answer is what makes a read non-linearizable, whatever the served bytes
// happen to be.
//
// How long that window lasts here, stated exactly, because an earlier draft of
// this file assumed otherwise and passed for the wrong reason.
// raft.DefaultOptions leaves CheckQuorum off (raft.go:72-75), but OpenNode turns
// it ON for every node (node.go:183), so an isolated leader is never stranded
// believing it leads: it demotes itself once checkQuorumWindows windows pass with
// no majority answering.
//
// The bound from the cut is 30 ticks, and NOT the 2 x ElectionTicks = 20 that the
// window count alone suggests. The extra window is deliberate rather than slack.
// Tick reads quorumActive() BEFORE sweepActive() (raft.go:377-378), so the window
// straddling the cut is still scored against the active set the pre-cut
// heartbeats filled, and it resets failedWindows instead of counting against it;
// that ordering is what keeps a healthy leader from being misread as quorumless
// on the first tick of a window. The cost is the remainder of the straddling
// window plus two full ones, so 3 x ElectionTicks. Measured on this scenario,
// tick by tick from the cut: still leader through 29, follower at 30.
//
// The window is therefore BOUNDED, which is a property of this system worth
// stating plainly, and it is not empty, which is what matters here. The scenario
// issues its read inside that window,
// with the node still reporting RoleLeader and every peer already unreachable,
// then drives far past the demotion. A correct node answers nothing for that
// request, ever: the round dies on the cut, the search stays parked, and the
// demotion flushes it as StatusNotLeader. A node that answers from local state
// answers StatusOK on the first pass.
//
// Why the sweep cannot host this. runClusterSeed guards every read probe with
// shardImpaired and sends no writes to an impaired shard, so the one window in
// which a shard's leader is cut off from its own followers is the window the
// sweep declines to probe. That guard is correct for what the sweep is, since an
// unimpaired-shard read that does not complete asserts nothing. It also means no
// strengthening of the sweep reaches this state, so the state gets its own
// scenario, driven frame by frame.
//
// The non-vacuity witness, which carries more weight than usual because the
// primary assertion is that something does NOT happen. A read path that answered
// nothing ever would pass it for entirely the wrong reason. So the majority side
// goes on committing while the isolated node refuses, and after the heal the same
// query over the same client wire must come back OK and reflect BOTH records.
// Only then is the refusal a refusal rather than a dead path.

// The two record ids. staleReadSeedID lands before the cut and reaches every
// replica. staleReadFreshID is committed by the majority while the old leader is
// isolated, so it witnesses that the cluster kept serving throughout and pins how
// far the isolated node's local index had diverged.
const (
	staleReadSeedID  uint64 = 3
	staleReadFreshID uint64 = 9
)

// staleReadDemotionBound bounds how long the isolated node may keep believing it
// leads. The demotion measures at tick 30 from the cut, for the reason the header
// works out; this is twice that, so it is a bound rather than a fit to the
// current constants, and it still fails in a few ticks if CheckQuorum is off.
const staleReadDemotionBound = 60

// staleReadNet drives three nodes by hand over a set of directed edges the test
// owns. It is a node-level driver rather than a SimNet-and-router one because the
// property under test is what ONE NAMED node does when it cannot reach a
// majority: a router that redirected the client to a reachable leader would
// answer correctly and hide the node whose behavior is in question.
type staleReadNet struct {
	t       *testing.T
	nodes   map[cluster.NodeID]*Node
	ids     []cluster.NodeID
	blocked map[[2]cluster.NodeID]bool
	resps   []ClientResponse
}

// cut blocks an edge in both directions. A one-way cut would leave the isolated
// node hearing a higher term and stepping down at once, which is a different
// scenario from the one under test.
func (d *staleReadNet) cut(a, b cluster.NodeID) {
	d.blocked[[2]cluster.NodeID{a, b}] = true
	d.blocked[[2]cluster.NodeID{b, a}] = true
}

// healAll clears every cut edge.
func (d *staleReadNet) healAll() { clear(d.blocked) }

// deliver drains a queue of frames the way node_test.go's pump does, with the two
// differences the scenario needs: a frame on a cut edge is swallowed, and a frame
// addressed to the fake client is decoded into resps rather than routed, since no
// node carries that id.
func (d *staleReadNet) deliver(seed [][]byte, budget int) {
	d.t.Helper()
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			d.t.Fatalf("decode envelope: %v", err)
		}
		if d.blocked[[2]cluster.NodeID{env.From, env.To}] {
			continue
		}
		if env.To == clientID {
			if env.Kind == ClientRespKind {
				resp, derr := DecodeClientResponse(env)
				if derr != nil {
					d.t.Fatalf("decode response: %v", derr)
				}
				d.resps = append(d.resps, resp)
			}
			continue
		}
		dst, ok := d.nodes[env.To]
		if !ok {
			continue
		}
		out, herr := dst.HandleMessage(data)
		if herr != nil {
			d.t.Fatalf("node %d handle: %v", env.To, herr)
		}
		queue = append(queue, out...)
	}
}

// advance ticks every node once in id order and drains what falls out, rounds
// times. It is the scenario's only clock: no wall time anywhere.
func (d *staleReadNet) advance(rounds int) {
	d.t.Helper()
	for r := 0; r < rounds; r++ {
		var msgs [][]byte
		for _, id := range d.ids {
			out, err := d.nodes[id].Tick()
			if err != nil {
				d.t.Fatalf("node %d tick: %v", id, err)
			}
			msgs = append(msgs, out...)
		}
		d.deliver(msgs, 4000)
	}
}

// okSearch returns the first StatusOK response siphoned for reqID, and whether
// one arrived at all.
func (d *staleReadNet) okSearch(reqID uint64) (ClientResponse, bool) {
	for _, r := range d.resps {
		if r.ReqID == reqID && r.Status == StatusOK {
			return r, true
		}
	}
	return ClientResponse{}, false
}

// respFor returns the first response of ANY status siphoned for reqID. It is how
// the bounded-refusal check tells a request that was answered and told to retry
// from one that was left hanging.
func (d *staleReadNet) respFor(reqID uint64) (ClientResponse, bool) {
	for _, r := range d.resps {
		if r.ReqID == reqID {
			return r, true
		}
	}
	return ClientResponse{}, false
}

// openedRound reports whether an outbound batch carries an append stamped with a
// read context, which is the observable proof that a search registered a
// confirmation round instead of being refused before one existed. It tolerates
// frames that are not raft messages, because a client answer rides in the same
// batch whenever the read path replies directly.
func (d *staleReadNet) openedRound(frames [][]byte) bool {
	for _, frame := range frames {
		m, err := raft.DecodeMsg(frame)
		if err != nil {
			continue
		}
		if m.Kind == raft.MsgApp && m.ReadCtx != 0 {
			return true
		}
	}
	return false
}

// holds reports whether a node's local index returns id as the nearest neighbor
// of id's own vector. vecFor is injective and self-separated, so id sits at
// distance zero to its own vector and comes back at rank 0 whenever it is live.
func (d *staleReadNet) holds(node cluster.NodeID, id uint64) bool {
	d.t.Helper()
	got, err := d.nodes[node].Search(vecFor(id), 1)
	if err != nil {
		d.t.Fatalf("node %d local search for %d: %v", node, id, err)
	}
	return len(got) == 1 && got[0].ID == id
}

func TestClusterDST_IsolatedLeaderServesNoRead(t *testing.T) {
	// seed is a runtime var so the per-node mix wraps mod 2^64 exactly as the
	// sealed sweep's does; a const would overflow at compile time.
	var seed uint64 = 0x5A1EDEAD
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}

	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3,
			testRNG(seed*0x9E3779B97F4A7C15+uint64(id)*0x100000001B3), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		nodes[id] = n
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()

	d := &staleReadNet{t: t, nodes: nodes, ids: ids, blocked: map[[2]cluster.NodeID]bool{}}

	// (1) Elect on an undisturbed fabric and seed one record everywhere, so the
	// isolated node below holds real data and an answer from its local state
	// would look perfectly healthy from the outside.
	oldLeader := cluster.None
	for r := 0; r < 400 && oldLeader == cluster.None; r++ {
		d.advance(1)
		oldLeader = leaderOf(nodes, ids)
	}
	if oldLeader == cluster.None {
		t.Fatalf("no leader elected on the undisturbed fabric")
	}
	_, out, err := nodes[oldLeader].Upsert(staleReadSeedID, vecFor(staleReadSeedID))
	if err != nil {
		t.Fatalf("seed upsert on leader %d: %v", oldLeader, err)
	}
	d.deliver(out, 4000)
	d.advance(20)
	for _, id := range ids {
		if !d.holds(id, staleReadSeedID) {
			t.Fatalf("node %d does not hold the seeded record before the cut", id)
		}
	}

	// (2) Cut the leader off from both followers, both directions. No tick runs
	// between the cut and the read below, so the node is still in office and
	// already unreachable: exactly the window the round exists to cover.
	majority := make([]cluster.NodeID, 0, len(ids)-1)
	for _, id := range ids {
		if id == oldLeader {
			continue
		}
		d.cut(oldLeader, id)
		majority = append(majority, id)
	}
	if nodes[oldLeader].Role() != raft.RoleLeader {
		t.Fatalf("node %d is not in office at the cut, so the scenario never enters its window", oldLeader)
	}

	// (3) The assertion. The read registers while the node still leads and can
	// reach no one. Its round counts one ack, its own, and quorum is two.
	const isolatedReqID uint64 = 1001
	d.resps = nil
	out, err = nodes[oldLeader].HandleMessage(mustEncodeReq(t, clientID, oldLeader,
		ClientRequest{Op: ReqSearch, ReqID: isolatedReqID, K: 1, Vec: vecFor(staleReadSeedID)}))
	if err != nil {
		t.Fatalf("isolated leader %d handling client search: %v", oldLeader, err)
	}
	d.deliver(out, 4000)
	if got, ok := d.okSearch(isolatedReqID); ok {
		t.Fatalf("node %d answered a client search StatusOK on the first pass while cut off from every peer: no majority can have confirmed the read, so the answer is not linearizable. neighbors=%+v", oldLeader, got.Neighbors)
	}
	// The silence has to be a refusal to COMPLETE, not a refusal to start, or it
	// says nothing about quorum. A search rejected before any round exists, on a
	// dimension mismatch or a k of zero, answers StatusInvalidArgument and stamps
	// no append, and would satisfy the check above for a reason that has nothing to
	// do with the majority.
	if !d.openedRound(out) {
		t.Fatalf("node %d emitted no append stamped with a read context, so its search never opened a confirmation round and the silence above is not about quorum (%d frames out)", oldLeader, len(out))
	}

	// The refusal must also be BOUNDED, which is a SEPARATE property from the
	// refusal itself and needs its own assertion: a node that simply never answers
	// anything also serves no read, and would satisfy every check above while
	// leaving the client hung forever. What bounds it is CheckQuorum, turned on at
	// node.go:183, and nothing else in this tree pins that line. Flipping it to
	// false leaves the whole suite green, this test included, with the isolated
	// node holding office for the full budget and the client never answered. So the
	// two facts the header works out are asserted here rather than only narrated:
	// the node leaves office, and the parked request comes back answered.
	demoteTick, answerTick := -1, -1
	for tick := 1; tick <= staleReadDemotionBound; tick++ {
		d.advance(1)
		if demoteTick < 0 && nodes[oldLeader].Role() != raft.RoleLeader {
			demoteTick = tick
		}
		if _, answered := d.respFor(isolatedReqID); answerTick < 0 && answered {
			answerTick = tick
		}
	}
	if demoteTick < 0 {
		t.Fatalf("node %d still held office %d ticks after losing every peer, so its refusal is an unbounded hang rather than a demotion: CheckQuorum (node.go:183) is what should have ended the term", oldLeader, staleReadDemotionBound)
	}
	answer, answered := d.respFor(isolatedReqID)
	if !answered {
		t.Fatalf("node %d never answered the parked search within %d ticks: a client left hanging is not the same as one told to retry, and the demotion at tick %d should have flushed it", oldLeader, staleReadDemotionBound, demoteTick)
	}
	if answer.Status != StatusNotLeader {
		t.Fatalf("node %d answered the parked search with status %v, want StatusNotLeader: the demotion flush is the only sound way this request can end", oldLeader, answer.Status)
	}
	if answerTick < demoteTick {
		t.Fatalf("node %d answered at tick %d but only left office at tick %d, so the answer did not come from the demotion flush", oldLeader, answerTick, demoteTick)
	}

	// Then drive far past all of it, so the refusal is shown to hold for the whole
	// life of the request and not merely until the flush.
	d.advance(600)
	if got, ok := d.okSearch(isolatedReqID); ok {
		t.Fatalf("node %d answered a client search StatusOK though its read round was never confirmed by a majority: neighbors=%+v", oldLeader, got.Neighbors)
	}

	// (4) The majority kept serving throughout, which is what makes the refusal
	// above a refusal by one node rather than the silence of a dead cluster.
	newLeader := leaderOf(nodes, majority)
	if newLeader == cluster.None {
		t.Fatalf("the majority side never elected while the old leader was cut off")
	}
	_, out, err = nodes[newLeader].Upsert(staleReadFreshID, vecFor(staleReadFreshID))
	if err != nil {
		t.Fatalf("fresh upsert on new leader %d: %v", newLeader, err)
	}
	d.deliver(out, 4000)
	d.advance(20)
	for _, id := range majority {
		if !d.holds(id, staleReadFreshID) {
			t.Fatalf("majority node %d does not hold the record committed during the cut", id)
		}
	}
	if d.holds(oldLeader, staleReadFreshID) {
		t.Fatalf("node %d holds the record committed during the cut, so it was never isolated", oldLeader)
	}

	// (5) Non-vacuity. Heal, then require the same query over the same client wire
	// to come back OK and to reflect BOTH records. A read path broken toward
	// refusing too much, one that answers nothing on any path, passes (3) and
	// fails here, which is why this arm runs.
	d.healAll()
	d.advance(400)

	// The heal has to DO something, or this arm would pass with the cut still in
	// place and would not be about healing at all: the query below goes to
	// whichever node leads, which is always a majority node whose round closes
	// with its one uncut peer. Deleting the heal outright used to leave this arm
	// green. The observable consequence that only a heal can produce is the ex
	// leader catching up on the record it was cut off from, so that is what is
	// required here.
	if !d.holds(oldLeader, staleReadFreshID) {
		t.Fatalf("node %d did not catch up on record %d after the heal, so the heal changed nothing this arm can see", oldLeader, staleReadFreshID)
	}

	lead := leaderOf(nodes, ids)
	if lead == cluster.None {
		t.Fatalf("no leader after the heal")
	}
	const healedReqID uint64 = 1002
	d.resps = nil
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead,
		ClientRequest{Op: ReqSearch, ReqID: healedReqID, K: 2, Vec: vecFor(staleReadFreshID)}))
	if err != nil {
		t.Fatalf("leader %d handling healed client search: %v", lead, err)
	}
	d.deliver(out, 4000)
	d.advance(400)
	got, ok := d.okSearch(healedReqID)
	if !ok {
		t.Fatalf("no read completed after the heal, so the refusal in (3) attests nothing: this client wire never answers OK at all (responses seen: %+v)", d.resps)
	}
	seen := map[uint64]bool{}
	for _, nb := range got.Neighbors {
		seen[nb.ID] = true
	}
	if !seen[staleReadSeedID] || !seen[staleReadFreshID] {
		t.Fatalf("the healed read does not reflect both committed records %d and %d: %+v",
			staleReadSeedID, staleReadFreshID, got.Neighbors)
	}
}
