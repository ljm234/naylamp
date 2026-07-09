package naylamp

import (
	"errors"
	"math"
	"sort"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
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

func TestRouter_ScatterGatherMatchesBruteForceOracle(t *testing.T) {
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

	vec := func(id uint64) []float32 { return []float32{1, float32(id) * 0.15, 0.2} }
	for id := uint64(1); id <= 10; id++ {
		op, frames, uerr := router.Upsert(id, vec(id))
		if uerr != nil {
			t.Fatalf("upsert %d: %v", id, uerr)
		}
		pumpWithRouter(t, nodes, router, frames, 4000)
		if res, ok := router.Result(op); !ok || res.Status != StatusOK || res.Index == 0 {
			t.Fatalf("upsert %d not OK: %+v ok=%v", id, res, ok)
		}
	}

	// Oracle: the exact cosine distance to every id, computed independently of
	// the index. This is cross evidence, two calculation paths agreeing on the
	// order, not a copy of the index's own answer.
	query := []float32{1, 0, 0}
	want := make(map[uint64]float32, 10)
	for id := uint64(1); id <= 10; id++ {
		want[id] = vector.CosineDistance(query, vec(id))
	}
	// Soundness self-check before asserting anything: the pairwise separation is
	// three orders of magnitude above the value tolerance, so the oracle order is
	// unambiguous by construction and no last-ulp divergence between formulas can
	// flip a pair.
	for i := uint64(1); i <= 10; i++ {
		for j := i + 1; j <= 10; j++ {
			if math.Abs(float64(want[i])-float64(want[j])) <= 1e-3 {
				t.Fatalf("oracle separation too small: ids %d and %d at %v and %v", i, j, want[i], want[j])
			}
		}
	}
	// Oracle order: ascending distance, ties broken by ascending id.
	order := make([]uint64, 0, 10)
	for id := uint64(1); id <= 10; id++ {
		order = append(order, id)
	}
	sort.Slice(order, func(a, b int) bool {
		if want[order[a]] != want[order[b]] {
			return want[order[a]] < want[order[b]]
		}
		return order[a] < order[b]
	})

	checkTopK := func(k int) {
		op, frames, serr := router.Search(query, k)
		if serr != nil {
			t.Fatalf("search k=%d: %v", k, serr)
		}
		pumpWithRouter(t, nodes, router, frames, 4000)
		res, ok := router.Result(op)
		if !ok || res.Status != StatusOK || res.Exhausted || res.Index != 0 {
			t.Fatalf("search k=%d did not complete OK: %+v ok=%v", k, res, ok)
		}
		bound := k
		if bound > 10 {
			bound = 10
		}
		if len(res.Neighbors) != bound {
			t.Fatalf("search k=%d returned %d neighbors, want %d", k, len(res.Neighbors), bound)
		}
		for i := 0; i < bound; i++ {
			nb := res.Neighbors[i]
			// (a) exact ids in the oracle's order.
			if nb.ID != order[i] {
				t.Fatalf("k=%d neighbor %d id = %d, oracle %d", k, i, nb.ID, order[i])
			}
			// (b) the served distance matches the oracle within a wide tolerance:
			// the index serves distances through a cosine fast path with norms
			// cached in float32 whose arithmetic differs from the direct
			// computation in the low bits (observed deviation on the order of
			// 3e-8); the tolerance bounds that deviation with wide margin and any
			// real distance bug breaks it, while the exact id order is the
			// property scatter-gather promises.
			if math.Abs(float64(nb.Distance)-float64(want[nb.ID])) > 1e-6 {
				t.Fatalf("k=%d neighbor %d distance = %v, oracle %v", k, i, nb.Distance, want[nb.ID])
			}
		}
	}
	checkTopK(5)
	checkTopK(50)
}

func TestRouter_SearchFollowsRedirectAndConfirms(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1400), NodeOptions{})
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
	vectors := map[uint64][]float32{1: {1, 0, 0}, 2: {0, 1, 0}, 3: {0, 0, 1}}
	for id := uint64(1); id <= 3; id++ {
		_, out, err := nodes[lead].Upsert(id, vectors[id])
		if err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("cluster did not converge")
	}

	// One shard rotated so the first target is a follower: the search leg is
	// redirected to the leader, and its ReadIndex round confirms through pump.
	rotated := rotateSoLeaderNotFirst(cfg.Nodes, lead)
	if rotated[0].ID == lead {
		t.Fatalf("rotation left the leader first")
	}
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: rotated}}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	res, ok := router.Result(op)
	if !ok || res.Status != StatusOK || res.Exhausted {
		t.Fatalf("redirected search did not complete OK: %+v ok=%v", res, ok)
	}
	if len(res.Neighbors) != 1 || res.Neighbors[0].ID != 1 {
		t.Fatalf("search returned the wrong nearest: %+v", res.Neighbors)
	}
}

