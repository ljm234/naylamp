package naylamp

import (
	"errors"
	"math/rand/v2"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// testRNG builds a deterministic generator for a node's election timing, so a
// whole cluster runs reproducibly under one set of seeds.
func testRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for reproducible tests, not security
}

// tickToLeader ticks a single node until it takes office or the budget is
// spent, returning whether it led.
func tickToLeader(t *testing.T, n *Node, budget int) bool {
	t.Helper()
	for i := 0; i < budget && n.Role() != raft.RoleLeader; i++ {
		if _, err := n.Tick(); err != nil {
			t.Fatalf("tick: %v", err)
		}
	}
	return n.Role() == raft.RoleLeader
}

// route delivers one framed message to its destination and returns the
// destination's responses. A message for an absent (closed) node is dropped,
// modeling a down or partitioned peer.
func route(t *testing.T, nodes map[cluster.NodeID]*Node, data []byte) [][]byte {
	t.Helper()
	env, err := cluster.DecodeMessage(data)
	if err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	dst, ok := nodes[env.To]
	if !ok {
		return nil
	}
	out, err := dst.HandleMessage(data)
	if err != nil {
		t.Fatalf("node %d handle: %v", env.To, err)
	}
	return out
}

// pump drains a queue of framed messages, routing each and enqueuing the
// responses, until the queue empties or the step budget is spent.
func pump(t *testing.T, nodes map[cluster.NodeID]*Node, seed [][]byte, budget int) {
	t.Helper()
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		queue = append(queue, route(t, nodes, data)...)
	}
}

// tickAll ticks every present node once in id order and returns all messages
// produced.
func tickAll(t *testing.T, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID) [][]byte {
	t.Helper()
	var msgs [][]byte
	for _, id := range ids {
		n, ok := nodes[id]
		if !ok {
			continue
		}
		out, err := n.Tick()
		if err != nil {
			t.Fatalf("node %d tick: %v", id, err)
		}
		msgs = append(msgs, out...)
	}
	return msgs
}

// leaderOf returns a present leader's id, or None.
func leaderOf(nodes map[cluster.NodeID]*Node, ids []cluster.NodeID) cluster.NodeID {
	for _, id := range ids {
		if n, ok := nodes[id]; ok && n.Role() == raft.RoleLeader {
			return id
		}
	}
	return cluster.None
}

// converged reports whether every present node shares the same last log index
// and the same committed-data hash.
func converged(nodes map[cluster.NodeID]*Node, ids []cluster.NodeID) bool {
	var li uint64
	var h [32]byte
	have := false
	for _, id := range ids {
		n, ok := nodes[id]
		if !ok {
			continue
		}
		if !have {
			li, h, have = n.LastIndex(), n.StateHash(), true
			continue
		}
		if n.LastIndex() != li || n.StateHash() != h {
			return false
		}
	}
	return have
}

// driveUntilLeader ticks and pumps until some present node takes office.
func driveUntilLeader(t *testing.T, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID, rounds int) cluster.NodeID {
	t.Helper()
	for r := 0; r < rounds; r++ {
		if lead := leaderOf(nodes, ids); lead != cluster.None {
			return lead
		}
		pump(t, nodes, tickAll(t, nodes, ids), 4000)
	}
	if lead := leaderOf(nodes, ids); lead != cluster.None {
		return lead
	}
	t.Fatalf("no leader after %d rounds", rounds)
	return cluster.None
}

// driveUntilConverged ticks and pumps until every present node converges, or
// the round budget is spent.
func driveUntilConverged(t *testing.T, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID, rounds int) bool {
	t.Helper()
	for r := 0; r < rounds; r++ {
		pump(t, nodes, tickAll(t, nodes, ids), 4000)
		if converged(nodes, ids) {
			return true
		}
	}
	return converged(nodes, ids)
}

