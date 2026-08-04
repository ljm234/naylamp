package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// oneHost builds a single Host of the cluster {1,2,3} on a SimNet and hands back
// the handler the transport would call, so a test can deliver a frame under any
// authenticated identity it chooses. That is the whole point of capturing it:
// through a real endpoint the fabric supplies the sender's own id and the two
// can never disagree, which is exactly the property under test and therefore
// exactly what a test has to be able to break.
//
// The peers are absent rather than silent. Whatever the Host emits goes into the
// fabric and finds no receiver, so what this node does is decided entirely by
// what the test delivers, with no second party to introduce timing of its own.
func oneHost(t *testing.T, seed uint64) (*Host, cluster.Handler) {
	t.Helper()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	fabric := cluster.NewSimNet(seed, cluster.DefaultSimConfig())
	t.Cleanup(fabric.Close)

	node, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(seed), NodeOptions{})
	if err != nil {
		t.Fatalf("open node 1: %v", err)
	}
	var captured cluster.Handler
	host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
		captured = h
		tr, terr := fabric.Endpoint(1, h)
		if terr != nil {
			t.Fatalf("endpoint 1: %v", terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("host 1: %v", err)
	}
	t.Cleanup(func() { _ = host.Close() })
	return host, captured
}

// TestHost_AcceptsAFrameFromTheSenderItAuthenticatedAs is the positive arm, and
// it runs first in this file on purpose. Every other test here asserts that
// something did NOT happen, and a check that refused every frame in the tree
// would satisfy all of them at once. This one is what makes that impossible: it
// requires an honest frame to still land and still be acted on.
func TestHost_AcceptsAFrameFromTheSenderItAuthenticatedAs(t *testing.T) {
	host, deliver := oneHost(t, 41)

	// Node 2 speaks as node 2. An append above our term is adopted and its
	// sender recognized as leader, so acting on it is directly observable.
	deliver(2, mustEncodeMsg(t, raft.Message{Kind: raft.MsgApp, From: 2, To: 1, Term: 5}))

	if got := host.Consensus().Leader; got != 2 {
		t.Fatalf("an honest frame was not acted on: leader = %d, want 2", got)
	}
	if got := host.Consensus().Term; got != 5 {
		t.Fatalf("an honest frame did not carry its term: term = %d, want 5", got)
	}
	if n := host.RejectedFrames(); n != 0 {
		t.Fatalf("an honest frame was refused: rejected = %d, want 0", n)
	}
	if err := host.Err(); err != nil {
		t.Fatalf("an honest frame poisoned the host: %v", err)
	}
}

// TestHost_RefusesAFrameThatNamesAnotherSender is the negative twin of the case
// above, and the pair is the argument. The frame is byte for byte the one that
// just worked; the only thing that changes is who delivers it. Node 3 sends it
// while the envelope says node 2.
//
// Both ids are members, so membership cannot be what turns it away, and the term
// is high enough that acting on it would move two observable things. The
// identity comparison is the only thing left that can refuse it.
//
// The last assertion is not decoration. Any principal the cluster CA signed
// reaches this handler, so if a refusal poisoned the Host then this very frame
// would be a remote kill switch for any node in the cluster, and the fix would
// have installed the attack it exists to remove.
func TestHost_RefusesAFrameThatNamesAnotherSender(t *testing.T) {
	host, deliver := oneHost(t, 41)

	deliver(3, mustEncodeMsg(t, raft.Message{Kind: raft.MsgApp, From: 2, To: 1, Term: 5}))

	if got := host.Consensus().Leader; got != cluster.None {
		t.Fatalf("a forged sender was recognized as leader %d", got)
	}
	if got := host.Consensus().Term; got != 0 {
		t.Fatalf("a forged sender moved the term to %d", got)
	}
	if n := host.RejectedFrames(); n != 1 {
		t.Fatalf("rejected = %d, want exactly 1", n)
	}
	if err := host.Err(); err != nil {
		t.Fatalf("a refused frame poisoned the host, which would make this frame a remote kill switch: %v", err)
	}
}

