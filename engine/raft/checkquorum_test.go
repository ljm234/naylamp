package raft

import (
	"testing"

	"naylamp/engine/cluster"
)

// This file is the deterministic-simulation test net for leader quorum
// checking: a leader that goes two election-timeout windows without hearing
// from a majority steps down on its own, and the cases below exercise that
// mechanism and its guards. The shared safety checker in harness_test.go
// (observeRoles, checkLogMatching, recordApply) runs continuously underneath
// every case, so any scenario that broke election safety, log matching, leader
// completeness or state-machine safety would fail on the spot.
//
// The quorum-check cases force the option through newHarnessOpts rather than
// newHarness, so NAYLAMP_RAFT_CHECKQUORUM (which gates the default harness for
// the seeded sweep) can never turn the mechanism off underneath a test that
// exists to exercise it.

// checkQuorumOptions is DefaultOptions with the guard on, independent of the
// environment knob.
func checkQuorumOptions() Options {
	opts := DefaultOptions()
	opts.CheckQuorum = true
	return opts
}

// isolateLeader cuts a node off from every peer in both directions.
func isolateLeader(h *harness, leadID cluster.NodeID) {
	for _, id := range h.cfg.IDs() {
		if id != leadID {
			h.fab.Partition(leadID, id)
			h.fab.Partition(id, leadID)
		}
	}
}

// stallLeaderOneWindow blocks the leader's inbound acks for exactly one quorum
// window, aligned to a window boundary, then heals. The leader keeps
// heartbeating outbound, so every follower's lease stays fresh and none of them
// challenges: the only thing that can move is the leader's own quorum check.
// This reproduces the transient false positive the hysteresis must absorb: a
// one-window latency spike that starves the leader of acks while the cluster is
// perfectly healthy.
func stallLeaderOneWindow(t *testing.T, h *harness, leadID cluster.NodeID) {
	t.Helper()
	et := h.nodes[leadID].opts.ElectionTicks
	// Warm past the seeded first window into steady state, then land on the
	// start of a fresh window so the block starves exactly one evaluation.
	h.runTicks(3 * et)
	aligned := false
	for i := 0; i < 2*et; i++ {
		if h.nodes[leadID].checkElapsed == 0 {
			aligned = true
			break
		}
		h.tick()
	}
	if !aligned {
		t.Fatalf("could not align to a window boundary (checkElapsed=%d); the tick ratios changed", h.nodes[leadID].checkElapsed)
	}
	for _, id := range h.cfg.IDs() {
		if id != leadID {
			h.fab.Partition(id, leadID) // drop acks TO the leader; its heartbeats still flow out
		}
	}
	for i := 0; i < et; i++ {
		h.tick()
	}
	h.fab.HealAll()
}

// TestRaft_CheckQuorum_BecomeLeaderSeedsRecentActive drives one node to office
// through a real pre-vote and vote round and confirms becomeLeader seeds
// recentActive with the granting majority, the startup grace that keeps a fresh
// leader from demoting itself before a heartbeat round has answered.
func TestRaft_CheckQuorum_BecomeLeaderSeedsRecentActive(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(1), checkQuorumOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	for i := 0; i < 100 && r.prevotes == nil; i++ {
		r.Tick()
	}
	if r.prevotes == nil {
		t.Fatalf("node never entered a pre-vote round")
	}
	// A peer's pre-vote grant for the prospective term reaches quorum and starts
	// the real campaign; a vote grant then wins it.
	r.Step(Message{Kind: MsgPreVoteResp, From: 2, To: 1, Term: r.Term() + 1, Granted: true})
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: 1, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("node did not take office: role=%v", r.Role())
	}
	if !r.recentActive[2] {
		t.Fatalf("becomeLeader did not seed recentActive with the granter 2: %v", r.recentActive)
	}
	if !r.quorumActive() {
		t.Fatalf("a freshly elected leader must read its first window as active from the seed alone")
	}
}