func TestNode_SingleNodeLifecycle(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	n, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(1), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = n.Close() }()

	if !tickToLeader(t, n, 40) {
		t.Fatalf("single node never took office")
	}

	upsert := func(id uint64, vec []float32) {
		if _, _, err := n.Upsert(id, vec); err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
	}
	upsert(1, []float32{1, 0, 0})
	upsert(2, []float32{0, 1, 0})
	upsert(3, []float32{0, 0, 1})

	got, err := n.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(got) != 1 || got[0].ID != 1 {
		t.Fatalf("nearest to [1,0,0] = %+v, want id 1", got)
	}

	if _, _, err := n.Delete(1); err != nil {
		t.Fatalf("delete: %v", err)
	}
	got, err = n.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("search after delete: %v", err)
	}
	if len(got) != 1 || got[0].ID == 1 {
		t.Fatalf("deleted id still nearest: %+v", got)
	}
}

func TestNode_RestartReplaysLog(t *testing.T) {
	dir := t.TempDir()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	n, err := OpenNode(dir, 1, cfg, 3, testRNG(1), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !tickToLeader(t, n, 40) {
		t.Fatalf("no leader")
	}
	for id := uint64(1); id <= 5; id++ {
		vec := []float32{float32(id), 1, 0}
		if _, _, err := n.Upsert(id, vec); err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
	}
	want := n.StateHash()
	if err := n.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	n2, err := OpenNode(dir, 1, cfg, 3, testRNG(1), NodeOptions{})
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	defer func() { _ = n2.Close() }()
	if got := n2.StateHash(); got != want {
		t.Fatalf("state hash changed across replay: %x vs %x", got, want)
	}
	res, err := n2.Search([]float32{5, 1, 0}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(res) != 1 || res[0].ID != 5 {
		t.Fatalf("wrong nearest after replay: %+v", res)
	}
}

func TestNode_RestartWithSnapshot(t *testing.T) {
	dir := t.TempDir()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}}}
	open := func() *Node {
		n, err := OpenNode(dir, 1, cfg, 3, testRNG(1), NodeOptions{CompactEvery: 2})
		if err != nil {
			t.Fatalf("open: %v", err)
		}
		return n
	}
	n := open()
	if !tickToLeader(t, n, 40) {
		t.Fatalf("no leader")
	}
	// Upserts that cross the compaction threshold several times, then more.
	for id := uint64(1); id <= 6; id++ {
		vec := []float32{float32(id), 0, 1}
		if _, _, err := n.Upsert(id, vec); err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
	}
	if n.lastSnapIndex == 0 {
		t.Fatalf("expected a compaction to have taken a snapshot")
	}
	want := n.StateHash()
	if err := n.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	n2 := open()
	defer func() { _ = n2.Close() }()
	if got := n2.StateHash(); got != want {
		t.Fatalf("state hash changed across snapshot restart: %x vs %x", got, want)
	}
	res, err := n2.Search([]float32{1, 0, 1}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(res) != 1 || res[0].ID != 1 {
		t.Fatalf("wrong nearest after snapshot restart: %+v", res)
	}
}

