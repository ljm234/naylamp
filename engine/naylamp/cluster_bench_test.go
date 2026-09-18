package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

// Cluster benchmarks for gate 3.5 (task 3.5.9). These measure the cost the
// replicated path adds over the standalone engine, and the cost fan-out adds
// over a single shard, so the value of consensus on the data path is visible
// as a number rather than a claim.
//
// Honesty about what these numbers are. The absolute figures are fsync bound
// and hardware dependent: a write to a replicated shard blocks on real disk
// syncs, so the ns/op moves with the machine and the filesystem, not only with
// the code. The signal is not any single figure but the RELATION between them:
// standalone upsert versus a one replica shard versus a three replica shard
// isolates the router and the replication cost, and a one shard search versus
// a two shard search shows the net cost of sharding the same corpus, the
// fan-out and the merge offset slightly by smaller per-shard indexes. The
// failover benchmark reports the election latency in tick rounds alongside
// the wall time.
//
// These functions are Benchmark*, so a normal `go test` run never executes
// them: they need `-bench`, and the coverage sweep and CI stay untouched. The
// final table for the gate is generated at the seal by one full run saved to
// engine/naylamp/cluster_bench.txt, which is gitignored.
//
// No SimNet here. The harness moves frames synchronously in the pump style of
// node_test.go and router_test.go, deterministic under fixed seeds, so the
// benchmarks measure work and not a simulated clock. The pure package test
// helpers testRNG, leaderOf and converged, and the constant routerID, are
// reused as is; every helper that had to be adapted from *testing.T to
// *testing.B is a local bench-prefixed copy of its node_test.go or
// router_test.go original.

// benchVec is the deterministic, injective vector for an id, the same shape the
// scatter-gather oracle test uses: distinct ids land at distinct, well
// separated cosine distances from {1,0,0}.
func benchVec(id uint64) []float32 {
	return []float32{1, float32(id) * 0.15, 0.2}
}

// benchRoute delivers one framed message to its destination and returns the
// destination's responses, dropping a message for an absent node. It is the
// *testing.B copy of route in node_test.go.
func benchRoute(b *testing.B, nodes map[cluster.NodeID]*Node, data []byte) [][]byte {
	b.Helper()
	env, err := cluster.DecodeMessage(data)
	if err != nil {
		b.Fatalf("decode envelope: %v", err)
	}
	dst, ok := nodes[env.To]
	if !ok {
		return nil
	}
	out, err := dst.HandleMessage(data)
	if err != nil {
		b.Fatalf("node %d handle: %v", env.To, err)
	}
	return out
}

// benchTickAll ticks every present node once in id order and returns the
// messages produced. It is the *testing.B copy of tickAll in node_test.go.
func benchTickAll(b *testing.B, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID) [][]byte {
	b.Helper()
	var msgs [][]byte
	for _, id := range ids {
		n, ok := nodes[id]
		if !ok {
			continue
		}
		out, err := n.Tick()
		if err != nil {
			b.Fatalf("node %d tick: %v", id, err)
		}
		msgs = append(msgs, out...)
	}
	return msgs
}

// benchPump drains a queue of framed messages, routing each and enqueuing the
// responses, until the queue empties or the step budget is spent. It is the
// *testing.B copy of pump in node_test.go.
func benchPump(b *testing.B, nodes map[cluster.NodeID]*Node, seed [][]byte, budget int) {
	b.Helper()
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		queue = append(queue, benchRoute(b, nodes, data)...)
	}
}

// benchPumpWithRouter drains a queue like benchPump, routing node-to-node
// frames and delivering any frame addressed to the router into
// router.HandleMessage, enqueuing whatever it re-emits. It is the *testing.B
// copy of pumpWithRouter in router_test.go.
func benchPumpWithRouter(b *testing.B, nodes map[cluster.NodeID]*Node, router *Router, seed [][]byte, budget int) {
	b.Helper()
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			b.Fatalf("decode envelope: %v", err)
		}
		if env.To == routerID {
			out, herr := router.HandleMessage(data)
			if herr != nil {
				b.Fatalf("router handle: %v", herr)
			}
			queue = append(queue, out...)
			continue
		}
		queue = append(queue, benchRoute(b, nodes, data)...)
	}
}

// benchDriveUntilLeader ticks and pumps until some present node takes office,
// failing the benchmark if none does within the round budget. It is the
// *testing.B copy of driveUntilLeader in node_test.go.
func benchDriveUntilLeader(b *testing.B, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID, rounds int) cluster.NodeID {
	b.Helper()
	for r := 0; r < rounds; r++ {
		if lead := leaderOf(nodes, ids); lead != cluster.None {
			return lead
		}
		benchPump(b, nodes, benchTickAll(b, nodes, ids), 4000)
	}
	if lead := leaderOf(nodes, ids); lead != cluster.None {
		return lead
	}
	b.Fatalf("no leader after %d rounds", rounds)
	return cluster.None
}

