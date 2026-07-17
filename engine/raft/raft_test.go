package raft

import (
	"fmt"
	"os"
	"strconv"
	"testing"

	"naylamp/engine/cluster"
)

func TestRaft_ElectsSingleLeader(t *testing.T) {
	for _, n := range []int{3, 5} {
		h := newHarness(t, n, 7, cluster.DefaultSimConfig())
		lead := h.waitLeader(300)
		h.runTicks(60)
		count := 0
		for _, id := range h.cfg.IDs() {
			node := h.nodes[id]
			if node.Role() == RoleLeader {
				count++
			} else if node.Leader() != lead.ID() {
				t.Fatalf("n=%d: node %d follows %d, want %d", n, id, node.Leader(), lead.ID())
			}
			if node.Term() != lead.Term() {
				t.Fatalf("n=%d: node %d at term %d, leader at %d", n, id, node.Term(), lead.Term())
			}
		}
		if count != 1 {
			t.Fatalf("n=%d: %d live leaders, want 1", n, count)
		}
	}
}

func TestRaft_LogMatchingUnderFaults(t *testing.T) {
	sim := cluster.SimConfig{MinLatency: 1, MaxLatency: 6, DropProb: 0.15, DupProb: 0.15}
	for seed := uint64(1); seed <= 10; seed++ {
		h := newHarness(t, 5, seed, sim)
		h.waitLeader(400)
		accepted := 0
		for step := 0; step < 200; step++ {
			if step%5 == 0 && h.propose([]byte(fmt.Sprintf("s%d-p%d", seed, step))) {
				accepted++
			}
			h.tick()
		}
		h.quiesce(800)
		if accepted == 0 || len(h.committed) == 0 {
			t.Fatalf("seed %d exercised nothing: accepted=%d committed=%d", seed, accepted, len(h.committed))
		}
	}
}

func TestRaft_LeaderPartitionNoDoubleCommit(t *testing.T) {
	h := newHarness(t, 5, 11, cluster.DefaultSimConfig())
	old := h.waitLeader(300)
	if !h.propose([]byte("e1")) {
		t.Fatalf("initial proposal rejected")
	}
	h.waitCommittedData("e1", 300)

	// Cut the leader off completely, both directions.
	for _, id := range h.cfg.IDs() {
		if id != old.ID() {
			h.fab.Partition(old.ID(), id)
			h.fab.Partition(id, old.ID())
		}
	}
	// The isolated old leader still accepts a proposal locally; it must
	// never commit anywhere.
	if _, rd, err := old.Propose([]byte("lost")); err != nil {
		t.Fatalf("isolated leader rejected proposal: %v", err)
	} else {
		h.drain(old.ID(), rd)
	}
	// The majority side elects a new leader at a higher term and commits.
	var fresh *Raft
	for i := 0; i < 600 && fresh == nil; i++ {
		h.tick()
		if lead := h.leader(); lead != nil && lead.Term() > old.Term() {
			fresh = lead
		}
	}
	if fresh == nil {
		t.Fatalf("majority never elected a new leader")
	}
	if !h.propose([]byte("e2")) {
		t.Fatalf("proposal to new leader rejected")
	}
	h.waitCommittedData("e2", 400)
	for _, e := range h.committed {
		if string(e.Data) == "lost" {
			t.Fatalf("minority entry committed: double commit")
		}
	}

	h.quiesce(800)
	if old.Role() == RoleLeader {
		t.Fatalf("stale leader did not step down after heal")
	}
	for i := uint64(1); i <= old.LastIndex(); i++ {
		if e, ok := old.log.Entry(i); ok && string(e.Data) == "lost" {
			t.Fatalf("divergent entry survived reconciliation")
		}
	}
	for _, e := range h.committed {
		if string(e.Data) == "lost" {
			t.Fatalf("minority entry appeared committed after heal")
		}
	}
}