func TestNode_ThreeNodeReplicationConverges(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+100), NodeOptions{})
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
	vectors := map[uint64][]float32{
		1: {1, 0, 0}, 2: {0, 1, 0}, 3: {0, 0, 1}, 4: {1, 1, 0}, 5: {0, 1, 1},
	}
	for id := uint64(1); id <= 5; id++ {
		_, out, err := nodes[lead].Upsert(id, vectors[id])
		if err != nil {
			t.Fatalf("upsert %d on leader %d: %v", id, lead, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("three nodes did not converge")
	}

	want := nodes[ids[0]].StateHash()
	for _, id := range ids {
		if got := nodes[id].StateHash(); got != want {
			t.Fatalf("node %d hash differs: %x vs %x", id, got, want)
		}
	}
	// A follower answers a query from its own replicated copy.
	for _, id := range ids {
		if id == lead {
			continue
		}
		res, err := nodes[id].Search([]float32{1, 0, 0}, 1)
		if err != nil {
			t.Fatalf("follower %d search: %v", id, err)
		}
		if len(res) != 1 || res[0].ID != 1 {
			t.Fatalf("follower %d wrong nearest: %+v", id, res)
		}
	}
}

func TestNode_FollowerRestartCatchesUp(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	dirs := map[cluster.NodeID]string{}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		dir := t.TempDir()
		dirs[id] = dir
		n, err := OpenNode(dir, id, cfg, 3, testRNG(uint64(id)+200), NodeOptions{})
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
	first := map[uint64][]float32{1: {1, 0, 0}, 2: {0, 1, 0}}
	for id := uint64(1); id <= 2; id++ {
		_, out, err := nodes[lead].Upsert(id, first[id])
		if err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("initial cluster did not converge")
	}

	// Close a follower and drop it from routing.
	var follower cluster.NodeID
	for _, id := range ids {
		if id != lead {
			follower = id
			break
		}
	}
	if err := nodes[follower].Close(); err != nil {
		t.Fatalf("close follower %d: %v", follower, err)
	}
	delete(nodes, follower)

	// More commits carry in the surviving majority.
	more := map[uint64][]float32{3: {0, 0, 1}, 4: {1, 1, 0}, 5: {0, 1, 1}}
	for id := uint64(3); id <= 5; id++ {
		_, out, err := nodes[lead].Upsert(id, more[id])
		if err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("majority did not converge without the follower")
	}

	// Reopen the follower and let it catch up.
	n2, err := OpenNode(dirs[follower], follower, cfg, 3, testRNG(uint64(follower)+999), NodeOptions{})
	if err != nil {
		t.Fatalf("reopen follower %d: %v", follower, err)
	}
	nodes[follower] = n2

	if !driveUntilConverged(t, nodes, ids, 500) {
		t.Fatalf("follower did not catch up")
	}
	want := nodes[lead].StateHash()
	for _, id := range ids {
		if got := nodes[id].StateHash(); got != want {
			t.Fatalf("node %d hash differs after catch-up: %x vs %x", id, got, want)
		}
	}
	res, err := nodes[follower].Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("follower search: %v", err)
	}
	if len(res) != 1 || res[0].ID != 1 {
		t.Fatalf("follower wrong nearest after catch-up: %+v", res)
	}
}

func TestNode_LiveSnapshotInstallOnNewFollower(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	// Node 3 stays down from the start; the leader compacts its log before
	// node 3 ever exists, so catch-up can only happen by installation.
	for _, id := range ids[:2] {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+300), NodeOptions{CompactEvery: 2})
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
	for id := uint64(1); id <= 6; id++ {
		vec := []float32{float32(id), 1, 0}
		_, out, err := nodes[lead].Upsert(id, vec)
		if err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("two-node majority did not converge")
	}
	if nodes[lead].lastSnapIndex == 0 {
		t.Fatalf("leader never compacted; the test needs a compacted log")
	}

	// A brand-new replica joins with an empty directory: the entries it
	// needs are gone from the leader's log, so the only path is a live
	// chunked installation through HandleMessage, exercising the
	// rd.Snapshot branch of processReady end to end.
	n3, err := OpenNode(t.TempDir(), 3, cfg, 3, testRNG(303), NodeOptions{CompactEvery: 2})
	if err != nil {
		t.Fatalf("open 3: %v", err)
	}
	nodes[3] = n3
	if !driveUntilConverged(t, nodes, ids, 500) {
		t.Fatalf("new follower did not converge via installation")
	}
	if n3.lastSnapIndex == 0 {
		t.Fatalf("follower converged without installing a snapshot; the install path was not exercised")
	}
	want := nodes[lead].StateHash()
	if got := n3.StateHash(); got != want {
		t.Fatalf("installed follower hash differs: %x vs %x", got, want)
	}
	res, err := n3.Search([]float32{6, 1, 0}, 1)
	if err != nil {
		t.Fatalf("follower search: %v", err)
	}
	if len(res) != 1 || res[0].ID != 6 {
		t.Fatalf("follower wrong nearest after install: %+v", res)
	}
}