// benchDriveUntilLeaderCounting drives like benchDriveUntilLeader but returns
// the number of tick rounds a leader took to emerge, so the failover benchmark
// can report election latency in rounds. It fails if none emerges in budget.
func benchDriveUntilLeaderCounting(b *testing.B, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID, budget int) (cluster.NodeID, int) {
	b.Helper()
	for r := 0; r < budget; r++ {
		if lead := leaderOf(nodes, ids); lead != cluster.None {
			return lead, r
		}
		benchPump(b, nodes, benchTickAll(b, nodes, ids), 4000)
	}
	b.Fatalf("no survivor took office within %d rounds", budget)
	return cluster.None, budget
}

// benchDriveUntilConverged ticks and pumps until every present node converges,
// or the round budget is spent. It is the *testing.B copy of
// driveUntilConverged in node_test.go.
func benchDriveUntilConverged(b *testing.B, nodes map[cluster.NodeID]*Node, ids []cluster.NodeID, rounds int) bool {
	b.Helper()
	for r := 0; r < rounds; r++ {
		benchPump(b, nodes, benchTickAll(b, nodes, ids), 4000)
		if converged(nodes, ids) {
			return true
		}
	}
	return converged(nodes, ids)
}

// benchLeaderFirst returns the group's nodes with the leader placed first, so a
// router built over it hits the leader on its first attempt and a redirect
// never enters the steady-state measurement.
func benchLeaderFirst(group []cluster.NodeAddr, lead cluster.NodeID) []cluster.NodeAddr {
	out := make([]cluster.NodeAddr, 0, len(group))
	for _, n := range group {
		if n.ID == lead {
			out = append(out, n)
		}
	}
	for _, n := range group {
		if n.ID != lead {
			out = append(out, n)
		}
	}
	return out
}

// BenchmarkEngineUpsertStandalone measures a pure in-memory upsert against the
// standalone engine: no durability, no consensus, no router. It isolates the
// ceiling, the cost of the store and the HNSW insert alone, that every
// replicated write is measured against.
func BenchmarkEngineUpsertStandalone(b *testing.B) {
	e := New()
	col, err := e.CreateCollection("bench", 3, vector.CosineDistance, 1)
	if err != nil {
		b.Fatalf("create collection: %v", err)
	}
	const idRange = 64
	for i := 0; b.Loop(); i++ {
		id := uint64(i%idRange) + 1
		if uerr := col.Upsert(id, benchVec(id)); uerr != nil {
			b.Fatalf("upsert: %v", uerr)
		}
	}
}

// benchWriteAckReplicated drives one upsert to a definitive ack through the
// router over a group of len(ids) replicas, the leader elected outside the
// timer. Every op pays the router and one real fsync; the difference between
// the one and three replica cases is the replication cost, the extra fsyncs,
// messages and quorum wait a committed write needs when it must be replicated.
func benchWriteAckReplicated(b *testing.B, ids []cluster.NodeID) {
	b.Helper()
	cfgNodes := make([]cluster.NodeAddr, len(ids))
	for i, id := range ids {
		cfgNodes[i] = cluster.NodeAddr{ID: id}
	}
	cfg := cluster.Config{Nodes: cfgNodes}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(b.TempDir(), id, cfg, 3, testRNG(uint64(id)+2000), NodeOptions{})
		if err != nil {
			b.Fatalf("open %d: %v", id, err)
		}
		nodes[id] = n
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()

	lead := benchDriveUntilLeader(b, nodes, ids, 2000)
	group := benchLeaderFirst(cfgNodes, lead)
	router, err := NewRouter(routerID, cluster.ShardMap{Groups: []cluster.Config{{Nodes: group}}})
	if err != nil {
		b.Fatalf("new router: %v", err)
	}

	const idRange = 64
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		id := uint64(i%idRange) + 1
		op, frames, uerr := router.Upsert(id, benchVec(id))
		if uerr != nil {
			b.Fatalf("upsert: %v", uerr)
		}
		benchPumpWithRouter(b, nodes, router, frames, 8000)
		res, ok := router.Result(op)
		if !ok || res.Status != StatusOK || res.Exhausted || res.Index == 0 {
			b.Fatalf("upsert not acked OK: %+v ok=%v", res, ok)
		}
	}
}

// BenchmarkWriteAckReplicated1 measures an upsert to ack through the router over
// a single replica shard. It isolates the router and one fsync with no
// replication: the floor a replicated write starts from.
func BenchmarkWriteAckReplicated1(b *testing.B) {
	benchWriteAckReplicated(b, []cluster.NodeID{1})
}

// BenchmarkWriteAckReplicated3 measures an upsert to ack through the router over
// a three replica shard. Its delta over BenchmarkWriteAckReplicated1 is the
// replication cost: the follower fsyncs, the replication messages and the
// quorum wait a committed write pays once it is replicated.
func BenchmarkWriteAckReplicated3(b *testing.B) {
	benchWriteAckReplicated(b, []cluster.NodeID{1, 2, 3})
}

