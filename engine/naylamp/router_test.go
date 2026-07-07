package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
)

// routerID is the fake coordinator identity the router speaks as: it is a
// member of no shard group, so a node never confuses its traffic with a peer's.
const routerID cluster.NodeID = 90

// pumpWithRouter drains a queue like pump, routing node-to-node frames and
// delivering any frame addressed to the router into router.HandleMessage,
// enqueuing whatever it re-emits. Frames for an absent destination are dropped.
func pumpWithRouter(t *testing.T, nodes map[cluster.NodeID]*Node, router *Router, seed [][]byte, budget int) {
	t.Helper()
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env.To == routerID {
			out, herr := router.HandleMessage(data)
			if herr != nil {
				t.Fatalf("router handle: %v", herr)
			}
			queue = append(queue, out...)
			continue
		}
		queue = append(queue, route(t, nodes, data)...)
	}
}

// pumpCollectFramesTo drains a queue like pump, routing node-to-node frames but
// collecting (not delivering) every frame addressed to dest, so a test can hold
// a response frame and deliver it to the router itself, more than once.
func pumpCollectFramesTo(t *testing.T, nodes map[cluster.NodeID]*Node, seed [][]byte, dest cluster.NodeID, budget int) [][]byte {
	t.Helper()
	var collected [][]byte
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env.To == dest {
			collected = append(collected, data)
			continue
		}
		queue = append(queue, route(t, nodes, data)...)
	}
	return collected
}

// decodeReq returns the destination and request id of one emitted request
// frame, so a test can assert where the router aimed and under which id.
func decodeReq(t *testing.T, frame []byte) (cluster.NodeID, uint64) {
	t.Helper()
	env, err := cluster.DecodeMessage(frame)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	req, err := DecodeClientRequest(env)
	if err != nil {
		t.Fatalf("decode request: %v", err)
	}
	return env.To, req.ReqID
}

// mustEncodeRespFrom frames a client response from a target back to the router.
func mustEncodeRespFrom(t *testing.T, from cluster.NodeID, resp ClientResponse) []byte {
	t.Helper()
	frame, err := EncodeClientResponse(from, routerID, resp)
	if err != nil {
		t.Fatalf("encode response: %v", err)
	}
	return frame
}

// rotateSoLeaderNotFirst returns the group's nodes with the leader moved to the
// end, so the first target is guaranteed to be a follower.
func rotateSoLeaderNotFirst(nodes []cluster.NodeAddr, lead cluster.NodeID) []cluster.NodeAddr {
	out := make([]cluster.NodeAddr, 0, len(nodes))
	var leadAddr cluster.NodeAddr
	for _, n := range nodes {
		if n.ID == lead {
			leadAddr = n
			continue
		}
		out = append(out, n)
	}
	return append(out, leadAddr)
}

// leaderAtIndex returns the group's nodes rearranged so the leader sits at pos,
// with the other members keeping their relative order around it.
func leaderAtIndex(nodes []cluster.NodeAddr, lead cluster.NodeID, pos int) []cluster.NodeAddr {
	others := make([]cluster.NodeAddr, 0, len(nodes)-1)
	var leadAddr cluster.NodeAddr
	for _, n := range nodes {
		if n.ID == lead {
			leadAddr = n
			continue
		}
		others = append(others, n)
	}
	out := make([]cluster.NodeAddr, 0, len(nodes))
	out = append(out, others[:pos]...)
	out = append(out, leadAddr)
	out = append(out, others[pos:]...)
	return out
}