func TestNode_LinearizableReadOnLeader(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+400), NodeOptions{})
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
	_, out, err := nodes[lead].Upsert(9, []float32{0, 1, 1})
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}
	pump(t, nodes, out, 4000)
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("cluster did not converge")
	}

	// A follower refuses to begin a linearizable read.
	for _, id := range ids {
		if id == lead {
			continue
		}
		if _, _, err := nodes[id].BeginRead(); !errors.Is(err, raft.ErrNotLeader) {
			t.Fatalf("follower %d began a read: %v", id, err)
		}
		break
	}

	ctx, out, err := nodes[lead].BeginRead()
	if err != nil {
		t.Fatalf("begin read: %v", err)
	}
	if nodes[lead].ReadServable(ctx) {
		t.Fatalf("read servable before the confirmation round completed")
	}
	pump(t, nodes, out, 4000)
	if !nodes[lead].ReadServable(ctx) {
		t.Fatalf("read not servable after the round completed")
	}
	// Served exactly once: the context is forgotten afterwards.
	if nodes[lead].ReadServable(ctx) {
		t.Fatalf("read served twice")
	}
	res, err := nodes[lead].Search([]float32{0, 1, 1}, 1)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(res) != 1 || res[0].ID != 9 {
		t.Fatalf("linearizable read wrong nearest: %+v", res)
	}
}

