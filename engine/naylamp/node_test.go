package naylamp

import (
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