func TestRaft_StaleCandidateLoses(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	voter, err := New(1, cfg, testRNG(1), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	voter.hs.Term = 2
	mustAppend(t, voter.log, ent(1, 1), ent(2, 2))

	// A candidate with a shorter, older log must be refused (5.4.1)...
	rd := voter.Step(Message{Kind: MsgVote, From: 2, To: 1, Term: 3, LogIndex: 1, LogTerm: 1})
	if len(rd.Msgs) != 1 || rd.Msgs[0].Kind != MsgVoteResp || rd.Msgs[0].Granted {
		t.Fatalf("stale candidate was granted: %+v", rd.Msgs)
	}
	if voter.Term() != 3 || voter.hs.Vote != cluster.None {
		t.Fatalf("voter state after refusal: term=%d vote=%d", voter.Term(), voter.hs.Vote)
	}
	// ...while an up-to-date candidate at the same term still gets the vote.
	rd = voter.Step(Message{Kind: MsgVote, From: 3, To: 1, Term: 3, LogIndex: 2, LogTerm: 2})
	if len(rd.Msgs) != 1 || !rd.Msgs[0].Granted {
		t.Fatalf("up-to-date candidate refused: %+v", rd.Msgs)
	}
	if voter.hs.Vote != 3 || !rd.Dirty {
		t.Fatalf("vote not recorded durably: vote=%d dirty=%v", voter.hs.Vote, rd.Dirty)
	}
	// A stale-term leader is answered so it learns the new term.
	rd = voter.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1})
	if len(rd.Msgs) != 1 || rd.Msgs[0].Term != 3 || rd.Msgs[0].Granted {
		t.Fatalf("stale leader handling: %+v", rd.Msgs)
	}
}

func TestRaft_SafetyInvariants_Seeded(t *testing.T) {
	seeds := 300
	if testing.Short() {
		seeds = 40
	}
	if env := os.Getenv("NAYLAMP_RAFT_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_RAFT_SEEDS=%q invalid", env)
		}
		seeds = v
	}

	var elections, committed int
	var stats cluster.SimStats
	sim := cluster.SimConfig{MinLatency: 1, MaxLatency: 6, DropProb: 0.12, DupProb: 0.12}
	for s := 1; s <= seeds; s++ {
		seed := uint64(s)
		size := 3 + 2*int(seed%2)
		h := newHarness(t, size, seed, sim)
		chaos := testRNG(seed + 0xC0FFEE)
		partitioned := false
		for step := 0; step < 350; step++ {
			if !partitioned && chaos.Float64() < 0.02 {
				cut := cluster.NodeID(chaos.IntN(size) + 1) //nolint:gosec // chaos.IntN(size) is in [0,size), the NodeID is always positive
				for _, id := range h.cfg.IDs() {
					if id != cut {
						h.fab.Partition(cut, id)
						h.fab.Partition(id, cut)
					}
				}
				partitioned = true
			} else if partitioned && chaos.Float64() < 0.05 {
				h.fab.HealAll()
				partitioned = false
			}
			if step%5 == 0 {
				h.propose([]byte(fmt.Sprintf("s%d-p%d", seed, step)))
			}
			h.tick()
		}
		h.quiesce(800)

		elections += h.elections
		committed += len(h.committed)
		st := h.fab.Stats()
		stats.Sent += st.Sent
		stats.DroppedByFault += st.DroppedByFault
		stats.DroppedByPartition += st.DroppedByPartition
		stats.Duplicated += st.Duplicated
	}

	// Coverage gate: a chaos run that elected nothing, committed nothing or
	// never exercised a fault proves nothing (the illusory-coverage trap).
	if elections < seeds {
		t.Fatalf("coverage: %d elections across %d seeds", elections, seeds)
	}
	if committed == 0 {
		t.Fatalf("coverage: nothing committed across %d seeds", seeds)
	}
	if stats.DroppedByFault == 0 || stats.Duplicated == 0 || stats.DroppedByPartition == 0 {
		t.Fatalf("coverage: fault schedule idle: %+v", stats)
	}
	t.Logf("seeds=%d elections=%d committed=%d sent=%d dropped=%d dup=%d partitionDrops=%d",
		seeds, elections, committed, stats.Sent, stats.DroppedByFault, stats.Duplicated, stats.DroppedByPartition)
}

