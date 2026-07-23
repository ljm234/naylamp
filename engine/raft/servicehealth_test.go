package raft

import (
	"testing"

	"naylamp/engine/cluster"
)

// This file is the deterministic unit net for the service-health signal: a
// leader that goes mute toward clients while a peer keeps serving them steps
// down on its own, and the cases below exercise that mechanism and its guards.
// They drive the pure core directly, feeding a peer's MsgAppResp with its reach
// bit set and controlling the leader's own bit through NoteClientReached, so the
// window arithmetic is observed with no fabric in the way.

// serviceHealthOptions is DefaultOptions with the signal on and CheckQuorum off,
// so a step-down in these cases can only be the reach signal, never quorum loss.
func serviceHealthOptions() Options {
	opts := DefaultOptions()
	opts.ServiceHealth = true
	return opts
}

// driveToLeader brings a fresh node to office through a real pre-vote and vote
// round, so becomeLeader runs and its reach state is seeded exactly as in
// production.
func driveToLeader(t *testing.T, r *Raft) {
	t.Helper()
	for i := 0; i < 200 && r.prevotes == nil; i++ {
		r.Tick()
	}
	if r.prevotes == nil {
		t.Fatalf("node never entered a pre-vote round")
	}
	r.Step(Message{Kind: MsgPreVoteResp, From: 2, To: r.id, Term: r.Term() + 1, Granted: true})
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: r.id, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("node did not take office: role=%v", r.Role())
	}
}

// peerReached feeds one MsgAppResp from peer 2 carrying its reach bit, the
// peer-reached half of the cede condition, at the leader's current term.
func peerReached(r *Raft) {
	r.Step(Message{Kind: MsgAppResp, From: 2, To: r.id, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), Reached: true})
}

// TestRaft_ServiceHealth_MuteLeaderCedes is the baseline: a leader that never
// frames a client answer while a peer reports reaching clients steps down by
// itself at the SAME term with its vote preserved and no known leader, and the
// ceding tick emits nothing so no late heartbeat re-pins a follower's lease.
func TestRaft_ServiceHealth_MuteLeaderCedes(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(1), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks
	termBefore := r.Term()
	voteBefore := r.hs.Vote

	ceded := false
	for i := 0; i < 6*et && !ceded; i++ {
		peerReached(r) // a peer reached a client; the leader itself never reaches one, so it stays mute
		rd := r.Tick()
		if r.Role() != RoleLeader {
			ceded = true
			if len(rd.Msgs) != 0 {
				t.Fatalf("the ceding tick emitted %d messages, want none", len(rd.Msgs))
			}
		}
	}
	if !ceded {
		t.Fatalf("mute leader never ceded within %d ticks", 6*et)
	}
	if r.Term() != termBefore {
		t.Fatalf("term inflated on cede: %d -> %d", termBefore, r.Term())
	}
	if r.hs.Vote != voteBefore {
		t.Fatalf("vote not preserved on cede: %d -> %d", voteBefore, r.hs.Vote)
	}
	if r.Leader() != cluster.None {
		t.Fatalf("cede left a known leader: %d", r.Leader())
	}
}

// TestRaft_ServiceHealth_HealthyLeaderHolds is the negative control: a leader
// that keeps answering clients itself never cedes, even while a peer also
// reports reaching them. The leader's own bit clears the cede condition every
// window.
func TestRaft_ServiceHealth_HealthyLeaderHolds(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(3), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks
	termBefore := r.Term()

	for i := 0; i < 40*et; i++ {
		r.NoteClientReached() // the leader served a client this window
		peerReached(r)
		r.Tick()
		if r.Role() != RoleLeader || r.Term() != termBefore {
			t.Fatalf("healthy leader did not hold office: role=%v term=%d (was leader at %d)", r.Role(), r.Term(), termBefore)
		}
		if r.reachFailedWindows != 0 {
			t.Fatalf("healthy leader accumulated %d cede windows while serving clients", r.reachFailedWindows)
		}
	}
}

// TestRaft_ServiceHealth_QuietPeersHoldLeader pins the empty-set guard: with no
// peer reporting a reach at all, the cede condition is never met and the leader
// holds indefinitely, so the signal restricts only on positive peer evidence.
func TestRaft_ServiceHealth_QuietPeersHoldLeader(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(5), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks
	termBefore := r.Term()

	for i := 0; i < 40*et; i++ {
		// A peer answers with its reach bit CLEAR: it exchanged with no client.
		r.Step(Message{Kind: MsgAppResp, From: 2, To: r.id, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})
		r.Tick()
		if r.Role() != RoleLeader || r.Term() != termBefore {
			t.Fatalf("leader ceded with no peer reporting a reach: role=%v", r.Role())
		}
	}
}