func TestRouter_WritesLandOnTheirShard(t *testing.T) {
	cfg0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	cfg1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 2}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg0, cfg1}}

	n1, err := OpenNode(t.TempDir(), 1, cfg0, 3, testRNG(1), NodeOptions{})
	if err != nil {
		t.Fatalf("open 1: %v", err)
	}
	n2, err := OpenNode(t.TempDir(), 2, cfg1, 3, testRNG(2), NodeOptions{})
	if err != nil {
		t.Fatalf("open 2: %v", err)
	}
	nodes := map[cluster.NodeID]*Node{1: n1, 2: n2}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()
	if !tickToLeader(t, n1, 40) {
		t.Fatalf("node 1 never took office")
	}
	if !tickToLeader(t, n2, 40) {
		t.Fatalf("node 2 never took office")
	}

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// Find the first id that routes to each shard without hardcoding the hash.
	var id0, id1 uint64
	found0, found1 := false, false
	for cand := uint64(1); cand < 100000 && (!found0 || !found1); cand++ {
		switch sm.ShardFor(cand) {
		case 0:
			if !found0 {
				id0, found0 = cand, true
			}
		case 1:
			if !found1 {
				id1, found1 = cand, true
			}
		}
	}
	if !found0 || !found1 {
		t.Fatalf("could not find ids for both shards")
	}

	op0, frames, err := router.Upsert(id0, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert shard 0: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	if res, ok := router.Result(op0); !ok || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("shard-0 upsert did not complete OK: %+v ok=%v", res, ok)
	}

	op1, frames, err := router.Upsert(id1, []float32{0, 1, 0})
	if err != nil {
		t.Fatalf("upsert shard 1: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	if res, ok := router.Result(op1); !ok || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("shard-1 upsert did not complete OK: %+v ok=%v", res, ok)
	}

	// Each write landed on its own shard's node.
	if got, err := n1.Search([]float32{1, 0, 0}, 1); err != nil || len(got) != 1 || got[0].ID != id0 {
		t.Fatalf("shard-0 write not on node 1: %+v err=%v", got, err)
	}
	if got, err := n2.Search([]float32{0, 1, 0}, 1); err != nil || len(got) != 1 || got[0].ID != id1 {
		t.Fatalf("shard-1 write not on node 2: %+v err=%v", got, err)
	}
	// And nowhere else: the other shard's node does not hold it.
	if got, err := n2.Search([]float32{1, 0, 0}, 1); err != nil || (len(got) != 0 && got[0].ID == id0) {
		t.Fatalf("shard-0 id leaked into node 2: %+v err=%v", got, err)
	}
	if got, err := n1.Search([]float32{0, 1, 0}, 1); err != nil || (len(got) != 0 && got[0].ID == id1) {
		t.Fatalf("shard-1 id leaked into node 1: %+v err=%v", got, err)
	}
}

func TestRouter_RedirectFollowsTheHint(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1100), NodeOptions{})
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

	lead := driveUntilLeader(t, nodes, ids, 300)
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("cluster did not converge")
	}

	// One shard whose group is rotated so its first target is a follower: the
	// first attempt must be redirected to the leader by the hint.
	rotated := rotateSoLeaderNotFirst(cfg.Nodes, lead)
	if rotated[0].ID == lead {
		t.Fatalf("rotation left the leader first")
	}
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: rotated}}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	if res, ok := router.Result(op); !ok || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("redirected upsert did not complete OK: %+v ok=%v", res, ok)
	}
}

func TestRouter_HintlessRetryIsBoundedAndRecovers(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1200), NodeOptions{})
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

	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// No election has happened: every node is a follower with no known leader,
	// so every response is NotLeader with a zero hint. The router cycles the
	// group and exhausts a bounded budget of three passes.
	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	res, ok := router.Result(op)
	if !ok || !res.Exhausted || res.Status != StatusNotLeader {
		t.Fatalf("hintless retry did not exhaust to NotLeader: %+v ok=%v", res, ok)
	}
	// The budget is a promise: exactly three passes over three nodes.
	if router.reqSeq != 9 {
		t.Fatalf("exhaust used %d attempts, want exactly 9", router.reqSeq)
	}

	// The router is healthy after an exhaust: once a leader exists a new
	// operation completes.
	_ = driveUntilLeader(t, nodes, ids, 300)
	op, frames, err = router.Upsert(8, []float32{0, 1, 0})
	if err != nil {
		t.Fatalf("second upsert: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	if res, ok := router.Result(op); !ok || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("router not healthy after exhaust: %+v ok=%v", res, ok)
	}
}