func TestRaft_PreVoteNoTermInflation(t *testing.T) {
	h := newHarness(t, 3, 17, cluster.DefaultSimConfig())
	lead := h.waitLeader(300)
	if !h.propose([]byte("stable")) {
		t.Fatalf("proposal rejected")
	}
	h.waitCommittedData("stable", 300)
	termBefore := lead.Term()

	// Fully isolate one follower, both directions, and let its election
	// timer fire many times. Without pre-vote each timeout increments its
	// term; with pre-vote it never wins a round, so the term must not move.
	var isolated *Raft
	for _, id := range h.cfg.IDs() {
		if id != lead.ID() {
			isolated = h.nodes[id]
			break
		}
	}
	for _, id := range h.cfg.IDs() {
		if id != isolated.ID() {
			h.fab.Partition(isolated.ID(), id)
			h.fab.Partition(id, isolated.ID())
		}
	}
	h.runTicks(400)
	if got := isolated.Term(); got != termBefore {
		t.Fatalf("isolated node inflated its term: %d, want %d", got, termBefore)
	}

	// Heal: the rejoiner must slot back in as a follower of the SAME term
	// and leadership must not change hands.
	h.fab.HealAll()
	h.runTicks(120)
	if lead.Role() != RoleLeader || lead.Term() != termBefore {
		t.Fatalf("stable leader disrupted after heal: role=%v term=%d", lead.Role(), lead.Term())
	}
	if isolated.Term() != termBefore || isolated.Role() != RoleFollower {
		t.Fatalf("rejoiner state wrong: role=%v term=%d, want follower at %d", isolated.Role(), isolated.Term(), termBefore)
	}
	h.quiesce(800)
}

