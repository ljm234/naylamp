package raft

import (
	"testing"

	"naylamp/engine/cluster"
)

// TestReady_LeaderHandsEntriesBeforeCommit checks the persist-before-send
// contract on the leader path: the no-op of taking office and every proposal
// appear in Ready.Entries exactly once, before or with their commit.
func TestReady_LeaderHandsEntriesBeforeCommit(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	r, err := New(1, cfg, testRNG(3), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	var handed []Entry
	for i := 0; i < 40 && r.Role() != RoleLeader; i++ {
		rd := r.Tick()
		handed = append(handed, rd.Entries...)
	}
	if r.Role() != RoleLeader {
		t.Fatalf("single node never took office")
	}
	if len(handed) != 1 || handed[0].Index != 1 || len(handed[0].Data) != 0 {
		t.Fatalf("no-op not handed exactly once: %+v", handed)
	}

	idx, rd, err := r.Propose([]byte("x"))
	if err != nil {
		t.Fatalf("propose: %v", err)
	}
	if len(rd.Entries) != 1 || rd.Entries[0].Index != idx || string(rd.Entries[0].Data) != "x" {
		t.Fatalf("proposal not handed: %+v", rd.Entries)
	}
	found := false
	for _, e := range rd.Committed {
		if e.Index == idx {
			found = true
		}
	}
	if !found {
		t.Fatalf("single-node proposal not committed in the same ready")
	}
	if rd2 := r.Tick(); len(rd2.Entries) != 0 {
		t.Fatalf("entries handed twice: %+v", rd2.Entries)
	}
}

// TestReady_FollowerHandsAppendsAndRewindsOnConflict checks the follower
// path: appended batches are handed for persistence, and a conflicting
// overwrite hands the affected suffix again (conservative rewind).
func TestReady_FollowerHandsAppendsAndRewindsOnConflict(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(5), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	rd := r.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 1, LogIndex: 0, LogTerm: 0,
		Entries: []Entry{dataEnt(1, 1, "a"), dataEnt(2, 1, "b")}})
	if len(rd.Entries) != 2 || rd.Entries[1].Index != 2 {
		t.Fatalf("appended batch not handed: %+v", rd.Entries)
	}
	// A new leader overwrites index 2: the suffix must be handed again with
	// the new content.
	rd = r.Step(Message{Kind: MsgApp, From: 3, To: 1, Term: 2, LogIndex: 1, LogTerm: 1,
		Entries: []Entry{dataEnt(2, 2, "B2")}})
	if len(rd.Entries) != 1 || rd.Entries[0].Index != 2 || rd.Entries[0].Term != 2 || string(rd.Entries[0].Data) != "B2" {
		t.Fatalf("conflict suffix not rehanded: %+v", rd.Entries)
	}
	// A pure heartbeat hands nothing.
	rd = r.Step(Message{Kind: MsgApp, From: 3, To: 1, Term: 2, LogIndex: 2, LogTerm: 2})
	if len(rd.Entries) != 0 {
		t.Fatalf("heartbeat handed entries: %+v", rd.Entries)
	}
}

// TestReady_RestoreSeedsDurableState checks restart seeding: restored
// entries are never rehanded, the committed prefix replays through the
// normal Committed path, and misuse fails loudly.
func TestReady_RestoreSeedsDurableState(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(7), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	hs := HardState{Term: 3, Vote: 2, Commit: 2}
	entries := []Entry{dataEnt(1, 1, "a"), dataEnt(2, 1, "b"), dataEnt(3, 3, "c")}
	if err := r.Restore(hs, entries); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if r.Term() != 3 || r.LastIndex() != 3 {
		t.Fatalf("restored state wrong: term=%d last=%d", r.Term(), r.LastIndex())
	}
	rd := r.Tick()
	if len(rd.Entries) != 0 {
		t.Fatalf("restored entries rehanded: %+v", rd.Entries)
	}
	if len(rd.Committed) != 2 || rd.Committed[1].Index != 2 || string(rd.Committed[0].Data) != "a" {
		t.Fatalf("committed prefix did not replay: %+v", rd.Committed)
	}

	// Misuse fails loudly.
	if err := r.Restore(hs, nil); err == nil {
		t.Fatalf("second restore accepted")
	}
	r2, _ := New(1, cfg, testRNG(8), DefaultOptions())
	if err := r2.Restore(HardState{Term: 1}, []Entry{dataEnt(2, 1, "gap")}); err == nil {
		t.Fatalf("gapped restore accepted")
	}
	r3, _ := New(1, cfg, testRNG(9), DefaultOptions())
	if err := r3.Restore(HardState{Term: 1, Commit: 5}, []Entry{dataEnt(1, 1, "a")}); err == nil {
		t.Fatalf("commit beyond log accepted")
	}
	r4, _ := New(1, cfg, testRNG(10), DefaultOptions())
	if err := r4.Restore(HardState{Term: 1}, []Entry{dataEnt(1, 2, "future")}); err == nil {
		t.Fatalf("log term above hard state term accepted")
	}
}