// TestRaft_CheckQuorum_IsolatedLeaderDemotes is the baseline case: a leader cut
// off from a majority steps down by itself at the SAME term with its vote
// preserved, and the majority elects a new leader. It records the empirical
// timings the mechanism is expected to hit.
func TestRaft_CheckQuorum_IsolatedLeaderDemotes(t *testing.T) {
	h := newHarnessOpts(t, 3, 11, cluster.DefaultSimConfig(), checkQuorumOptions())
	lead := h.waitLeader(300)
	leadID := lead.ID()
	et := lead.opts.ElectionTicks
	if !h.propose([]byte("seed")) {
		t.Fatalf("proposal rejected before the partition")
	}
	h.runTicks(3 * et)
	termBefore := h.nodes[leadID].Term()
	voteBefore := h.nodes[leadID].hs.Vote

	isolatedAt := h.ticks
	isolateLeader(h, leadID)

	var demoteAt, recoverAt int
	for i := 0; i < 60*et; i++ {
		h.tick()
		if demoteAt == 0 && h.nodes[leadID].Role() != RoleLeader {
			demoteAt = h.ticks
			if got := h.nodes[leadID].Term(); got != termBefore {
				t.Fatalf("term inflated on self-demotion: %d -> %d", termBefore, got)
			}
			if got := h.nodes[leadID].hs.Vote; got != voteBefore {
				t.Fatalf("vote not preserved on self-demotion: %d -> %d", voteBefore, got)
			}
		}
		if recoverAt == 0 {
			if l := h.leader(); l != nil && l.ID() != leadID && l.Term() > termBefore {
				recoverAt = h.ticks
			}
		}
		if demoteAt != 0 && recoverAt != 0 {
			break
		}
	}
	if demoteAt == 0 {
		t.Fatalf("isolated leader never demoted within %d ticks", 60*et)
	}
	if recoverAt == 0 {
		t.Fatalf("majority never elected a new leader")
	}
	t.Logf("leader %d isolated at tick %d; self-demoted at tick %d (%.1f windows); majority re-elected at tick %d; cluster leaderless hole = %d ticks (%.1f x ElectionTicks)",
		leadID, isolatedAt, demoteAt, float64(demoteAt-isolatedAt)/float64(et),
		recoverAt, recoverAt-isolatedAt, float64(recoverAt-isolatedAt)/float64(et))
}

// TestRaft_CheckQuorum_HealthyLeaderHolds is the negative control: a leader that
// keeps hearing a majority holds office continuously, across jittery,
// high-latency and lossy fabrics. The high-latency arm is the case a healthy
// sole leader must survive without a spurious step-down. Any step-down here,
// same-term (a quorum-check false positive) or otherwise, is a failure: with a
// live majority and fresh follower leases nothing should unseat the leader.
func TestRaft_CheckQuorum_HealthyLeaderHolds(t *testing.T) {
	cases := []struct {
		name string
		sim  cluster.SimConfig
	}{
		{"jittery", cluster.DefaultSimConfig()},
		{"highLatency", cluster.SimConfig{MinLatency: 1, MaxLatency: 7}},
		{"lossy", cluster.SimConfig{MinLatency: 1, MaxLatency: 6, DropProb: 0.05}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for seed := uint64(1); seed <= 6; seed++ {
				h := newHarnessOpts(t, 3, seed, tc.sim, checkQuorumOptions())
				lead := h.waitLeader(500)
				leadID := lead.ID()
				leadTerm := lead.Term()
				et := lead.opts.ElectionTicks
				for i := 0; i < 40*et; i++ {
					h.tick()
					n := h.nodes[leadID]
					if n.Role() != RoleLeader || n.Term() != leadTerm {
						t.Fatalf("seed %d %s: healthy leader %d did not hold office continuously: role=%v term=%d (was leader at term %d)",
							seed, tc.name, leadID, n.Role(), n.Term(), leadTerm)
					}
				}
			}
		})
	}
}