func TestRouter_SearchExhaustRetiresWholeOp(t *testing.T) {
	cfg0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	cfg1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 2}, {ID: 3}, {ID: 4}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg0, cfg1}}

	n1, err := OpenNode(t.TempDir(), 1, cfg0, 3, testRNG(1), NodeOptions{})
	if err != nil {
		t.Fatalf("open 1: %v", err)
	}
	nodes := map[cluster.NodeID]*Node{1: n1}
	shard1 := []cluster.NodeID{2, 3, 4}
	for _, id := range shard1 {
		n, oerr := OpenNode(t.TempDir(), id, cfg1, 3, testRNG(uint64(id)+1500), NodeOptions{})
		if oerr != nil {
			t.Fatalf("open %d: %v", id, oerr)
		}
		nodes[id] = n
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()
	if !tickToLeader(t, n1, 40) {
		t.Fatalf("node 1 never took office")
	}
	// Shard 1 is left without an election: every node a follower, hint zero.

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	res, ok := router.Result(op)
	if !ok || !res.Exhausted || res.Status != StatusNotLeader {
		t.Fatalf("shard-1 leg did not exhaust the whole op: %+v ok=%v", res, ok)
	}

	// The router is healthy after an exhaust: once shard 1 has a leader a new
	// search completes. That shard holds no data, so an empty neighbor list is
	// correct; the asserted property is the status.
	_ = driveUntilLeader(t, nodes, shard1, 300)
	op, frames, err = router.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("second search: %v", err)
	}
	pumpWithRouter(t, nodes, router, frames, 4000)
	res, ok = router.Result(op)
	if !ok || res.Status != StatusOK || res.Exhausted {
		t.Fatalf("router not healthy after exhaust: %+v ok=%v", res, ok)
	}
}

func TestRouter_SearchGuardsAndRetries(t *testing.T) {
	cfg0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	cfg1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 4}, {ID: 5}, {ID: 6}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg0, cfg1}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// A valid search fans out exactly one frame per shard, in shard order.
	_, frames, err := router.Search([]float32{1, 0, 0}, 3)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(frames) != len(sm.Groups) {
		t.Fatalf("search emitted %d frames, want %d (one per shard)", len(frames), len(sm.Groups))
	}
	// The fan-out order is part of the determinism contract: shard 0 first,
	// each leg aimed at its group's index zero.
	to0, _ := decodeReq(t, frames[0])
	to1, _ := decodeReq(t, frames[1])
	if to0 != 1 || to1 != 4 {
		t.Fatalf("fan-out order wrong: frames to %d and %d, want 1 then 4", to0, to1)
	}

	// (a) A NotReady on the first leg retries the SAME target under a NEW id.
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

	// (b) A StatusOK carrying a nonzero index on a search leg is a crossed write
	// ack: fatal.
	if _, berr := router.HandleMessage(mustEncodeRespFrom(t, target2, ClientResponse{ReqID: reqID2, Status: StatusOK, Index: 5})); berr == nil {
		t.Fatalf("a search-leg OK with a nonzero index was accepted")
	}

	// (c) A non-positive k is rejected locally, without registering an operation.
	before := router.opSeq
	opID, cframes, cerr := router.Search([]float32{1, 0, 0}, 0)
	if !errors.Is(cerr, ErrInvalidArgument) {
		t.Fatalf("k=0 error = %v, want ErrInvalidArgument", cerr)
	}
	if opID != 0 || cframes != nil {
		t.Fatalf("k=0 registered an operation: opID=%d frames=%v", opID, cframes)
	}
	if router.opSeq != before {
		t.Fatalf("k=0 advanced the op counter from %d to %d", before, router.opSeq)
	}

	// (d) A k beyond the wire's uint32 width is rejected locally too: the
	// bound lives in the API, never in a silent narrowing on encode.
	bigK := int(int64(math.MaxUint32) + 1)
	if _, _, derr := router.Search([]float32{1, 0, 0}, bigK); !errors.Is(derr, ErrInvalidArgument) {
		t.Fatalf("oversized k error = %v, want ErrInvalidArgument", derr)
	}
	if router.opSeq != before {
		t.Fatalf("oversized k advanced the op counter from %d to %d", before, router.opSeq)
	}
}