func TestNode_LeaderKillRestartNoAckedWriteLost(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	dirs := map[cluster.NodeID]string{}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		dir := t.TempDir()
		dirs[id] = dir
		n, err := OpenNode(dir, id, cfg, 3, testRNG(uint64(id)+500), NodeOptions{})
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
	vecs := map[uint64][]float32{
		1: {1, 0, 0}, 2: {0, 1, 0}, 3: {0, 0, 1}, 4: {1, 1, 0}, 5: {0, 1, 1},
	}
	for id := uint64(1); id <= 3; id++ {
		_, out, err := nodes[lead].Upsert(id, vecs[id])
		if err != nil {
			t.Fatalf("upsert %d: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("initial cluster did not converge")
	}

	// Kill the leader: every write acknowledged above must survive it.
	oldLead := lead
	if err := nodes[oldLead].Close(); err != nil {
		t.Fatalf("close leader %d: %v", oldLead, err)
	}
	delete(nodes, oldLead)

	// The surviving majority elects a new leader and keeps committing.
	newLead := driveUntilLeader(t, nodes, ids, 600)
	for id := uint64(4); id <= 5; id++ {
		_, out, err := nodes[newLead].Upsert(id, vecs[id])
		if err != nil {
			t.Fatalf("upsert %d on new leader: %v", id, err)
		}
		pump(t, nodes, out, 4000)
	}
	if !driveUntilConverged(t, nodes, ids, 300) {
		t.Fatalf("majority did not converge after the kill")
	}

	// The old leader restarts from its own disk. It must rejoin as a
	// follower, since pre-vote keeps a rejoiner from disrupting a healthy
	// leadership, and catch up through normal replication.
	n2, err := OpenNode(dirs[oldLead], oldLead, cfg, 3, testRNG(777), NodeOptions{})
	if err != nil {
		t.Fatalf("reopen old leader %d: %v", oldLead, err)
	}
	nodes[oldLead] = n2
	if !driveUntilConverged(t, nodes, ids, 500) {
		t.Fatalf("restarted leader did not catch up")
	}
	if n2.Role() == raft.RoleLeader {
		t.Fatalf("restarted leader retook office against a healthy leadership")
	}
	want := nodes[newLead].StateHash()
	for _, id := range ids {
		if got := nodes[id].StateHash(); got != want {
			t.Fatalf("node %d hash differs after leader restart: %x vs %x", id, got, want)
		}
	}
	// Every acknowledged write, before and after the kill, is present on
	// the restarted node.
	for id := uint64(1); id <= 5; id++ {
		res, err := n2.Search(vecs[id], 1)
		if err != nil {
			t.Fatalf("search %d: %v", id, err)
		}
		if len(res) != 1 || res[0].ID != id {
			t.Fatalf("acked write %d lost after leader kill and restart: %+v", id, res)
		}
	}
}

// clientID is the fake requester the client-serving tests speak as: no node
// carries this id, so a response addressed to it is never routed by pump and a
// test must siphon it off explicitly.
const clientID cluster.NodeID = 99

// mustEncodeReq frames a client request into a cluster envelope or fails.
func mustEncodeReq(t *testing.T, from, to cluster.NodeID, r ClientRequest) []byte {
	t.Helper()
	frame, err := EncodeClientRequest(from, to, r)
	if err != nil {
		t.Fatalf("encode request: %v", err)
	}
	return frame
}

// mustEncodeMsg frames a raft message into a cluster envelope or fails.
func mustEncodeMsg(t *testing.T, m raft.Message) []byte {
	t.Helper()
	frame, err := raft.EncodeMsg(m)
	if err != nil {
		t.Fatalf("encode msg: %v", err)
	}
	return frame
}

// clientResponses decodes every frame in a batch that is addressed to the fake
// client under the response family, so a test can assert on the replies a node
// produced in one HandleMessage call.
func clientResponses(t *testing.T, frames [][]byte, client cluster.NodeID) []ClientResponse {
	t.Helper()
	var resps []ClientResponse
	for _, frame := range frames {
		env, err := cluster.DecodeMessage(frame)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env.To != client || env.Kind != ClientRespKind {
			continue
		}
		resp, err := DecodeClientResponse(env)
		if err != nil {
			t.Fatalf("decode response: %v", err)
		}
		resps = append(resps, resp)
	}
	return resps
}

// pumpCollectClient drains a queue like pump, routing node-to-node frames, but
// siphons off every frame addressed to the fake client and returns the decoded
// responses. It is how a test observes replies that no node would route.
func pumpCollectClient(t *testing.T, nodes map[cluster.NodeID]*Node, seed [][]byte, client cluster.NodeID, budget int) []ClientResponse {
	t.Helper()
	var resps []ClientResponse
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env.To == client {
			if env.Kind == ClientRespKind {
				resp, derr := DecodeClientResponse(env)
				if derr != nil {
					t.Fatalf("decode response: %v", derr)
				}
				resps = append(resps, resp)
			}
			continue
		}
		queue = append(queue, route(t, nodes, data)...)
	}
	return resps
}

// readCtxOf returns the read context an append round carries, extracted from a
// node's outbound frames so a test can confirm that round by hand.
func readCtxOf(t *testing.T, frames [][]byte) uint64 {
	t.Helper()
	for _, frame := range frames {
		m, err := raft.DecodeMsg(frame)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		if m.Kind == raft.MsgApp && m.ReadCtx != 0 {
			return m.ReadCtx
		}
	}
	t.Fatalf("no read context in %d frames", len(frames))
	return 0
}

// craftLeader drives node 1 of a three node config to office by hand, granting
// its pre-vote and vote rounds from peer 2, and returns the term it won. The
// no-op of that term is appended but not yet committed: the same starting point
// makeReadLeader gives the raft core, lifted to whole frames through the node.
func craftLeader(t *testing.T, n *Node) uint64 {
	t.Helper()
	var term uint64
	var queue [][]byte
	for i := 0; i < 200 && n.Role() != raft.RoleLeader; i++ {
		out, err := n.Tick()
		if err != nil {
			t.Fatalf("tick: %v", err)
		}
		queue = append(queue, out...)
		for len(queue) > 0 {
			m, derr := raft.DecodeMsg(queue[0])
			if derr != nil {
				t.Fatalf("decode: %v", derr)
			}
			queue = queue[1:]
			var resp raft.Message
			switch m.Kind {
			case raft.MsgPreVote:
				resp = raft.Message{Kind: raft.MsgPreVoteResp, From: 2, To: 1, Term: m.Term, Granted: true}
			case raft.MsgVote:
				term = m.Term
				resp = raft.Message{Kind: raft.MsgVoteResp, From: 2, To: 1, Term: m.Term, Granted: true}
			default:
				continue
			}
			rout, herr := n.HandleMessage(mustEncodeMsg(t, resp))
			if herr != nil {
				t.Fatalf("handle grant: %v", herr)
			}
			queue = append(queue, rout...)
		}
	}
	if n.Role() != raft.RoleLeader {
		t.Fatalf("crafted node never took office: role=%v", n.Role())
	}
	if term == 0 {
		t.Fatalf("never captured the election term")
	}
	return term
}

// commitNoop grants the leader's own-term no-op from peer 2, giving it the
// majority that commits and applies the no-op.
func commitNoop(t *testing.T, n *Node, term uint64) {
	t.Helper()
	frame := mustEncodeMsg(t, raft.Message{
		Kind: raft.MsgAppResp, From: 2, To: 1, Term: term, Granted: true, LastIndex: n.LastIndex(),
	})
	if _, err := n.HandleMessage(frame); err != nil {
		t.Fatalf("commit no-op: %v", err)
	}
}

func TestNode_ClientWriteAcksOnCommit(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+600), NodeOptions{})
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

	// A write acknowledges on commit, not on propose: the leader's immediate
	// output frames the replication round but carries no client response.
	out, err := nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqUpsert, ReqID: 1, ID: 7, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("upsert handle: %v", err)
	}
	if got := clientResponses(t, out, clientID); len(got) != 0 {
		t.Fatalf("write acknowledged at propose, not commit: %+v", got)
	}
	resps := pumpCollectClient(t, nodes, out, clientID, 4000)
	if len(resps) != 1 || resps[0].ReqID != 1 || resps[0].Status != StatusOK || resps[0].Index == 0 {
		t.Fatalf("upsert not acknowledged OK on commit: %+v", resps)
	}

	// A delete acknowledges the same way.
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqDelete, ReqID: 2, ID: 7}))
	if err != nil {
		t.Fatalf("delete handle: %v", err)
	}
	resps = pumpCollectClient(t, nodes, out, clientID, 4000)
	if len(resps) != 1 || resps[0].ReqID != 2 || resps[0].Status != StatusOK || resps[0].Index == 0 {
		t.Fatalf("delete not acknowledged OK on commit: %+v", resps)
	}

	// Retrying the original upsert acknowledges OK again: the operation is
	// idempotent, so a client that missed the first ack can safely repeat it.
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqUpsert, ReqID: 3, ID: 7, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("retry handle: %v", err)
	}
	resps = pumpCollectClient(t, nodes, out, clientID, 4000)
	if len(resps) != 1 || resps[0].ReqID != 3 || resps[0].Status != StatusOK || resps[0].Index == 0 {
		t.Fatalf("idempotent retry not acknowledged OK: %+v", resps)
	}
}