// benchScatterGather drives one search to a result through the router across
// single node shards, with the same total vector set preloaded. The delta
// between one and two shards is the net cost of sharding the same corpus:
// the fan-out and the merge, offset slightly by each shard searching a
// smaller index, which is negligible at this scale.
func benchScatterGather(b *testing.B, shards int) {
	b.Helper()
	groups := make([]cluster.Config, shards)
	ids := make([]cluster.NodeID, 0, shards)
	nodes := map[cluster.NodeID]*Node{}
	for s := 0; s < shards; s++ {
		id := cluster.NodeID(s + 1) //nolint:gosec // s is a small positive shard index
		groups[s] = cluster.Config{Nodes: []cluster.NodeAddr{{ID: id}}}
		ids = append(ids, id)
	}
	sm := cluster.ShardMap{Groups: groups}
	for s := 0; s < shards; s++ {
		id := ids[s]
		n, err := OpenNode(b.TempDir(), id, groups[s], 3, testRNG(uint64(id)+3000), NodeOptions{})
		if err != nil {
			b.Fatalf("open %d: %v", id, err)
		}
		nodes[id] = n
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()
	// Each single node shard elects itself before any work is timed.
	for _, id := range ids {
		if benchDriveUntilLeader(b, nodes, []cluster.NodeID{id}, 400) != id {
			b.Fatalf("shard node %d never took office", id)
		}
	}

	router, err := NewRouter(routerID, sm)
	if err != nil {
		b.Fatalf("new router: %v", err)
	}
	// Preload the same total set across all shards; the router hashes each id to
	// its shard, so the vectors spread over the shards without being placed by
	// hand.
	const total = 100
	for id := uint64(1); id <= total; id++ {
		op, frames, uerr := router.Upsert(id, benchVec(id))
		if uerr != nil {
			b.Fatalf("preload upsert %d: %v", id, uerr)
		}
		benchPumpWithRouter(b, nodes, router, frames, 8000)
		if res, ok := router.Result(op); !ok || res.Status != StatusOK || res.Index == 0 {
			b.Fatalf("preload %d not OK: %+v ok=%v", id, res, ok)
		}
	}

	query := []float32{1, 0, 0}
	const k = 10
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		op, frames, serr := router.Search(query, k)
		if serr != nil {
			b.Fatalf("search: %v", serr)
		}
		benchPumpWithRouter(b, nodes, router, frames, 8000)
		res, ok := router.Result(op)
		if !ok || res.Status != StatusOK || res.Exhausted || res.Index != 0 {
			b.Fatalf("search not OK: %+v ok=%v", res, ok)
		}
	}
}

// BenchmarkScatterGatherK1 measures a top-10 search through the router over one
// shard: a single leg and a trivial merge. It is the fan-out baseline.
func BenchmarkScatterGatherK1(b *testing.B) {
	benchScatterGather(b, 1)
}

// BenchmarkScatterGatherK2 measures a top-10 search through the router over two
// shards: two legs fanned out and merged into a global top-k. Its delta over
// BenchmarkScatterGatherK1 is the fan-out and merge cost.
func BenchmarkScatterGatherK2(b *testing.B) {
	benchScatterGather(b, 2)
}

// BenchmarkFailoverElection measures how long a three node group takes to
// recover from the loss of its leader. Each iteration kills the current leader,
// counts the tick rounds a survivor needs to take office, then reopens the
// fallen node from its own directory and waits for the group to reconverge
// before the next iteration. It reports the average election latency as
// rounds/failover alongside the wall time of the whole kill and recover cycle.
func BenchmarkFailoverElection(b *testing.B) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	dirs := map[cluster.NodeID]string{}
	nodes := map[cluster.NodeID]*Node{}
	var opens uint64
	openNode := func(id cluster.NodeID) {
		opens++
		n, err := OpenNode(dirs[id], id, cfg, 3, testRNG(uint64(id)*1000+opens), NodeOptions{})
		if err != nil {
			b.Fatalf("open %d: %v", id, err)
		}
		nodes[id] = n
	}
	for _, id := range ids {
		dirs[id] = b.TempDir() // kept per id so a reopen recovers from the same store
		openNode(id)
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()

	benchDriveUntilLeader(b, nodes, ids, 2000)

	totalRounds := 0
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		lead := leaderOf(nodes, ids)
		if lead == cluster.None {
			lead = benchDriveUntilLeader(b, nodes, ids, 2000)
		}
		// Kill the current leader: close its storage and drop it from the fabric,
		// so its heartbeats stop and a survivor must call an election.
		if cerr := nodes[lead].Close(); cerr != nil {
			b.Fatalf("close leader %d: %v", lead, cerr)
		}
		delete(nodes, lead)
		_, rounds := benchDriveUntilLeaderCounting(b, nodes, ids, 2000)
		totalRounds += rounds
		// Recovery is real: OpenNode replays the committed log from the same
		// directory, and the group must reconverge before the next failover.
		openNode(lead)
		if !benchDriveUntilConverged(b, nodes, ids, 2000) {
			b.Fatalf("group did not reconverge after failover")
		}
	}
	b.ReportMetric(float64(totalRounds)/float64(b.N), "rounds/failover")
}
