package naylamp

import (
	"math"
	"os"
	"sort"
	"strconv"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

// clusterIDRange bounds the record ids the schedule writes: a small, closed
// range so both shards fill and every live set stays inside the well separated
// regime the oracle relies on.
const clusterIDRange = 12

// vecFor is the deterministic, injective vector for a record id: the same shape
// the scatter-gather oracle test uses. Distinct ids land at strictly increasing
// cosine distance from {1,0,0} with wide pairwise separation, so the brute-force
// order is unambiguous by construction (self-checked at quiesce) rather than by
// relaxing the value tolerance. Re-putting an id writes the same vector, so the
// oracle's "last value" for an id is always this vector and the oracle tracks a
// live set.
func vecFor(id uint64) []float32 {
	return []float32{1, float32(id) * 0.15, 0.2}
}

// clusterSeedOutcome is one seed's converged conclusion plus the schedule
// coverage it exercised. The sweep aggregates the counters for its gate and the
// replay test compares the conclusion.
type clusterSeedOutcome struct {
	shardHash  [2][32]byte
	oracleSize int
	elections  int
	partitions int
	crashes    int
	acked      int
	stats      cluster.SimStats
}

// runClusterSeed builds a two-shard, six-replica cluster over one seeded SimNet,
// runs a bounded chaos schedule of client ops and faults against a RouterHost,
// then quiesces and asserts the equality-of-replicas and observable-durability
// invariants. Everything it depends on is a pure function of the seed, so the
// same seed replays the same history (see TestClusterDST_DeterministicReplay).
//
// Durability here is Option A, observable: the harness never reads a node's
// committed log. The invariant is that every operation the RouterHost acked is
// present in the converged state with its last value, the per-shard record count
// matches the oracle, and a shard's replicas are identical by hash. Literal
// exactly-once at the log level is DEFER-013.
func runClusterSeed(t *testing.T, seed uint64) clusterSeedOutcome {
	t.Helper()

	// G2: one deterministic model per seed. The fabric's fault profile is
	// derived from the seed within modest ranges. Latency jitters between 1 and
	// 6 ticks so deliveries reorder; drop and dup stay low, 2% to 5%, on
	// purpose: a consensus cluster only makes progress when most messages land,
	// and the point of this harness is to converge under chaos, not to model a
	// dead network. The raft safety sweep runs at 12% for a leaderless stress
	// test; this cluster carries client work end to end, so it sits lower.
	minLat := cluster.Tick(1 + (seed/16)%2)    // 1 or 2 ticks of floor latency
	maxLat := minLat + cluster.Tick(2+seed%3)  // minLat+2 .. minLat+4, at most 6
	dropProb := 0.02 + 0.01*float64(seed%4)    // 0.02 .. 0.05
	dupProb := 0.02 + 0.01*float64((seed/4)%4) // 0.02 .. 0.05
	net := cluster.NewSimNet(seed, cluster.SimConfig{
		MinLatency: minLat, MaxLatency: maxLat, DropProb: dropProb, DupProb: dupProb,
	})

	// Two shards of three replicas: ids 1,2,3 on shard 0 and 4,5,6 on shard 1.
	// Each node knows only its own group's membership; the shared fabric routes
	// every group's consensus traffic by node id.
	cfg0 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	cfg1 := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 4}, {ID: 5}, {ID: 6}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg0, cfg1}}
	shardIDs := [][]cluster.NodeID{{1, 2, 3}, {4, 5, 6}}
	allIDs := []cluster.NodeID{1, 2, 3, 4, 5, 6}
	groupCfg := map[cluster.NodeID]cluster.Config{1: cfg0, 2: cfg0, 3: cfg0, 4: cfg1, 5: cfg1, 6: cfg1}

	dirs := map[cluster.NodeID]string{}
	for _, id := range allIDs {
		dirs[id] = t.TempDir() // saved per id so a restart recovers from the same store
	}
	restarts := map[cluster.NodeID]uint64{}
	hosts := map[cluster.NodeID]*Host{}
	var rh *RouterHost

	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range allIDs {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	// Node election timing draws from a generator seeded apart from both the
	// fabric (seeded with the raw seed) and the chaos schedule below, so the
	// three sources of randomness never alias. A restart re-seeds with the
	// restart count folded in, still a pure function of the seed.
	nodeSeed := func(id cluster.NodeID, gen uint64) uint64 {
		return seed*0x9E3779B97F4A7C15 + uint64(id)*0x100000001B3 + gen
	}
	open := func(id cluster.NodeID) {
		node, err := OpenNode(dirs[id], id, groupCfg[id], 3, testRNG(nodeSeed(id, restarts[id])), NodeOptions{})
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(id, h)
			if terr != nil {
				t.Fatalf("seed %d: endpoint %d: %v", seed, id, terr)
			}
			return tr
		})
		if err != nil {
			t.Fatalf("seed %d: host %d: %v", seed, id, err)
		}
		hosts[id] = host
	}
	for _, id := range allIDs {
		open(id)
	}

	// The router speaks as its own identity (routerID, distinct from every
	// replica), wired as one more endpoint by the pattern of the failover test:
	// its handler feeds each inbound frame to the router and re-emits whatever it
	// produces by the To in the envelope (RouterHost.deliver does exactly this).
	// Under SimNet the fabric routes by endpoint id, so AddPeer does not apply
	// and a restarted node is reachable again the instant it re-registers.
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("seed %d: new router: %v", seed, err)
	}
	rh, err = NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("seed %d: router endpoint: %v", seed, terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("seed %d: router host: %v", seed, err)
	}

	// Schedule counters, read back for the coverage gate and the replay.
	var elections, partitions, crashes, acked int
	lastLeader := [2]cluster.NodeID{cluster.None, cluster.None}

	trackElections := func() {
		for sh := range shardIDs {
			cur := hostLeaderOf(hosts, shardIDs[sh])
			if cur != lastLeader[sh] {
				if cur != cluster.None {
					elections++
				}
				lastLeader[sh] = cur
			}
		}
	}
	// advance is one deterministic round: tick every present host in id order,
	// then tick the fabric, then note any leadership change. No wall clock.
	advance := func() {
		tickHosts(t, hosts, allIDs)
		net.Tick()
		trackElections()
	}
	// drivePoll spends a bounded tick budget waiting for one op to resolve. The
	// client has no protocol timeout yet (DEFER-011): an op that does not resolve
	// inside its budget simply never acks.
	drivePoll := func(opID uint64, budget int) (RouteResult, bool) {
		for i := 0; i < budget; i++ {
			advance()
			if res, ok := rh.Result(opID); ok {
				return res, true
			}
		}
		return RouteResult{}, false
	}

	// Fault state: at most one partition episode and one crashed node live at a
	// time, mirroring the single-slot chaos of the raft safety sweep so a shard
	// keeps its quorum often enough to make progress.
	partitioned := false
	var blockedEdges [][2]cluster.NodeID
	partNode := cluster.None
	downNode := cluster.None

	shardOfNode := func(v cluster.NodeID) int {
		for sh := range shardIDs {
			for _, id := range shardIDs[sh] {
				if id == v {
					return sh
				}
			}
		}
		return 0
	}
	// shardImpaired reports whether the current fault episode robs a shard of a
	// replica, so it may lack quorum. Writes go only to an unimpaired shard: see
	// runOp for why an at-most-once client protocol forces that.
	shardImpaired := func(s int) bool {
		if downNode != cluster.None && shardOfNode(downNode) == s {
			return true
		}
		return partitioned && shardOfNode(partNode) == s
	}
	crashNode := func(v cluster.NodeID) {
		_ = hosts[v].Close() // Close detaches the endpoint: a crashed node
		delete(hosts, v)     // vanishes from the fabric and stops ticking
		downNode = v
		crashes++
	}
	restartNode := func(v cluster.NodeID) {
		restarts[v]++
		open(v) // recovery is real: OpenNode replays the committed log from dirs[v]
		downNode = cluster.None
	}

	// The chaos generator is separate from the node and fabric streams.
	chaos := testRNG(seed ^ 0xC0FFEE5CA1AB1E)

	// G3: first bring both shards to an initial leader, then run the bounded
	// chaos loop. Each round advances once, then with the higher probability
	// runs one client op, then with the lower probability injects one fault.
	const initBudget = 600
	elected := false
	for i := 0; i < initBudget; i++ {
		advance()
		if hostLeaderOf(hosts, shardIDs[0]) != cluster.None && hostLeaderOf(hosts, shardIDs[1]) != cluster.None {
			elected = true
			break
		}
	}
	if !elected {
		t.Fatalf("seed %d: shards did not both elect an initial leader within %d rounds", seed, initBudget)
	}

	oracle := map[uint64][]float32{}
	const opBudget = 30
	const searchBudget = 18
	const opReissues = 10

	// reissueUntilOK drives one idempotent write to a definitive OK ack, re-issuing
	// a FRESH operation past transient loss, which is the RouterHost caller
	// contract (the client has no protocol retransmit, DEFER-011). It is called
	// only when the target shard is unimpaired, so it keeps full quorum for the
	// whole call (faults toggle in the chaos loop, never inside a poll) and the
	// write is guaranteed to commit; re-issuing only overcomes a lost request or
	// ack. It returns true once the write has provably committed.
	reissueUntilOK := func(issue func() (uint64, error)) bool {
		for attempt := 0; attempt < opReissues; attempt++ {
			opID, err := issue()
			if err != nil {
				t.Fatalf("seed %d: router op: %v", seed, err)
			}
			if res, done := drivePoll(opID, opBudget); done && res.Status == StatusOK && !res.Exhausted && res.Index != 0 {
				return true
			}
		}
		return false
	}

	// runOp issues one client operation chosen by the schedule.
	//
	// Writes go only to an unimpaired shard and are driven to a real OK ack. An
	// at-most-once client protocol with no retransmit cannot keep an exact,
	// independent oracle otherwise: a write to a shard that can commit but whose
	// ack is lost would leave a record the oracle never saw, and a write to a
	// shard without quorum can leave an uncommitted entry that commits late at
	// heal. Restricting writes to a full-quorum shard and confirming the ack
	// closes both holes, so an acked write is committed exactly once as far as the
	// converged state can tell (literal log-level exactly-once stays DEFER-013),
	// and the oracle is a faithful model of the committed data. Faults still run
	// against the other shard and between writes, so the durability of every
	// committed write is proved across the full fault history.
	runOp := func() {
		switch kind := chaos.IntN(10); {
		case kind < 6: // put an id with its deterministic vector
			id := uint64(1 + chaos.IntN(clusterIDRange)) //nolint:gosec // 1+IntN(range) is a small positive int
			if shardImpaired(sm.ShardFor(id)) {
				return
			}
			vec := vecFor(id)
			if reissueUntilOK(func() (uint64, error) { return rh.Upsert(id, vec) }) {
				oracle[id] = vec
				acked++
			}
		case kind < 8: // delete an id (a no-op on the store if absent, still an ack)
			id := uint64(1 + chaos.IntN(clusterIDRange)) //nolint:gosec // 1+IntN(range) is a small positive int
			if shardImpaired(sm.ShardFor(id)) {
				return
			}
			if reissueUntilOK(func() (uint64, error) { return rh.Delete(id) }) {
				delete(oracle, id)
				acked++
			}
		default: // a search interleaved, to drive the read path under chaos
			id := uint64(1 + chaos.IntN(clusterIDRange)) //nolint:gosec // 1+IntN(range) is a small positive int
			opID, oerr := rh.Search(vecFor(id), 1+chaos.IntN(3))
			if oerr != nil {
				t.Fatalf("seed %d: router search: %v", seed, oerr)
			}
			// A mid-chaos search is best effort and not judged here; the healed
			// scatter-gather at quiesce is the oracle. This only exercises the path.
			_, _ = drivePoll(opID, searchBudget)
		}
	}

	injectFault := func() {
		switch chaos.IntN(3) {
		case 0: // partition episode: cut one node against its whole shard, then heal
			if partitioned {
				for _, e := range blockedEdges {
					net.Heal(e[0], e[1])
				}
				blockedEdges = blockedEdges[:0]
				partitioned = false
				return
			}
			v := allIDs[chaos.IntN(len(allIDs))]
			sh := shardOfNode(v)
			dir := chaos.IntN(3) // 0 both directions, 1 outbound only, 2 inbound only
			for _, p := range shardIDs[sh] {
				if p == v {
					continue
				}
				// Cutting v against every shard peer always crosses a leader
				// edge, so heartbeat traffic is dropped and the partition is
				// effective, not a silent no-op on a leaderless pair.
				if dir == 0 || dir == 1 {
					net.Partition(v, p)
					blockedEdges = append(blockedEdges, [2]cluster.NodeID{v, p})
				}
				if dir == 0 || dir == 2 {
					net.Partition(p, v)
					blockedEdges = append(blockedEdges, [2]cluster.NodeID{p, v})
				}
			}
			if len(blockedEdges) > 0 {
				partitioned = true
				partNode = v
				partitions++
			}
		case 1: // crash or restart a node chosen by the schedule
			if downNode == cluster.None {
				crashNode(allIDs[chaos.IntN(len(allIDs))])
			} else {
				restartNode(downNode)
			}
		default: // kill a shard's current leader, or restart the crashed node
			if downNode == cluster.None {
				if v := hostLeaderOf(hosts, shardIDs[chaos.IntN(2)]); v != cluster.None {
					crashNode(v)
				}
			} else {
				restartNode(downNode)
			}
		}
	}

	const chaosRounds = 16
	for step := 0; step < chaosRounds; step++ {
		advance()
		if chaos.Float64() < 0.6 {
			runOp()
		}
		if chaos.Float64() < 0.14 {
			injectFault()
		}
	}

	// G4: quiesce. Restart any crashed node and heal every partition, then drive
	// each shard to convergence within a bounded budget. A shard that will not
	// reconverge is the liveness failure and stops the seed.
	if downNode != cluster.None {
		restartNode(downNode)
	}
	net.HealAll()

	const quiesceBudget = 1500
	converged := false
	for i := 0; i < quiesceBudget; i++ {
		advance()
		if hostsConverged(hosts, shardIDs[0]) && hostsConverged(hosts, shardIDs[1]) {
			converged = true
			break
		}
	}
	if !converged {
		t.Fatalf("seed %d: shards did not reconverge after heal within %d rounds", seed, quiesceBudget)
	}

	// (1) Equality of replicas: per shard, every replica present shares its last
	// index and its committed-state hash.
	for sh := range shardIDs {
		if !hostsConverged(hosts, shardIDs[sh]) {
			t.Fatalf("seed %d: shard %d replicas diverge on index or state hash", seed, sh)
		}
	}

	// (2) Observable durability. Every acked id is present with its last value:
	// an exact-vector search against a shard replica returns that id as the
	// nearest neighbor, and each shard holds exactly the ids the oracle maps to
	// it (count via a local enumerate read, k above any shard's live size).
	enumQuery := []float32{1, 0, 0}
	for sh := range shardIDs {
		want := 0
		for id := range oracle {
			if sm.ShardFor(id) == sh {
				want++
			}
		}
		rep := shardIDs[sh][0]
		got, gerr := hosts[rep].Search(enumQuery, clusterIDRange)
		if gerr != nil {
			t.Fatalf("seed %d: shard %d enumerate: %v", seed, sh, gerr)
		}
		if len(got) != want {
			t.Fatalf("seed %d: shard %d holds %d records, oracle maps %d there", seed, sh, len(got), want)
		}
	}
	for id := range oracle {
		rep := shardIDs[sm.ShardFor(id)][0]
		got, gerr := hosts[rep].Search(vecFor(id), 1)
		if gerr != nil {
			t.Fatalf("seed %d: durability search id %d: %v", seed, id, gerr)
		}
		if len(got) != 1 || got[0].ID != id {
			t.Fatalf("seed %d: durability id %d nearest = %+v, want that id", seed, id, got)
		}
	}

	// (3) Scatter-gather. A final search against the RouterHost matches the
	// brute-force top-k over the whole oracle: exact ids in order, distances
	// within 1e-6. The pairwise separation is self-checked first, three orders of
	// magnitude above the value tolerance (the 5b soundness check), so the order
	// is unambiguous by construction; a live set that fails to separate is a
	// vector-generation bug, never a reason to relax the tolerance.
	liveIDs := make([]uint64, 0, len(oracle))
	for id := range oracle {
		liveIDs = append(liveIDs, id)
	}
	sort.Slice(liveIDs, func(a, b int) bool { return liveIDs[a] < liveIDs[b] })
	if len(liveIDs) > 0 {
		query := []float32{1, 0, 0}
		want := make(map[uint64]float32, len(liveIDs))
		for _, id := range liveIDs {
			want[id] = vector.CosineDistance(query, vecFor(id))
		}
		for i := 0; i < len(liveIDs); i++ {
			for j := i + 1; j < len(liveIDs); j++ {
				if math.Abs(float64(want[liveIDs[i]])-float64(want[liveIDs[j]])) <= 1e-3 {
					t.Fatalf("seed %d: oracle separation too small: ids %d and %d at %v and %v",
						seed, liveIDs[i], liveIDs[j], want[liveIDs[i]], want[liveIDs[j]])
				}
			}
		}
		order := append([]uint64(nil), liveIDs...)
		sort.Slice(order, func(a, b int) bool {
			if want[order[a]] != want[order[b]] {
				return want[order[a]] < want[order[b]]
			}
			return order[a] < order[b]
		})
		// The client has no protocol retransmit yet (DEFER-011): on a lossy
		// fabric a dropped request or response leaves a search leg with no reply
		// and the op never terminates. The RouterHost contract for exactly this
		// is that the caller re-issues a FRESH operation on its own deadline, so
		// the harness retries a fresh search until one round-trip survives. This
		// overcomes transient loss only; a completed search with the wrong
		// contents still fails the assertions below.
		res, done := RouteResult{}, false
		for attempt := 0; attempt < 12 && !done; attempt++ {
			opID, serr := rh.Search(query, len(order))
			if serr != nil {
				t.Fatalf("seed %d: scatter search: %v", seed, serr)
			}
			if r, ok := drivePoll(opID, 300); ok && r.Status == StatusOK && !r.Exhausted {
				res, done = r, true
			}
		}
		if !done || res.Index != 0 {
			t.Fatalf("seed %d: scatter-gather search did not complete OK within the retry budget: %+v done=%v", seed, res, done)
		}
		if len(res.Neighbors) != len(order) {
			t.Fatalf("seed %d: scatter returned %d neighbors, want %d", seed, len(res.Neighbors), len(order))
		}
		for i, nb := range res.Neighbors {
			if nb.ID != order[i] {
				t.Fatalf("seed %d: scatter neighbor %d id = %d, oracle %d", seed, i, nb.ID, order[i])
			}
			if math.Abs(float64(nb.Distance)-float64(want[nb.ID])) > 1e-6 {
				t.Fatalf("seed %d: scatter neighbor %d distance = %v, oracle %v", seed, i, nb.Distance, want[nb.ID])
			}
		}
	}

	if herr := rh.Err(); herr != nil {
		t.Fatalf("seed %d: router host poisoned: %v", seed, herr)
	}
	for _, id := range allIDs {
		if herr := hosts[id].Err(); herr != nil {
			t.Fatalf("seed %d: host %d poisoned: %v", seed, id, herr)
		}
	}

	out := clusterSeedOutcome{
		oracleSize: len(oracle),
		elections:  elections,
		partitions: partitions,
		crashes:    crashes,
		acked:      acked,
		stats:      net.Stats(),
	}
	for sh := range shardIDs {
		out.shardHash[sh] = hosts[shardIDs[sh][0]].StateHash()
	}
	return out
}