func TestNode_ClientSearchServesLinearizable(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+700), NodeOptions{})
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

	// A search parks until its read round confirms: no reply in the immediate
	// output, then a linearizable answer once the round completes over pump.
	out, err := nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqSearch, ReqID: 1, K: 1, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("search handle: %v", err)
	}
	if got := clientResponses(t, out, clientID); len(got) != 0 {
		t.Fatalf("search answered before its read round confirmed: %+v", got)
	}
	resps := pumpCollectClient(t, nodes, out, clientID, 4000)
	if len(resps) != 1 || resps[0].ReqID != 1 || resps[0].Status != StatusOK {
		t.Fatalf("search not served OK: %+v", resps)
	}
	if len(resps[0].Neighbors) != 1 || resps[0].Neighbors[0].ID != 1 {
		t.Fatalf("search returned the wrong nearest: %+v", resps[0].Neighbors)
	}
}

func TestNode_ClientRedirectsAndRejects(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+800), NodeOptions{})
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

	// A follower redirects a write with a leader hint.
	var follower cluster.NodeID
	for _, id := range ids {
		if id != lead {
			follower = id
			break
		}
	}
	out, err := nodes[follower].HandleMessage(mustEncodeReq(t, clientID, follower, ClientRequest{Op: ReqUpsert, ReqID: 1, ID: 1, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("follower handle: %v", err)
	}
	resps := clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].Status != StatusNotLeader || resps[0].Leader != lead {
		t.Fatalf("follower did not redirect to the leader: %+v", resps)
	}

	// The leader rejects a wrong-dimension upsert without proposing it.
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqUpsert, ReqID: 2, ID: 2, Vec: []float32{1, 0}}))
	if err != nil {
		t.Fatalf("bad-dim handle: %v", err)
	}
	resps = clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].Status != StatusInvalidArgument {
		t.Fatalf("wrong-dim upsert not rejected InvalidArgument: %+v", resps)
	}

	// The leader rejects a k=0 search the same way.
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqSearch, ReqID: 3, K: 0, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("k=0 handle: %v", err)
	}
	resps = clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].Status != StatusInvalidArgument {
		t.Fatalf("k=0 search not rejected InvalidArgument: %+v", resps)
	}

	// A client body too short to hold a reqID is dropped: no response, no
	// error, and the node stays operational.
	shortFrame, err := cluster.EncodeMessage(cluster.Envelope{From: clientID, To: lead, Kind: ClientKind, Payload: make([]byte, clientReqHeaderSize-1)})
	if err != nil {
		t.Fatalf("encode short: %v", err)
	}
	out, err = nodes[lead].HandleMessage(shortFrame)
	if err != nil {
		t.Fatalf("short body errored instead of dropping: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("short body produced output: %d frames", len(out))
	}
	out, err = nodes[lead].HandleMessage(mustEncodeReq(t, clientID, lead, ClientRequest{Op: ReqUpsert, ReqID: 4, ID: 1, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("post-drop handle: %v", err)
	}
	resps = pumpCollectClient(t, nodes, out, clientID, 4000)
	if len(resps) != 1 || resps[0].ReqID != 4 || resps[0].Status != StatusOK {
		t.Fatalf("node not operational after a dropped garbage frame: %+v", resps)
	}

	// A fresh leader that has not committed its own term's no-op refuses a read
	// retryably, then serves the same search once the no-op commits and the
	// round confirms.
	fresh, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(850), NodeOptions{})
	if err != nil {
		t.Fatalf("open fresh: %v", err)
	}
	defer func() { _ = fresh.Close() }()
	term := craftLeader(t, fresh)
	search := ClientRequest{Op: ReqSearch, ReqID: 10, K: 1, Vec: []float32{1, 0, 0}}
	out, err = fresh.HandleMessage(mustEncodeReq(t, clientID, 1, search))
	if err != nil {
		t.Fatalf("early search handle: %v", err)
	}
	resps = clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].Status != StatusNotReady {
		t.Fatalf("search before term commit not refused NotReady: %+v", resps)
	}
	commitNoop(t, fresh, term)
	out, err = fresh.HandleMessage(mustEncodeReq(t, clientID, 1, search))
	if err != nil {
		t.Fatalf("second search handle: %v", err)
	}
	if got := clientResponses(t, out, clientID); len(got) != 0 {
		t.Fatalf("search served before its round confirmed: %+v", got)
	}
	ctx := readCtxOf(t, out)
	out, err = fresh.HandleMessage(mustEncodeMsg(t, raft.Message{Kind: raft.MsgAppResp, From: 2, To: 1, Term: term, Granted: true, LastIndex: fresh.LastIndex(), ReadCtx: ctx}))
	if err != nil {
		t.Fatalf("confirm handle: %v", err)
	}
	resps = clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].ReqID != 10 || resps[0].Status != StatusOK {
		t.Fatalf("search not served after the round confirmed: %+v", resps)
	}
}

