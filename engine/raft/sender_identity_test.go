package raft

import (
	"testing"

	"naylamp/engine/cluster"
)

// makeFiveNodeLeader elects node 1 of a five node cluster and commits the term's
// no-op, leaving a leader that can open a read round. Five rather than three
// because the point of the tests below is the size of a majority: quorum here is
// three, so the leader's own seed plus two answers decides a round, and the test
// can hand it two answers from ids that do not exist.
func makeFiveNodeLeader(t *testing.T, seed uint64) *Raft {
	t.Helper()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4}, {ID: 5}}}
	r, err := New(1, cfg, testRNG(seed), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	for i := 0; i < 40 && r.Role() == RoleFollower; i++ {
		for _, m := range r.Tick().Msgs {
			if m.Kind != MsgPreVote {
				continue
			}
			r.Step(Message{Kind: MsgPreVoteResp, From: 2, To: 1, Term: m.Term, Granted: true})
			r.Step(Message{Kind: MsgPreVoteResp, From: 3, To: 1, Term: m.Term, Granted: true})
		}
	}
	if r.Role() != RoleCandidate {
		t.Fatalf("never campaigned")
	}
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: 1, Term: r.Term(), Granted: true})
	r.Step(Message{Kind: MsgVoteResp, From: 3, To: 1, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("the grants did not elect")
	}
	r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})
	r.Step(Message{Kind: MsgAppResp, From: 3, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})
	return r
}

// TestStep_CountsOnlyConfiguredSendersTowardAReadQuorum is the half of the
// identity problem that binding the declared sender to the authenticated one
// cannot reach, and it is worth being exact about why. Binding asks whether a
// sender is honest about who it is. A stranger answers that truthfully by naming
// itself, and the round below then counts it, because a read quorum is sized
// with len of a map keyed by whoever answered and no denominator of membership.
//
// The stranger is not hypothetical. The transport admits any principal holding a
// certificate the cluster CA signed, and the deployment signs one for the
// routing client, which belongs to no group. So this is the id 90 case with the
// numbers changed: two ids that are in no configuration anywhere, answering a
// round they were never asked about.
//
// The honest arm runs second and is not optional. Everything above it asserts
// that a round did not confirm, and a Step that dropped every message would make
// all of that true.
func TestStep_CountsOnlyConfiguredSendersTowardAReadQuorum(t *testing.T) {
	r := makeFiveNodeLeader(t, 61)

	seq, rd, err := r.RequestRead()
	if err != nil {
		t.Fatalf("request read: %v", err)
	}
	if len(rd.ReadStates) != 0 {
		t.Fatalf("the round resolved before anyone answered")
	}
	before := r.RejectedMessages()

	// Ids 91 and 92 are members of nothing. Quorum of five is three and the
	// leader seeds itself, so two answers would finish the round.
	r.Step(Message{Kind: MsgAppResp, From: 91, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	rd = r.Step(Message{Kind: MsgAppResp, From: 92, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	if len(rd.ReadStates) != 0 {
		t.Fatalf("read round %d was confirmed by ids that are in no cluster config", seq)
	}
	if got := r.RejectedMessages() - before; got != 2 {
		t.Fatalf("rejected %d strangers, want 2", got)
	}

	// The same two answers from nodes that really are in the configuration have
	// to finish it.
	r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	rd = r.Step(Message{Kind: MsgAppResp, From: 3, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex(), ReadCtx: seq})
	if len(rd.ReadStates) == 0 {
		t.Fatalf("read round %d was not confirmed by a real majority", seq)
	}
}

// TestStep_CountsOnlyConfiguredSendersTowardAnElection is the same rule on the
// other two tallies. Pre-votes and votes are counted the same way the read round
// is, by the length of a map keyed by the sender, so a stranger inflates an
// election exactly as it inflates a read.
func TestStep_CountsOnlyConfiguredSendersTowardAnElection(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}, {ID: 4}, {ID: 5}}}
	r, err := New(1, cfg, testRNG(67), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}

	// Drive the pre-vote round, then answer it entirely with strangers.
	var prospective uint64
	for i := 0; i < 40 && prospective == 0; i++ {
		for _, m := range r.Tick().Msgs {
			if m.Kind == MsgPreVote {
				prospective = m.Term
			}
		}
	}
	if prospective == 0 {
		t.Fatalf("the node never opened a pre-vote round")
	}
	for _, id := range []cluster.NodeID{91, 92, 93, 94} {
		r.Step(Message{Kind: MsgPreVoteResp, From: id, To: 1, Term: prospective, Granted: true})
	}
	if r.Role() == RoleCandidate || r.Role() == RoleLeader {
		t.Fatalf("strangers carried the node into a campaign: role %v", r.Role())
	}

	// Real members carry it, which is what says the tally still works.
	r.Step(Message{Kind: MsgPreVoteResp, From: 2, To: 1, Term: prospective, Granted: true})
	r.Step(Message{Kind: MsgPreVoteResp, From: 3, To: 1, Term: prospective, Granted: true})
	if r.Role() != RoleCandidate {
		t.Fatalf("a real pre-vote majority did not campaign: role %v", r.Role())
	}

	for _, id := range []cluster.NodeID{91, 92, 93, 94} {
		r.Step(Message{Kind: MsgVoteResp, From: id, To: 1, Term: r.Term(), Granted: true})
	}
	if r.Role() == RoleLeader {
		t.Fatalf("strangers elected a leader")
	}
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: 1, Term: r.Term(), Granted: true})
	r.Step(Message{Kind: MsgVoteResp, From: 3, To: 1, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("a real vote majority did not elect: role %v", r.Role())
	}
}

// TestStep_RefusesAMessageAddressedFromItself covers the third door, which is
// nonsense rather than attack: nothing in the protocol hands a node its own
// frame, because every broadcast walks cfg.Peers and that excludes self. It is
// refused anyway so that a node cannot be made to answer its own tally, and it
// is tested so the clause cannot be deleted unnoticed.
func TestStep_RefusesAMessageAddressedFromItself(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(71), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	before := r.RejectedMessages()
	r.Step(Message{Kind: MsgApp, From: 1, To: 1, Term: 9})
	if got := r.RejectedMessages() - before; got != 1 {
		t.Fatalf("a self addressed message was not refused: rejected %d, want 1", got)
	}
	if r.Term() != 0 {
		t.Fatalf("a self addressed message moved the term to %d", r.Term())
	}
}

// TestStep_RefusesAMessageAddressedToAnotherNode covers the oldest of the three
// doors, the one the transport is supposed to make impossible and Step checks
// anyway. The frame comes from a real member of this configuration and is
// addressed to somebody else. It went uncovered until the clause was rewritten
// and wired to the counter, at which point deleting it left the package green.
func TestStep_RefusesAMessageAddressedToAnotherNode(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(73), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	before := r.RejectedMessages()
	r.Step(Message{Kind: MsgApp, From: 2, To: 3, Term: 9})
	if got := r.RejectedMessages() - before; got != 1 {
		t.Fatalf("a misrouted message was not refused: rejected %d, want 1", got)
	}
	if r.Term() != 0 {
		t.Fatalf("a misrouted message moved the term to %d", r.Term())
	}
}