// TestRaft_CheckQuorum_MinorityLossNoDemotion covers reintegration: losing a
// single follower (a minority) must never demote the leader. The white-box
// check that failedWindows stays zero makes this exercise quorumActive itself,
// since a miscount that treated the surviving majority as quorumless would climb the
// counter here even though the leader has not (yet) stepped down. The follower
// then rejoins cleanly on heal.
func TestRaft_CheckQuorum_MinorityLossNoDemotion(t *testing.T) {
	h := newHarnessOpts(t, 3, 7, cluster.DefaultSimConfig(), checkQuorumOptions())
	lead := h.waitLeader(300)
	leadID := lead.ID()
	et := lead.opts.ElectionTicks
	termBefore := lead.Term()

	var iso cluster.NodeID
	for _, id := range h.cfg.IDs() {
		if id != leadID {
			iso = id
			break
		}
	}
	for _, id := range h.cfg.IDs() {
		if id != iso {
			h.fab.Partition(iso, id)
			h.fab.Partition(id, iso)
		}
	}
	for i := 0; i < 40*et; i++ {
		h.tick()
		if h.nodes[leadID].Role() != RoleLeader || h.nodes[leadID].Term() != termBefore {
			t.Fatalf("leader demoted while only a minority (%d) was isolated: role=%v term=%d, want leader at %d",
				iso, h.nodes[leadID].Role(), h.nodes[leadID].Term(), termBefore)
		}
		if fw := h.nodes[leadID].failedWindows; fw != 0 {
			t.Fatalf("leader accumulated %d failed windows while a majority was reachable: quorumActive miscounted the live majority", fw)
		}
	}
	h.fab.HealAll()
	h.quiesce(400)
	if h.nodes[iso].Role() != RoleFollower {
		t.Fatalf("reintegrated node is not a follower: role=%v", h.nodes[iso].Role())
	}
}

// TestRaft_CheckQuorum_FreshLeaderGrace pins the startup grace: a leader
// isolated right after taking office does not demote before its grace window and
// hysteresis elapse, and it does demote afterward.
func TestRaft_CheckQuorum_FreshLeaderGrace(t *testing.T) {
	h := newHarnessOpts(t, 3, 42, cluster.DefaultSimConfig(), checkQuorumOptions())
	lead := h.waitLeader(300)
	leadID := lead.ID()
	et := lead.opts.ElectionTicks
	if len(h.nodes[leadID].recentActive) < h.cfg.Quorum()-1 {
		t.Fatalf("a leader in office should carry an active majority, got recentActive=%v", h.nodes[leadID].recentActive)
	}
	termBefore := lead.Term()
	isolateLeader(h, leadID)

	survived := 0
	for i := 0; i < 60*et; i++ {
		if h.nodes[leadID].Role() != RoleLeader {
			break
		}
		h.tick()
		survived++
	}
	if h.nodes[leadID].Role() == RoleLeader {
		t.Fatalf("isolated leader never demoted within budget")
	}
	if survived < et {
		t.Fatalf("isolated leader demoted after only %d ticks, less than one grace window (%d): the becomeLeader seed did not protect the first window", survived, et)
	}
	if h.nodes[leadID].Term() != termBefore {
		t.Fatalf("term inflated on demotion: %d -> %d", termBefore, h.nodes[leadID].Term())
	}
	t.Logf("fresh isolated leader survived %d ticks (%.1f windows) before demoting", survived, float64(survived)/float64(et))
}