func TestNode_ClientWriteSupersededAnswersNotLeader(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	n, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(900), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = n.Close() }()

	term := craftLeader(t, n)
	commitNoop(t, n, term)

	// A client write parks at the next index, proposed in this leader's term.
	out, err := n.HandleMessage(mustEncodeReq(t, clientID, 1, ClientRequest{Op: ReqUpsert, ReqID: 1, ID: 7, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("upsert handle: %v", err)
	}
	if got := clientResponses(t, out, clientID); len(got) != 0 {
		t.Fatalf("write acknowledged before commit: %+v", got)
	}
	writeIdx := n.LastIndex()

	// Another leader at a higher term overwrites that index with its own entry
	// and commits it. The parked write never survived to commit under its own
	// term, so it must be answered NotLeader, never OK.
	super := raft.Message{
		Kind:     raft.MsgApp,
		From:     3,
		To:       1,
		Term:     term + 1,
		LogIndex: writeIdx - 1,
		LogTerm:  term,
		Entries:  []raft.Entry{{Index: writeIdx, Term: term + 1}},
		Commit:   writeIdx,
	}
	out, err = n.HandleMessage(mustEncodeMsg(t, super))
	if err != nil {
		t.Fatalf("supersede handle: %v", err)
	}
	resps := clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].ReqID != 1 {
		t.Fatalf("superseded write produced %d responses: %+v", len(resps), resps)
	}
	if resps[0].Status != StatusNotLeader {
		t.Fatalf("superseded write not answered NotLeader: %+v", resps[0])
	}
	if n.Role() != raft.RoleFollower {
		t.Fatalf("node did not step down after a higher term: role=%v", n.Role())
	}
}