func TestRouter_RetransmitOnTimeout(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("first attempt emitted %d frames, want 1", len(frames))
	}
	target1, reqID1 := decodeReq(t, frames[0])
	// The first attempt spent one of nine tries (three passes over three nodes).
	if got := router.ops[op].attemptsLeft; got != 8 {
		t.Fatalf("after the first attempt attemptsLeft = %d, want 8", got)
	}

	// A tick short of the budget does not retransmit: the attempt was stamped at
	// tick 0 and is not yet old enough.
	if out, terr := router.Tick(retransmitTimeout - 1); terr != nil || len(out) != 0 {
		t.Fatalf("early tick retransmitted: out=%d err=%v", len(out), terr)
	}
	if got := router.ops[op].attemptsLeft; got != 8 {
		t.Fatalf("early tick spent an attempt: attemptsLeft = %d, want 8", got)
	}

	// A tick at the budget retransmits once: a fresh request id to the same
	// target, and one more attempt spent.
	out, terr := router.Tick(retransmitTimeout)
	if terr != nil {
		t.Fatalf("tick: %v", terr)
	}
	if len(out) != 1 {
		t.Fatalf("timeout retransmitted %d frames, want 1", len(out))
	}
	target2, reqID2 := decodeReq(t, out[0])
	if target2 != target1 {
		t.Fatalf("retransmit aimed at %d, want the same target %d", target2, target1)
	}
	if reqID2 == reqID1 {
		t.Fatalf("retransmit reused request id %d", reqID1)
	}
	if got := router.ops[op].attemptsLeft; got != 7 {
		t.Fatalf("retransmit did not spend an attempt: attemptsLeft = %d, want 7", got)
	}

	// The live attempt (reqID2) is acknowledged: the op resolves OK.
	if o, herr := router.HandleMessage(mustEncodeRespFrom(t, target2, ClientResponse{ReqID: reqID2, Status: StatusOK, Index: 5})); herr != nil || o != nil {
		t.Fatalf("ok handle: out=%v err=%v", o, herr)
	}
	res, ok := router.Result(op)
	if !ok || res.Status != StatusOK || res.Index != 5 || res.Exhausted {
		t.Fatalf("retransmitted op did not resolve OK: %+v ok=%v", res, ok)
	}

	// The superseded attempt (reqID1) was consumed by the retransmit, so a late
	// reply for it is a stale duplicate: dropped, and the op cannot resolve a
	// second time. This is the router-level single resolution of DEFER-011; the
	// node's own log dedup is DEFER-013 and is not claimed here.
	if o, herr := router.HandleMessage(mustEncodeRespFrom(t, target1, ClientResponse{ReqID: reqID1, Status: StatusOK, Index: 5})); herr != nil || o != nil {
		t.Fatalf("stale reply for the superseded attempt: out=%v err=%v", o, herr)
	}
	if _, ok := router.Result(op); ok {
		t.Fatalf("op resolved a second time after a stale reply")
	}
}