func TestRouter_TerminalAnswersAndStaleResponses(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1300), NodeOptions{})
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

	lead := driveUntilLeader(t, nodes, ids, 300)
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("cluster did not converge")
	}
	// Leader at index 1: index 0 is a follower (so the first target redirects),
	// and the group's next target after index 0 is the leader itself.
	group := leaderAtIndex(cfg.Nodes, lead, 1)
	if group[0].ID == lead || group[1].ID != lead {
		t.Fatalf("group not arranged with the leader at index 1: %+v lead=%d", group, lead)
	}
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: group}}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// (a) A wrong-dimension upsert is terminal InvalidArgument, not exhausted.
	opBad, frames, err := router.Upsert(7, []float32{1, 0})
	if err != nil {
		t.Fatalf("bad-dim upsert: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	res, ok := router.Result(opBad)
	if !ok || res.Status != StatusInvalidArgument || res.Exhausted {
		t.Fatalf("bad-dim not terminal InvalidArgument: %+v ok=%v", res, ok)
	}
	// (b) Result is one-shot.
	if _, ok := router.Result(opBad); ok {
		t.Fatalf("Result returned a consumed op a second time")
	}

	// (c) A valid upsert held back from the cluster. A crafted NotReady retries
	// the SAME target under a NEW request id.
	opLive, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("valid upsert: %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("first attempt emitted %d frames, want 1", len(frames))
	}
	target1, reqID1 := decodeReq(t, frames[0])
	out, err := router.HandleMessage(mustEncodeRespFrom(t, target1, ClientResponse{ReqID: reqID1, Status: StatusNotReady}))
	if err != nil {
		t.Fatalf("not-ready handle: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("not-ready re-emitted %d frames, want 1", len(out))
	}
	target2, reqID2 := decodeReq(t, out[0])
	if target2 != target1 {
		t.Fatalf("not-ready retried target %d, want the same %d", target2, target1)
	}
	if reqID2 == reqID1 {
		t.Fatalf("retry reused request id %d", reqID1)
	}

	// (d) A NotLeader with an out-of-group hint advances to the NEXT target in
	// the group, never chasing the bogus hint.
	out, err = router.HandleMessage(mustEncodeRespFrom(t, target2, ClientResponse{ReqID: reqID2, Status: StatusNotLeader, Leader: 77}))
	if err != nil {
		t.Fatalf("not-leader handle: %v", err)
	}
	if len(out) != 1 {
		t.Fatalf("not-leader re-emitted %d frames, want 1", len(out))
	}
	target3, reqID3 := decodeReq(t, out[0])
	if target3 == 77 {
		t.Fatalf("router chased an out-of-group hint to 77")
	}
	if want := group[1].ID; target3 != want {
		t.Fatalf("router advanced to %d, want the next target %d", target3, want)
	}
	if reqID3 == reqID2 {
		t.Fatalf("advance reused request id %d", reqID2)
	}

	// (e) Deliver the live attempt to the cluster by hand, collecting the
	// router-bound responses so the terminal OK can be delivered twice. target3
	// is the leader, so it commits and acks with an index.
	respFrames := pumpCollectFramesTo(t, nodes, out, routerID, 4000)
	if len(respFrames) == 0 {
		t.Fatalf("no response reached the router")
	}
	reout, err := router.HandleMessage(respFrames[0])
	if err != nil {
		t.Fatalf("ok handle: %v", err)
	}
	if len(reout) != 0 {
		t.Fatalf("terminal ok re-emitted %d frames", len(reout))
	}
	res, ok = router.Result(opLive)
	if !ok || res.Status != StatusOK || res.Index == 0 || res.Exhausted {
		t.Fatalf("live attempt did not complete OK: %+v ok=%v", res, ok)
	}
	// The same response delivered again is a stale duplicate: ignored, and the
	// consumed result does not reappear.
	reout, err = router.HandleMessage(respFrames[0])
	if err != nil {
		t.Fatalf("stale response errored: %v", err)
	}
	if reout != nil {
		t.Fatalf("stale response re-emitted %d frames", len(reout))
	}
	if _, ok := router.Result(opLive); ok {
		t.Fatalf("consumed result reappeared after a stale response")
	}
}