// TestClusterDST_Seeded sweeps the distributed harness across many seeds and
// gates on the coverage the schedule actually exercised.
func TestClusterDST_Seeded(t *testing.T) {
	// Seed budget and parsing follow the raft safety sweep exactly
	// (TestRaft_SafetyInvariants_Seeded and its NAYLAMP_RAFT_SEEDS gate): 500
	// seeds by default, 40 under -short, and NAYLAMP_CLUSTER_SEEDS overrides the
	// count. NAYLAMP_CLUSTER_SEED (singular) pins one seed for a replay.
	seeds := 500
	if testing.Short() {
		seeds = 40
	}
	if env := os.Getenv("NAYLAMP_CLUSTER_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_CLUSTER_SEEDS=%q invalid", env)
		}
		seeds = v
	}
	start, end := 1, seeds
	if env := os.Getenv("NAYLAMP_CLUSTER_SEED"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_CLUSTER_SEED=%q invalid", env)
		}
		start, end = v, v
	}

	var elections, partitions, crashes, acked int
	var stats cluster.SimStats
	for s := start; s <= end; s++ {
		oc := runClusterSeed(t, uint64(s)) //nolint:gosec // s ranges over positive seed numbers
		elections += oc.elections
		partitions += oc.partitions
		crashes += oc.crashes
		acked += oc.acked
		stats.Sent += oc.stats.Sent
		stats.DroppedByFault += oc.stats.DroppedByFault
		stats.Duplicated += oc.stats.Duplicated
		stats.DroppedByPartition += oc.stats.DroppedByPartition
		stats.DroppedNoReceiver += oc.stats.DroppedNoReceiver
	}
	nseeds := end - start + 1

	// G5: coverage gate, the shape of the raft sweep's gate. A run that never
	// elected, never crashed, acked nothing, or whose fault schedule never
	// dropped, duplicated or blocked a message proves nothing: the
	// illusory-coverage trap. A sweep that did not exercise chaos does not count.
	if elections == 0 {
		t.Fatalf("coverage: no elections across %d seeds", nseeds)
	}
	if crashes == 0 {
		t.Fatalf("coverage: no crashes across %d seeds", nseeds)
	}
	if partitions == 0 {
		t.Fatalf("coverage: no partitions across %d seeds", nseeds)
	}
	if acked == 0 {
		t.Fatalf("coverage: nothing acked across %d seeds", nseeds)
	}
	if stats.DroppedByFault == 0 || stats.Duplicated == 0 || stats.DroppedByPartition == 0 {
		t.Fatalf("coverage: fault schedule idle: %+v", stats)
	}
	t.Logf("cluster DST: seeds=%d elections=%d partitions=%d crashes=%d acked=%d sent=%d dropped=%d dup=%d partitionDrops=%d noReceiver=%d",
		nseeds, elections, partitions, crashes, acked,
		stats.Sent, stats.DroppedByFault, stats.Duplicated, stats.DroppedByPartition, stats.DroppedNoReceiver)
}

// TestClusterDST_DeterministicReplay drives one fixed seed twice down the
// identical path and requires the identical conclusion, requirement 3.5.8.
// Everything the run depends on, the fabric generator, the per-node election
// generators, and the chaos schedule, is a pure function of the seed, so the
// converged state hash per shard and the oracle size must match across replays.
func TestClusterDST_DeterministicReplay(t *testing.T) {
	const seed uint64 = 0x0DDC0FFEE
	a := runClusterSeed(t, seed)
	b := runClusterSeed(t, seed)
	for sh := 0; sh < 2; sh++ {
		if a.shardHash[sh] != b.shardHash[sh] {
			t.Fatalf("shard %d state hash diverged across replays: %x vs %x", sh, a.shardHash[sh], b.shardHash[sh])
		}
	}
	if a.oracleSize != b.oracleSize {
		t.Fatalf("oracle size diverged across replays: %d vs %d", a.oracleSize, b.oracleSize)
	}
}
