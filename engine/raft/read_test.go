package raft

import (
	"errors"
	"testing"

	"naylamp/engine/cluster"
)

// makeReadLeader elects node 1 of a three node cluster by answering its
// pre-vote round and granting the real vote, leaving the no-op of its term
// appended but not yet committed.
func makeReadLeader(t *testing.T, seed uint64) *Raft {
	t.Helper()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(seed), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	for i := 0; i < 40 && r.Role() == RoleFollower; i++ {
		for _, m := range r.Tick().Msgs {
			if m.Kind == MsgPreVote {
				r.Step(Message{Kind: MsgPreVoteResp, From: 2, To: 1, Term: m.Term, Granted: true})
			}
		}
	}
	if r.Role() != RoleCandidate {
		t.Fatalf("never campaigned")
	}
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: 1, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("vote grant did not elect")
	}
	return r
}

func TestRead_LeaderConfirmsWithQuorum(t *testing.T) {
	r := makeReadLeader(t, 61)

	// Before the no-op of this term commits, reads are refused retryably.
	if _, _, err := r.RequestRead(); !errors.Is(err, ErrNotReady) {
		t.Fatalf("read before term commit accepted: %v", err)
	}
	r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})

	seq, rd, err := r.RequestRead()
	if err != nil {
		t.Fatalf("request read: %v", err)
	}
	if len(rd.ReadStates) != 0 {
		t.Fatalf("read confirmed without a round: %+v", rd.ReadStates)
	}
	carrying := 0
	for _, m := range rd.Msgs {
		if m.Kind == MsgApp && m.ReadCtx == seq {
			carrying++
		}
	}
	if carrying != 2 {
		t.Fatalf("read context on %d appends, want 2", carrying)
	}

	// One follower's answer completes the majority (leader plus one of three).
	rd2 := r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	if len(rd2.ReadStates) != 1 || rd2.ReadStates[0].Ctx != seq || rd2.ReadStates[0].Index != r.LastIndex() {
		t.Fatalf("read not confirmed correctly: %+v", rd2.ReadStates)
	}
	// A duplicate answer must not deliver the read twice.
	rd3 := r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	if len(rd3.ReadStates) != 0 {
		t.Fatalf("read delivered twice: %+v", rd3.ReadStates)
	}
	// A follower refuses reads outright.
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	f, _ := New(2, cfg, testRNG(62), DefaultOptions())
	if _, _, err := f.RequestRead(); !errors.Is(err, ErrNotLeader) {
		t.Fatalf("follower served a read: %v", err)
	}
}

func TestRead_FollowerEchoesContext(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	f, err := New(2, cfg, testRNG(63), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	// A granted heartbeat echoes the context.
	rd := f.Step(Message{Kind: MsgApp, From: 1, To: 2, Term: 1, LogIndex: 0, LogTerm: 0, ReadCtx: 7})
	if len(rd.Msgs) != 1 || !rd.Msgs[0].Granted || rd.Msgs[0].ReadCtx != 7 {
		t.Fatalf("granted echo wrong: %+v", rd.Msgs)
	}
	// A rejected append still echoes it: the answer proves recognition.
	rd = f.Step(Message{Kind: MsgApp, From: 1, To: 2, Term: 1, LogIndex: 9, LogTerm: 1, ReadCtx: 9})
	if len(rd.Msgs) != 1 || rd.Msgs[0].Granted || rd.Msgs[0].ReadCtx != 9 {
		t.Fatalf("rejection echo wrong: %+v", rd.Msgs)
	}
}

func TestRead_DepositionDropsPendingReads(t *testing.T) {
	r := makeReadLeader(t, 64)
	r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})
	oldTerm := r.Term()
	seq, _, err := r.RequestRead()
	if err != nil {
		t.Fatalf("request read: %v", err)
	}
	// A higher term deposes the leader before the round completes.
	r.Step(Message{Kind: MsgApp, From: 3, To: 1, Term: oldTerm + 1})
	if r.Role() != RoleFollower {
		t.Fatalf("higher term did not depose")
	}
	// The stale answer arrives afterwards: it must confirm nothing.
	rd := r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: oldTerm, Granted: true, ReadCtx: seq})
	if len(rd.ReadStates) != 0 {
		t.Fatalf("read confirmed after deposition: %+v", rd.ReadStates)
	}
	if _, _, err := r.RequestRead(); !errors.Is(err, ErrNotLeader) {
		t.Fatalf("deposed leader served a read: %v", err)
	}
}