// leaderHost drives node 1 into office the only way still open, by having node 2
// grant both rounds honestly under its own name, and leaves the term's no-op
// committed so the leader is ready to replicate. Quorum of three is two, so node
// 1 and node 2 are an election between them.
func leaderHost(t *testing.T, seed uint64) (*Host, cluster.Handler) {
	t.Helper()
	host, deliver := oneHost(t, seed)

	for i := 0; i < 500 && host.Consensus().Role != raft.RoleLeader; i++ {
		if terr := host.Tick(); terr != nil {
			t.Fatalf("tick: %v", terr)
		}
		// The pre-vote round arms on a tick and campaigns for the term above
		// this one; the real vote is answered at the term the campaign reached.
		deliver(2, mustEncodeMsg(t, raft.Message{
			Kind: raft.MsgPreVoteResp, From: 2, To: 1, Term: host.Consensus().Term + 1, Granted: true,
		}))
		deliver(2, mustEncodeMsg(t, raft.Message{
			Kind: raft.MsgVoteResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true,
		}))
	}
	if host.Consensus().Role != raft.RoleLeader {
		t.Fatalf("node 1 never took office, so nothing below is testable")
	}

	// Commit the term's no-op with an honest ack, which is what a leader needs
	// before it can serve a read or commit anything of its own.
	deliver(2, mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true, LastIndex: host.LastIndex(),
	}))
	return host, deliver
}

// TestHost_ForgedAckDoesNotCommitWithoutAQuorum carries the consequence the
// original proof of this defect demonstrated at the raft layer, re-expressed
// where the defense actually lives. A leader writes matchIndex under the id the
// frame declares and then counts a majority out of those entries, so one frame
// claiming to be a follower used to commit an entry no follower ever received.
// A commit is a durability promise: if the leader then failed, the write it had
// already acknowledged would be gone.
//
// The two arms share everything but the sender. The forged ack is delivered by
// node 3 under node 2's name and must not move the applied state; the honest one
// that follows is the same ack from node 2 itself and must.
func TestHost_ForgedAckDoesNotCommitWithoutAQuorum(t *testing.T) {
	host, deliver := leaderHost(t, 47)

	idx, err := host.Upsert(1, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	before := host.StateHash()

	// Node 3 answers under node 2's name, claiming to hold the write.
	deliver(3, mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true, LastIndex: idx,
	}))
	if err := host.Err(); err != nil {
		t.Fatalf("the forged ack poisoned the host: %v", err)
	}
	if host.StateHash() != before {
		t.Fatalf("a forged ack committed and applied entry %d, which no follower ever stored", idx)
	}
	if n := host.RejectedFrames(); n != 1 {
		t.Fatalf("rejected = %d, want exactly 1", n)
	}

	// The same ack from the node that really is node 2 has to work.
	deliver(2, mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true, LastIndex: idx,
	}))
	if host.StateHash() == before {
		t.Fatalf("an honest ack did not commit entry %d", idx)
	}
}

// TestHost_ForgedAckDoesNotConfirmALinearizableRead is the read-round half of
// the same defect. A read index is confirmed by counting answers in a map keyed
// by the id the frame declares, so a single forged ack used to complete the
// round that exists precisely to prove the leader still leads. A leader cut off
// from its followers would serve a read on the strength of one frame from
// whoever sent it.
func TestHost_ForgedAckDoesNotConfirmALinearizableRead(t *testing.T) {
	host, deliver := leaderHost(t, 53)

	ctx, err := host.BeginRead()
	if err != nil {
		t.Fatalf("begin read: %v", err)
	}
	if host.ReadServable(ctx) {
		t.Fatalf("read %d was servable before any answer arrived", ctx)
	}

	deliver(3, mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true,
		LastIndex: host.LastIndex(), ReadCtx: ctx,
	}))
	if err := host.Err(); err != nil {
		t.Fatalf("the forged ack poisoned the host: %v", err)
	}
	if host.ReadServable(ctx) {
		t.Fatalf("a forged ack confirmed read round %d, so the leader would serve it having heard from nobody", ctx)
	}
	if n := host.RejectedFrames(); n != 1 {
		t.Fatalf("rejected = %d, want exactly 1", n)
	}

	deliver(2, mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: host.Consensus().Term, Granted: true,
		LastIndex: host.LastIndex(), ReadCtx: ctx,
	}))
	if !host.ReadServable(ctx) {
		t.Fatalf("an honest ack did not confirm read round %d", ctx)
	}
}