func TestRouter_TimeoutRespectsExhaustion(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("first attempt emitted %d frames, want 1", len(frames))
	}

	// Nothing ever answers. Each tick past the budget burns exactly one attempt.
	// The budget is three passes over three nodes, nine attempts: one spent on
	// the first emit, eight retransmits burn the rest, and the next tick finds
	// nothing left and retires the op as exhausted.
	now := cluster.Tick(0)
	var lastOut [][]byte
	for step := 0; step < 20; step++ {
		now += retransmitTimeout
		out, terr := router.Tick(now)
		if terr != nil {
			t.Fatalf("tick %d: %v", step, terr)
		}
		lastOut = out
		if _, done := router.results[op]; done {
			break
		}
	}

	res, ok := router.Result(op)
	if !ok || !res.Exhausted {
		t.Fatalf("timeouts did not retire the op as exhausted: %+v ok=%v", res, ok)
	}
	// The exhausting tick emits no frame, and the budget holds: the first emit
	// plus eight retransmits is exactly nine attempts, never an unbounded stream.
	if len(lastOut) != 0 {
		t.Fatalf("the exhausting tick still emitted %d frames", len(lastOut))
	}
	if router.reqSeq != 9 {
		t.Fatalf("exhaust used %d attempts, want exactly 9", router.reqSeq)
	}

	// A further tick is a no-op: the op is gone, nothing re-emits, no panic.
	now += retransmitTimeout
	if out, terr := router.Tick(now); terr != nil || len(out) != 0 {
		t.Fatalf("tick after exhaust re-emitted: out=%d err=%v", len(out), terr)
	}
}

func TestRouter_DropsForeignOrigin(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if len(frames) != 1 {
		t.Fatalf("first attempt emitted %d frames, want 1", len(frames))
	}
	target1, reqID1 := decodeReq(t, frames[0])

	// A different group member answers under the right request id. It is not the
	// node this attempt was aimed at, so DEFER-012 drops it as stale: no re-emit,
	// no resolution, and the attempt stays live for its real target.
	foreign := cluster.NodeID(2)
	if target1 == foreign {
		foreign = 3
	}
	out, herr := router.HandleMessage(mustEncodeRespFrom(t, foreign, ClientResponse{ReqID: reqID1, Status: StatusOK, Index: 5}))
	if herr != nil {
		t.Fatalf("foreign-origin handle errored: %v", herr)
	}
	if out != nil {
		t.Fatalf("foreign-origin reply re-emitted %d frames", len(out))
	}
	if _, ok := router.Result(op); ok {
		t.Fatalf("a reply from the wrong origin resolved the op")
	}

	// The same reply from the correct target does resolve it: a right-origin
	// reply passes exactly as before, so the check is additive.
	out, herr = router.HandleMessage(mustEncodeRespFrom(t, target1, ClientResponse{ReqID: reqID1, Status: StatusOK, Index: 5}))
	if herr != nil {
		t.Fatalf("correct-origin handle errored: %v", herr)
	}
	if out != nil {
		t.Fatalf("terminal ok re-emitted %d frames", len(out))
	}
	res, ok := router.Result(op)
	if !ok || res.Status != StatusOK || res.Index != 5 || res.Exhausted {
		t.Fatalf("correct-origin reply did not resolve OK: %+v ok=%v", res, ok)
	}
}

func TestRouter_TickWithoutPendingIsNoop(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}

	// No operation is in flight: a tick, even a large one, emits nothing and does
	// not panic.
	out, terr := router.Tick(1000)
	if terr != nil {
		t.Fatalf("tick on an idle router: %v", terr)
	}
	if out != nil {
		t.Fatalf("idle tick emitted %d frames", len(out))
	}

	// It stays a no-op after an op has fully resolved and left no pending attempt
	// behind.
	op, frames, err := router.Upsert(7, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	target, reqID := decodeReq(t, frames[0])
	if _, herr := router.HandleMessage(mustEncodeRespFrom(t, target, ClientResponse{ReqID: reqID, Status: StatusOK, Index: 5})); herr != nil {
		t.Fatalf("ok handle: %v", herr)
	}
	if res, ok := router.Result(op); !ok || res.Status != StatusOK {
		t.Fatalf("op did not resolve OK: %+v ok=%v", res, ok)
	}
	if out, terr := router.Tick(2000); terr != nil || out != nil {
		t.Fatalf("tick after a resolved op re-emitted: out=%v err=%v", out, terr)
	}
}