// TestRaft_CheckQuorum_AntiFlapping drives repeated transient one-window stalls
// at the default two-window threshold and confirms the leader rides through
// every one of them without a single step-down: the hysteresis absorbs
// recurring spikes.
func TestRaft_CheckQuorum_AntiFlapping(t *testing.T) {
	h := newHarnessOpts(t, 3, 7, cluster.DefaultSimConfig(), checkQuorumOptions())
	lead := h.waitLeader(300)
	leadID := lead.ID()
	termBefore := lead.Term()
	for round := 0; round < 5; round++ {
		stallLeaderOneWindow(t, h, leadID)
		if h.nodes[leadID].Role() != RoleLeader || h.nodes[leadID].Term() != termBefore {
			t.Fatalf("round %d: leader flapped under a repeated transient stall: role=%v term=%d, want leader at %d",
				round, h.nodes[leadID].Role(), h.nodes[leadID].Term(), termBefore)
		}
	}
	t.Logf("leader held office across 5 repeated one-window stalls at k=%d", h.nodes[leadID].checkQuorumWindows)
}

// TestRaft_CheckQuorum_HysteresisSuppressesTransientFalsePositive runs the SAME
// transient one-window stall on a healthy sole leader at both hysteresis
// settings. With a one-window threshold the leader misreads the stall and steps
// down at the same term (the false positive); with the two-window default it
// absorbs the stall and holds office. The one-window arm also measures the
// recovery time after the false step-down.
func TestRaft_CheckQuorum_HysteresisSuppressesTransientFalsePositive(t *testing.T) {
	run := func(t *testing.T, k int) (falseStepDown, held bool, hole int) {
		h := newHarnessOpts(t, 3, 7, cluster.DefaultSimConfig(), checkQuorumOptions())
		lead := h.waitLeader(300)
		leadID := lead.ID()
		et := lead.opts.ElectionTicks
		for _, id := range h.cfg.IDs() {
			h.nodes[id].checkQuorumWindows = k
		}
		termBefore := h.nodes[leadID].Term()
		stallLeaderOneWindow(t, h, leadID)
		n := h.nodes[leadID]
		switch {
		case n.Role() != RoleLeader && n.Term() == termBefore:
			falseStepDown = true
			demoteAt := h.ticks
			for i := 0; i < 60*et; i++ {
				h.tick()
				if l := h.leader(); l != nil {
					hole = h.ticks - demoteAt
					break
				}
			}
		case n.Role() == RoleLeader && n.Term() == termBefore:
			held = true
			h.runTicks(5 * et)
		}
		return
	}
	t.Run("one_window_threshold_false_stepdown", func(t *testing.T) {
		down, _, hole := run(t, 1)
		if !down {
			t.Fatalf("k=1: a single-window stall must trip a spurious same-term step-down (the false positive), but the leader held")
		}
		t.Logf("k=1: leader falsely stepped down on ONE transient window; cluster recovered a leader %d ticks later", hole)
	})
	t.Run("two_window_threshold_tolerated", func(t *testing.T) {
		down, held, _ := run(t, 2)
		if down {
			t.Fatalf("k=2: a single transient window must NOT step the leader down, but it did")
		}
		if !held {
			t.Fatalf("k=2: leader must still hold office at its original term after the transient window, but it did not")
		}
		t.Logf("k=2: leader held office at its term through the transient window; the false positive is suppressed")
	})
}

// TestRaft_CheckQuorum_FlagOffLeaderHolds confirms the option gates the
// behavior: with CheckQuorum off, an isolated leader retains office exactly as
// it did before this change.
func TestRaft_CheckQuorum_FlagOffLeaderHolds(t *testing.T) {
	off := DefaultOptions() // CheckQuorum is false by default
	h := newHarnessOpts(t, 3, 7, cluster.DefaultSimConfig(), off)
	lead := h.waitLeader(300)
	leadID := lead.ID()
	et := lead.opts.ElectionTicks
	isolateLeader(h, leadID)
	h.runTicks(10 * et)
	if h.nodes[leadID].Role() != RoleLeader {
		t.Fatalf("with CheckQuorum off an isolated leader must retain office (historical behavior), but it demoted to %v", h.nodes[leadID].Role())
	}
}