// TestHost_UnexpectedEnvelopeKindDropsInsteadOfKillingTheNode closes the one
// defect in this family that neither identity rule touches. The frame is well
// formed, and its declared sender is the sender: it is honest about everything
// except that its kind is one this node does not serve, which used to come back
// as a fatal error and be latched as sticky poison. One frame, and the node was
// deaf until someone restarted it.
//
// Nothing here needs to be forged, which is what makes it worth its own test:
// the identity of the sender is beside the point, and any principal the cluster
// CA signed could send it. The counter is what distinguishes a frame that was
// dropped from one that was never delivered.
func TestHost_UnexpectedEnvelopeKindDropsInsteadOfKillingTheNode(t *testing.T) {
	host, deliver := oneHost(t, 59)

	frame, err := EncodeClientResponse(2, 1, ClientResponse{ReqID: 1, Status: StatusOK})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	deliver(2, frame)

	if err := host.Err(); err != nil {
		t.Fatalf("one well formed frame of an unserved family ended the node: %v", err)
	}
	if n := host.RejectedFrames(); n != 0 {
		t.Fatalf("the identity check refused an honest frame: rejected = %d", n)
	}
	if n := host.DroppedKindFrames(); n != 1 {
		t.Fatalf("the unserved frame was not counted as dropped: %d, want 1", n)
	}

	// Still alive, and still doing its job.
	if terr := host.Tick(); terr != nil {
		t.Fatalf("the node stopped working after the frame: %v", terr)
	}
	deliver(2, mustEncodeMsg(t, raft.Message{Kind: raft.MsgApp, From: 2, To: 1, Term: 5}))
	if got := host.Consensus().Leader; got != 2 {
		t.Fatalf("the node no longer acts on consensus traffic: leader = %d, want 2", got)
	}
	if n := host.DroppedKindFrames(); n != 1 {
		t.Fatalf("the drop arm swallowed consensus traffic: dropped = %d, want 1", n)
	}
}

// TestRouterHost_RefusesAResponseThatNamesAnotherSender is the client half, and
// what it protects is a rule that was never authentication in the first place.
// A router accepts a response only from the node its live attempt was aimed at,
// which drops a superseded replica answering late. But the rule compares the
// name written on the frame, so anyone who knew which node was being asked could
// write that name and resolve an operation they never served, handing the caller
// a result no replica ever produced. Binding the field is what makes naming the
// target require being the target.
//
// The request id is taken from the frame the router actually sent rather than
// guessed, so the forged answer is the one the attempt is genuinely waiting on
// and the refusal cannot be an accident of correlation.
func TestRouterHost_RefusesAResponseThatNamesAnotherSender(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	router, err := NewRouter(routerID, cluster.ShardMap{Groups: []cluster.Config{cfg}})
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	fabric := cluster.NewSimNet(73, cluster.DefaultSimConfig())
	t.Cleanup(fabric.Close)

	// The replicas only record. What matters is which one was asked and under
	// what request id, so the answer below can be the one being waited for.
	asked := make(chan []byte, 8)
	for _, n := range cfg.Nodes {
		if _, terr := fabric.Endpoint(n.ID, func(_ cluster.NodeID, data []byte) {
			asked <- append([]byte(nil), data...)
		}); terr != nil {
			t.Fatalf("endpoint %d: %v", n.ID, terr)
		}
	}

	var deliver cluster.Handler
	rh, err := NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		deliver = h
		tr, terr := fabric.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("router endpoint: %v", terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("router host: %v", err)
	}
	t.Cleanup(func() { _ = rh.Close() })

	op, err := rh.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	fabric.RunTicks(50)

	var frame []byte
	select {
	case frame = <-asked:
	default:
		t.Fatalf("the router never reached a replica, so nothing below is testable")
	}
	target, reqID := decodeReq(t, frame)

	impostor := cluster.NodeID(2)
	if target == impostor {
		impostor = 3
	}
	answer := mustEncodeRespFrom(t, target, ClientResponse{ReqID: reqID, Status: StatusOK, Index: 5})

	// The impostor sends the target's answer. Same bytes the target would send.
	deliver(impostor, answer)
	if _, ok := rh.Result(op); ok {
		t.Fatalf("an operation was resolved by node %d wearing node %d's name", impostor, target)
	}
	if n := rh.RejectedFrames(); n != 1 {
		t.Fatalf("rejected = %d, want exactly 1", n)
	}
	if err := rh.Err(); err != nil {
		t.Fatalf("a refused frame poisoned the router host: %v", err)
	}

	// The target's own answer has to resolve it.
	deliver(target, answer)
	if _, ok := rh.Result(op); !ok {
		t.Fatalf("the target's own answer did not resolve the operation")
	}
}
