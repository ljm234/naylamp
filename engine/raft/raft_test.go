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