func TestNode_DepositionFlushesUnconfirmedSearch(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	n, err := OpenNode(t.TempDir(), 1, cfg, 3, testRNG(910), NodeOptions{})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer func() { _ = n.Close() }()

	term := craftLeader(t, n)
	commitNoop(t, n, term)

	// A search parks pending its confirmation round.
	out, err := n.HandleMessage(mustEncodeReq(t, clientID, 1, ClientRequest{Op: ReqSearch, ReqID: 5, K: 1, Vec: []float32{1, 0, 0}}))
	if err != nil {
		t.Fatalf("search handle: %v", err)
	}
	if got := clientResponses(t, out, clientID); len(got) != 0 {
		t.Fatalf("search answered before confirmation: %+v", got)
	}

	// A higher term deposes the leader before the round completes. The parked
	// search is flushed NotLeader in this very step, and the tables empty.
	out, err = n.HandleMessage(mustEncodeMsg(t, raft.Message{Kind: raft.MsgApp, From: 3, To: 1, Term: term + 1}))
	if err != nil {
		t.Fatalf("depose handle: %v", err)
	}
	resps := clientResponses(t, out, clientID)
	if len(resps) != 1 || resps[0].ReqID != 5 || resps[0].Status != StatusNotLeader {
		t.Fatalf("deposition did not flush the search NotLeader: %+v", resps)
	}
	if n.Role() != raft.RoleFollower {
		t.Fatalf("node did not step down: role=%v", n.Role())
	}
	if len(n.pendingSearches) != 0 || len(n.searchQueue) != 0 {
		t.Fatalf("search tables not cleared: %d pending, %d queued", len(n.pendingSearches), len(n.searchQueue))
	}
}