// TestRaft_PreVoteNotBlockedByDeadLeaderBelief pins the liveness bug behind the
// election stall the real-infrastructure gate exposed: after a leader dies, the
// two survivors both still point r.leader at it, and preCampaign resets
// electionElapsed without clearing that belief, so in handlePreVote each
// survivor reports the dead leader as fresh (r.leader != None and
// electionElapsed < ElectionTicks) and refuses the other's pre-vote. Two nodes
// that both just timed out on the same dead leader can then refuse each other,
// a metastable tie the timeout randomization usually breaks quickly but which a
// perturbed schedule sustained far past the timeout.
//
// The first subtest drives one survivor into the pre-candidate state (it has
// itself timed out on the unreachable leader and started a pre-vote round, so
// electionElapsed just reset to zero while it still believes the old leader) and
// hands it a peer's pre-vote for the next term carrying an up-to-date log. A
// survivor that has itself lost the leader must be willing to pre-vote for a
// peer, so the grant must be true. It is false today because the belief in the
// dead leader survives preCampaign; that is the bug, and this subtest is meant
// to fail until preCampaign clears r.leader.
//
// The second subtest is the non-vacuity control: a follower that is still
// hearing the current leader (a genuinely fresh lease) must refuse the same
// pre-vote, today and after the fix, so the fix cannot be mistaken for one that
// simply disables the pre-vote leader protection.
func TestRaft_PreVoteNotBlockedByDeadLeaderBelief(t *testing.T) {
	const seed = 17

	t.Run("DeadLeaderBeliefMustNotBlockAPeersPreVote", func(t *testing.T) {
		h := newHarness(t, 3, seed, cluster.DefaultSimConfig())
		lead := h.waitLeader(300)
		if !h.propose([]byte("stable")) {
			t.Fatalf("proposal rejected before a leader was stable")
		}
		h.waitCommittedData("stable", 300)

		// Two survivors after the leader dies. Reading the elected leader keeps
		// the test seed independent: whoever won leads, the other two survive.
		leadID := lead.ID()
		var survivors []cluster.NodeID
		for _, id := range h.cfg.IDs() {
			if id != leadID {
				survivors = append(survivors, id)
			}
		}
		peer, victim := survivors[0], h.nodes[survivors[1]]

		// Kill the leader and keep every node from completing a real election, so
		// the victim spins its own pre-vote rounds in place: cut every directed
		// edge. The leader stops heartbeating, the victim's timer fires, and its
		// pre-votes reach no one, so it never leaves the pre-candidate state the
		// probe below inspects.
		ids := h.cfg.IDs()
		for _, a := range ids {
			for _, b := range ids {
				if a != b {
					h.fab.Partition(a, b)
				}
			}
		}

		// Drive the victim to the exact target state: a follower that just ran
		// preCampaign, so electionElapsed is zero and it still believes the dead
		// leader. prevotes is non-nil only once a pre-vote round has started.
		reached := false
		for i := 0; i < 400; i++ {
			h.tick()
			if victim.Role() == RoleFollower && victim.prevotes != nil && victim.electionElapsed == 0 {
				reached = true
				break
			}
		}
		if !reached {
			t.Fatalf("victim %d never reached the pre-candidate state", victim.ID())
		}
		if victim.leader != leadID {
			t.Fatalf("victim %d no longer believes the dead leader (leader=%d): setup invalid", victim.ID(), victim.leader)
		}
		if victim.electionElapsed >= victim.opts.ElectionTicks {
			t.Fatalf("victim %d lease window already closed (electionElapsed=%d): setup invalid", victim.ID(), victim.electionElapsed)
		}

		// The peer's pre-vote for the next term, carrying a log identical to the
		// victim's, so IsUpToDate is true and the only thing that can refuse the
		// grant is the leaderFresh lease.
		pv := Message{
			Kind:     MsgPreVote,
			From:     peer,
			To:       victim.ID(),
			Term:     victim.Term() + 1,
			LogIndex: victim.log.LastIndex(),
			LogTerm:  victim.log.LastTerm(),
		}
		resp, ok := preVoteRespTo(victim.Step(pv), peer)
		if !ok {
			t.Fatalf("victim %d did not answer the pre-vote", victim.ID())
		}
		if !resp.Granted {
			t.Fatalf("victim %d refused a peer's pre-vote for term %d because it still believes the dead leader %d is fresh (leader=%d, electionElapsed=%d < ElectionTicks=%d): the metastable pre-vote tie that stalls the election",
				victim.ID(), pv.Term, leadID, victim.leader, victim.electionElapsed, victim.opts.ElectionTicks)
		}
	})

	t.Run("HealthyLeaderIsStillProtected", func(t *testing.T) {
		h := newHarness(t, 3, seed, cluster.DefaultSimConfig())
		lead := h.waitLeader(300)
		if !h.propose([]byte("stable")) {
			t.Fatalf("proposal rejected before a leader was stable")
		}
		h.waitCommittedData("stable", 300)

		leadID := lead.ID()
		var others []cluster.NodeID
		for _, id := range h.cfg.IDs() {
			if id != leadID {
				others = append(others, id)
			}
		}
		peer, follower := others[0], h.nodes[others[1]]

		// A few healthy ticks so heartbeats keep the follower's lease fresh: it
		// knows the leader and its timer stays well within the election window.
		h.runTicks(3)
		if follower.leader != leadID {
			t.Fatalf("follower %d does not know the leader: control setup invalid", follower.ID())
		}
		if follower.electionElapsed >= follower.opts.ElectionTicks {
			t.Fatalf("follower %d lease not fresh (electionElapsed=%d): control setup invalid", follower.ID(), follower.electionElapsed)
		}

		// The same up-to-date pre-vote for the next term. A follower still hearing
		// the leader must refuse it: pre-vote exists to shield a healthy leader
		// from a disruptive challenger. This holds today and after the fix.
		pv := Message{
			Kind:     MsgPreVote,
			From:     peer,
			To:       follower.ID(),
			Term:     follower.Term() + 1,
			LogIndex: follower.log.LastIndex(),
			LogTerm:  follower.log.LastTerm(),
		}
		resp, ok := preVoteRespTo(follower.Step(pv), peer)
		if !ok {
			t.Fatalf("follower %d did not answer the pre-vote", follower.ID())
		}
		if resp.Granted {
			t.Fatalf("follower %d granted a pre-vote while still hearing leader %d: the healthy-leader protection is broken", follower.ID(), leadID)
		}
	})
}

// preVoteRespTo returns the MsgPreVoteResp aimed at to inside a Ready, if one is
// present, so the cases above read the same field the same way.
func preVoteRespTo(rd Ready, to cluster.NodeID) (Message, bool) {
	for _, m := range rd.Msgs {
		if m.Kind == MsgPreVoteResp && m.To == to {
			return m, true
		}
	}
	return Message{}, false
}