// TestRaft_ServiceHealth_HysteresisNeedsTwoWindows pins the threshold: one full
// window of the cede condition raises the counter but does not step the leader
// down; the second window does. A one-window check would misread the healthy
// first-contact case, which this hysteresis absorbs.
func TestRaft_ServiceHealth_HysteresisNeedsTwoWindows(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(7), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks

	// One window of a reaching peer and a mute leader: the counter climbs to one, office held.
	for i := 0; i < et; i++ {
		peerReached(r)
		r.Tick()
	}
	if r.Role() != RoleLeader {
		t.Fatalf("leader ceded after a single window")
	}
	if r.reachFailedWindows != 1 {
		t.Fatalf("after one window reachFailedWindows = %d, want 1", r.reachFailedWindows)
	}

	// A second window trips the step-down.
	ceded := false
	for i := 0; i < et && !ceded; i++ {
		peerReached(r)
		r.Tick()
		if r.Role() != RoleLeader {
			ceded = true
		}
	}
	if !ceded {
		t.Fatalf("leader did not cede after the second window")
	}
}

// TestRaft_ServiceHealth_ThresholdOfOneCedesInOneWindow pins the threshold knob,
// the mutation guard mirroring the CheckQuorum k=1 case: forced to a single
// window, the leader cedes after ONE window of the cede condition, which is
// exactly the transient first-contact false positive the default two-window
// hysteresis exists to suppress. It is here to fail loudly if the threshold is
// ever silently forced to one.
func TestRaft_ServiceHealth_ThresholdOfOneCedesInOneWindow(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	opts := serviceHealthOptions()
	opts.ServiceHealthWindows = 1
	r, err := New(1, cfg, testRNG(17), opts)
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if r.serviceHealthWindows != 1 {
		t.Fatalf("ServiceHealthWindows override not applied: got %d", r.serviceHealthWindows)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks

	ceded := false
	for i := 0; i < et+2 && !ceded; i++ {
		peerReached(r)
		r.Tick()
		if r.Role() != RoleLeader {
			ceded = true
		}
	}
	if !ceded {
		t.Fatalf("with a one-window threshold the leader must cede after a single window, but it held")
	}
}

// TestRaft_ServiceHealth_FlagOffLeaderHolds confirms the option gates the
// behavior: with ServiceHealth off, the same mute pattern never cedes, so a
// build that leaves the option at its zero value is byte-for-byte the old one.
func TestRaft_ServiceHealth_FlagOffLeaderHolds(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(9), DefaultOptions()) // ServiceHealth and CheckQuorum both off
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	driveToLeader(t, r)
	et := r.opts.ElectionTicks
	termBefore := r.Term()

	for i := 0; i < 40*et; i++ {
		r.NoteClientReached() // a no-op while the option is off
		peerReached(r)        // Reached is ignored: reachedClient stays nil
		r.Tick()
		if r.Role() != RoleLeader || r.Term() != termBefore {
			t.Fatalf("with the option off a mute leader must hold office, but it ceded to %v", r.Role())
		}
	}
	if r.reachedClient != nil {
		t.Fatalf("the option is off but a reach set was allocated: %v", r.reachedClient)
	}
}

// TestRaft_ServiceHealth_FollowerStampsOwnBit checks the stamping path in
// isolation: a follower that framed a client answer this window sets the bit on
// its next MsgAppResp, one that has not does not, and with the option off the
// bit is never set even after NoteClientReached.
func TestRaft_ServiceHealth_FollowerStampsOwnBit(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}

	stampOf := func(r *Raft) bool {
		// Node 1 learns leader 2 at term 1, then answers a heartbeat.
		r.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
		rd := r.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
		if len(rd.Msgs) != 1 || rd.Msgs[0].Kind != MsgAppResp {
			t.Fatalf("follower did not answer a heartbeat with one MsgAppResp: %+v", rd.Msgs)
		}
		return rd.Msgs[0].Reached
	}

	// With the option on but no client answer framed, the bit is clear.
	r1, err := New(1, cfg, testRNG(11), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	// Become a follower of term 1 first, then note the reach, so the follower
	// transition does not clear the bit we are about to check.
	r1.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
	r1.NoteClientReached()
	rd := r1.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
	if len(rd.Msgs) != 1 || !rd.Msgs[0].Reached {
		t.Fatalf("a follower that framed a client answer did not stamp its bit: %+v", rd.Msgs)
	}

	r2, err := New(1, cfg, testRNG(13), serviceHealthOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	if stampOf(r2) {
		t.Fatalf("a follower that framed no client answer stamped the bit")
	}

	// With the option off, even a noted reach never stamps the bit.
	r3, err := New(1, cfg, testRNG(15), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	r3.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
	r3.NoteClientReached()
	rd = r3.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
	if len(rd.Msgs) != 1 || rd.Msgs[0].Reached {
		t.Fatalf("the option is off but the follower stamped a reach bit: %+v", rd.Msgs)
	}
}
