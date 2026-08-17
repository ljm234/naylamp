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
	// reelections counts only the leader changes AFTER each shard's first, and
	// exists because elections alone cannot fail: the init loop at G3 t.Fatalf's
	// unless both shards seat a leader, so elections >= 2 per seed holds by
	// construction before any gate reads it. A re-election is the thing the
	// anti-Eaton clause actually means by "elecciones forzadas", and it is zero
	// on any seed whose fault schedule never deposed anyone.
	reelections  int
	partitions   int
	crashes      int
	acked        int
	readsChecked int
	stats        cluster.SimStats
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
// matches the oracle, and a shard's replicas are identical by hash. Read
// linearizability is checked the same observable way, during the schedule under
// active faults: right after a write or delete acks, a scatter-gather read of
// that id must reflect the ack, read-your-writes and read-your-deletes, the
// observable consequence of the ReadIndex barrier. Literal exactly-once at the
// log level is DEFER-013 and literal read-index linearizability is DEFER-014.
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
	var elections, reelections, partitions, crashes, acked, readsChecked int
	lastLeader := [2]cluster.NodeID{cluster.None, cluster.None}
	// seated[sh] records that shard sh has already had one leader, so the next
	// change is a re-election rather than the initial seating the init loop
	// forces. See clusterSeedOutcome.reelections for why the distinction is the
	// whole difference between a gate that can fail and one that cannot.
	var seated [2]bool

	trackElections := func() {
		for sh := range shardIDs {
			cur := hostLeaderOf(hosts, shardIDs[sh])
			if cur != lastLeader[sh] {
				if cur != cluster.None {
					elections++
					if seated[sh] {
						reelections++
					}
					seated[sh] = true
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
	// readGen decides when to fire a read-your-writes probe. It is a fourth
	// stream, seeded apart from the node, fabric and chaos generators so it never
	// aliases them: turning the checker on draws from readGen alone and leaves the
	// chaos schedule's fault decisions for a seed exactly as they were, so a seed
	// exercises the same fault history with the probe on or off.
	readGen := testRNG(seed ^ 0x5EAD5EAD5EAD5EAD)

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
	// readCheckBudget bounds the ticks a read-your-writes probe waits for its
	// scatter-gather to complete; readCheckProb is how often the chaos schedule
	// fires a probe right after a write or delete ack. A probe that does not
	// complete inside the budget asserts nothing (DEFER-011), so the budget only
	// needs to be generous enough that a healthy cluster's read lands.
	const readCheckBudget = 60
	const readCheckProb = 0.5

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

	// checkReadYourWrite issues one linearizable read of id's own vector right
	// after that id's write or delete was drained to a definitive ack, and asserts
	// the observable consequence of the ReadIndex barrier. It is called inline from
	// runOp, so the read is emitted before runOp returns and before any other
	// schedule op can touch id: the ack strictly precedes the read, and no fault
	// toggles in between because injectFault runs only after runOp returns.
	// present=true is a read-your-writes probe: vecFor is injective and self
	// separated, so id sits at distance zero to its own vector and must come back
	// as the global nearest. present=false is a read-your-deletes probe: id must
	// not appear at any rank. The read is a scatter-gather via the RouterHost,
	// served on each shard's leader behind the applied>=readIndex barrier (see
	// Node.ReadServable in node.go), never on a stale follower, so a completed read
	// reflects every write committed before its read index and thus the ack that
	// preceded it. A read that does not complete asserts nothing: with no client
	// retransmit (DEFER-011) a dropped leg leaves the op unresolved, which is not a
	// violation. readsChecked counts only reads that completed and were asserted,
	// so the coverage gate can require the property was actually exercised.
	checkReadYourWrite := func(id uint64, present bool) {
		// Probe only when id's shard has full quorum at this instant: a scatter
		// gather needs every shard's leg to answer, so an impaired shard just means
		// the read will not complete, which is a non-assertion, not a violation.
		if shardImpaired(sm.ShardFor(id)) {
			return
		}
		opID, oerr := rh.Search(vecFor(id), 1)
		if oerr != nil {
			t.Fatalf("seed %d: read-your-writes search id %d: %v", seed, id, oerr)
		}
		res, done := drivePoll(opID, readCheckBudget)
		if !done || res.Status != StatusOK || res.Exhausted {
			return // did not complete: assert nothing, DEFER-011
		}
		if present {
			if len(res.Neighbors) < 1 || res.Neighbors[0].ID != id {
				t.Fatalf("seed %d: read-your-writes id %d: nearest = %+v, want that id at rank 0", seed, id, res.Neighbors)
			}
		} else {
			for _, nb := range res.Neighbors {
				if nb.ID == id {
					t.Fatalf("seed %d: read-your-deletes id %d: still returned in %+v", seed, id, res.Neighbors)
				}
			}
		}
		readsChecked++
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
				if readGen.Float64() < readCheckProb {
					checkReadYourWrite(id, true)
				}
			}
		case kind < 8: // delete an id (a no-op on the store if absent, still an ack)
			id := uint64(1 + chaos.IntN(clusterIDRange)) //nolint:gosec // 1+IntN(range) is a small positive int
			if shardImpaired(sm.ShardFor(id)) {
				return
			}
			if reissueUntilOK(func() (uint64, error) { return rh.Delete(id) }) {
				delete(oracle, id)
				acked++
				if readGen.Float64() < readCheckProb {
					checkReadYourWrite(id, false)
				}
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
		oracleSize:   len(oracle),
		elections:    elections,
		reelections:  reelections,
		partitions:   partitions,
		crashes:      crashes,
		acked:        acked,
		readsChecked: readsChecked,
		stats:        net.Stats(),
	}
	for sh := range shardIDs {
		out.shardHash[sh] = hosts[shardIDs[sh][0]].StateHash()
	}
	return out
}

// TestClusterDST_Seeded sweeps the distributed harness across many seeds and
// gates on the coverage the schedule actually exercised.
func TestClusterDST_Seeded(t *testing.T) {
	// Seed budget and parsing follow the shape of the raft safety sweep
	// (TestRaft_SafetyInvariants_Seeded and its NAYLAMP_RAFT_SEEDS gate), but not
	// its count: that sweep defaults to 300 seeds and this one to 500, both 40
	// under -short, with NAYLAMP_CLUSTER_SEEDS overriding the count here.
	// A replay of one pinned seed lives in TestClusterDST_SeededReplay, and this
	// test refuses to become one.
	//
	// It used to accept NAYLAMP_CLUSTER_SEED itself and skip the coverage gate for
	// that run, on the reasoning that one seed cannot carry a per-seed floor, which
	// is true, and that printing the exemption kept the skip honest, which is FALSE
	// and is why the shape changed. Go discards a passing test's output entirely
	// without -v: t.Logf, os.Stdout and os.Stderr alike. phase_pre in gate/omnibus.sh
	// runs exactly `go test ./naylamp/ -run '^TestClusterDST_Seeded$' -count=1` with
	// no -v, so a NAYLAMP_CLUSTER_SEED left exported from an earlier replay would
	// have collapsed the sealed 500-seed gate to one ungated seed and still printed
	// nothing but `ok`. An exemption nobody can see is the illusory coverage this
	// gate exists to refuse. That phase sanitizes the environment now, and it names
	// this comment as the reason; the citation is by function because it used to be
	// by line number and the line moved the day the sanitizing went in.
	//
	// So the pin is refused here rather than honored, and the replay carries its
	// meaning in its NAME instead of in a log line that the default invocation
	// throws away. The anchored -run pattern above does not match the replay, so
	// the sealed gate now fails loudly on a stray pin instead of passing quietly.
	if env := os.Getenv("NAYLAMP_CLUSTER_SEED"); env != "" {
		t.Fatalf("NAYLAMP_CLUSTER_SEED=%q pins a single seed, which cannot carry the coverage gate: this test IS the gated sweep. Unset it here and run TestClusterDST_SeededReplay for a replay", env)
	}
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

	var elections, reelections, partitions, crashes, acked, readsChecked int
	var stats cluster.SimStats
	for s := start; s <= end; s++ {
		oc := runClusterSeed(t, uint64(s)) //nolint:gosec // s ranges over positive seed numbers
		elections += oc.elections
		reelections += oc.reelections
		partitions += oc.partitions
		crashes += oc.crashes
		acked += oc.acked
		readsChecked += oc.readsChecked
		stats.Sent += oc.stats.Sent
		stats.DroppedByFault += oc.stats.DroppedByFault
		stats.Duplicated += oc.stats.Duplicated
		stats.DroppedByPartition += oc.stats.DroppedByPartition
		stats.DroppedNoReceiver += oc.stats.DroppedNoReceiver
	}
	nseeds := end - start + 1

	// The summary prints BEFORE the gate so a run that trips a floor still shows
	// every counter beside the one that tripped, which is what a diagnosis needs.
	t.Logf("cluster DST: seeds=%d elections=%d reelections=%d partitions=%d crashes=%d acked=%d readsChecked=%d sent=%d dropped=%d dup=%d partitionDrops=%d noReceiver=%d",
		nseeds, elections, reelections, partitions, crashes, acked, readsChecked,
		stats.Sent, stats.DroppedByFault, stats.Duplicated, stats.DroppedByPartition, stats.DroppedNoReceiver)

	// G5: coverage gate, what the Eaton 2024 DST trap entry of the risk list and
	// the Objective of Subphase 3.5 call "minimos por corrida". Both are in
	// NAYLAMP_PHASE_3.md, which lives OUTSIDE this repository, in the workspace
	// directory beside it, so a clone does not carry it. Named and not numbered,
	// corrected on 17 August 2026; the reasoning is in the hard rule of
	// DEFER-035.
	//
	// It used to be six comparisons to zero over the whole
	// sweep, which is not a minimum per run: one seed with one ack and one dropped
	// frame satisfied all six no matter how many seeds ran beside it. Two things
	// changed here, and both are load-bearing.
	//
	// First, every floor is now a RATE PER SEED, not a count. A fixed count rots
	// in both directions: raise the seed budget and yesterday's number stops being
	// a floor, lower it and the number stops being reachable. A rate scales with
	// the run by construction and needs no maintenance when the budget moves.
	//
	// The rates are NOT uniform against what the schedule produces, and quoting a
	// single fraction for them would misreport the headroom in both directions.
	// Measured over 60 seeds, floor against observed: re-elections 15/47 (3.1x
	// margin), partitions 15/33 (2.2x), crashes 30/62 (2.1x), acked 120/337 (2.8x),
	// reads 30/114 (3.8x), fault drops 600/3674 (6.1x), duplicates 600/3261 (5.4x),
	// partition drops 120/852 (7.1x). The floors run between a seventh and a half
	// of observed: the fabric counters sit furthest below because a schedule change
	// moves them most, and the TIGHTEST is crashes, followed by partitions.
	//
	// The budget that decides a pull request is 40 seeds, not 60, since CI runs
	// -short (.github/workflows/ci.yml) and testing.Short() picks 40 above. There
	// the binding margin is tighter still: crashes 20/39 is 1.95x, partitions 10/26
	// is 2.60x, and everything else is looser. So crashes at 40 seeds is the one
	// number to look at first if a schedule edit ever trips this gate.
	//
	// The sweep is a pure function of its seeds, so all of these are exact rather
	// than sampled: the margin is headroom against a future edit to the schedule,
	// never against run-to-run noise, and no rerun of an unchanged tree can drift
	// across a floor.
	//
	// Second, the elections floor is gone and reelections stands in its place. The
	// old one could not fail: the init loop at G3 t.Fatalf's unless both shards
	// seat a leader, so elections >= 2 per seed was true before the gate read it.
	// A decorative check is worse than none, because its green reads as an
	// attestation. Re-elections carry what the clause meant.
	//
	// The three fabric counters are uint64 on SimStats and the sweep's own are
	// int; they meet here as int, which cannot overflow, since every one of them
	// is bounded by the frames a bounded seed budget can emit.
	floors := []struct {
		name     string
		got      int
		num, den int // floor for a run of n seeds is num*n/den
	}{
		{"re-elections", reelections, 1, 4},
		{"partitions", partitions, 1, 4},
		{"crashes", crashes, 1, 2},
		{"acked writes", acked, 2, 1},
		{"linearizable reads verified", readsChecked, 1, 2},
		{"frames dropped by fault", int(stats.DroppedByFault), 10, 1},        //nolint:gosec // bounded by the frames a bounded seed budget emits
		{"frames duplicated", int(stats.Duplicated), 10, 1},                  //nolint:gosec // bounded the same way
		{"frames dropped by partition", int(stats.DroppedByPartition), 2, 1}, //nolint:gosec // bounded the same way
	}

	for _, f := range floors {
		want := f.num * nseeds / f.den
		if want < 1 {
			t.Fatalf("coverage: a sweep of %d seeds is too small to gate: the floor for %s rounds to %d, which no run can fail. Raise NAYLAMP_CLUSTER_SEEDS, or pin a seed with NAYLAMP_CLUSTER_SEED for a replay",
				nseeds, f.name, want)
		}
		if f.got < want {
			t.Fatalf("coverage: %s = %d over %d seeds, below the per-run floor of %d (%d per %d seeds)",
				f.name, f.got, nseeds, want, f.num, f.den)
		}
	}
}

// TestClusterDST_SeededReplay re-runs ONE seed of the sweep, the seed named by
// NAYLAMP_CLUSTER_SEED, and skips when that variable is unset.
//
// It exists so a pin can never be mistaken for the gated sweep. It runs the
// identical scenario through the identical runClusterSeed, so every per-seed
// invariant a failing seed violated is violated here too and reproduces exactly,
// which is what a replay is for. What it does NOT do is gate on coverage, and it
// cannot: a per-seed floor over one seed distinguishes nothing, since a healthy
// seed is entitled to have partitioned zero times. That is not a hole because
// this test's name is not the sweep's, and TestClusterDST_Seeded refuses to run
// at all while the pin is set, so no invocation can quietly serve a one-seed
// green where a five-hundred-seed gated green was expected.
func TestClusterDST_SeededReplay(t *testing.T) {
	env := os.Getenv("NAYLAMP_CLUSTER_SEED")
	if env == "" {
		t.Skip("NAYLAMP_CLUSTER_SEED is unset, so there is no seed to replay")
	}
	v, err := strconv.Atoi(env)
	if err != nil || v < 1 {
		t.Fatalf("NAYLAMP_CLUSTER_SEED=%q invalid", env)
	}
	oc := runClusterSeed(t, uint64(v)) //nolint:gosec // v is a positive seed number, checked above
	t.Logf("cluster DST replay: seed=%d elections=%d reelections=%d partitions=%d crashes=%d acked=%d readsChecked=%d sent=%d dropped=%d dup=%d partitionDrops=%d noReceiver=%d",
		v, oc.elections, oc.reelections, oc.partitions, oc.crashes, oc.acked, oc.readsChecked,
		oc.stats.Sent, oc.stats.DroppedByFault, oc.stats.Duplicated, oc.stats.DroppedByPartition, oc.stats.DroppedNoReceiver)
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

// TestClusterDST_SilentTargetRecoversByProtocol proves the DEFER-011 retransmit
// that 4.1a added actually recovers a lost frame under a real fault, on the same
// logical clock the cluster runs on, and WITHOUT the caller re-issuing the
// operation.
//
// It is deliberately separate from TestClusterDST_Seeded and its runClusterSeed.
// That sweep never ticks the RouterHost, so a Router there never times an attempt
// out, and wiring a tick into its advance would change the sealed sweep's message
// history, its coverage counters and its per-shard hashes. This test brings its
// own small deterministic harness whose advance DOES tick the RouterHost, so the
// retransmit path gets real coverage while the 500-seed sweep stays untouched.
//
// The fault is a silent target. One replica keeps receiving requests and keeps
// committing them with its peers, but every response it sends the router is
// dropped: it does its job and answers into a void. The router hears nothing, so
// only its own retransmit, fired by Tick on the fabric clock, keeps the operation
// alive until the channel heals and one ack finally lands. Because the caller
// issues exactly one Upsert and never retries, a terminal OK can only be the
// protocol recovering, never a fresh caller operation.
func TestClusterDST_SilentTargetRecoversByProtocol(t *testing.T) {
	// seed is a runtime var, not a const, so the per-node mix below wraps mod 2^64
	// exactly as runClusterSeed's does with its seed parameter; a const seed would
	// make that multiply a compile-time overflow.
	var seed uint64 = 0x5A1E7

	// A clean fabric except for the mute: latency jitters so deliveries reorder,
	// but nothing is dropped or duplicated at random. That makes the muted leader's
	// ack the only lost frame in the whole run, which isolates the property under
	// test: the op stays open exactly while the mute holds and resolves exactly
	// when a retransmit's ack crosses the healed channel.
	net := cluster.NewSimNet(seed, cluster.SimConfig{MinLatency: 1, MaxLatency: 4})

	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	sm := cluster.ShardMap{Groups: []cluster.Config{cfg}}
	shard := []cluster.NodeID{1, 2, 3}
	groupCfg := map[cluster.NodeID]cluster.Config{1: cfg, 2: cfg, 3: cfg}

	dirs := map[cluster.NodeID]string{}
	for _, id := range shard {
		dirs[id] = t.TempDir()
	}
	hosts := map[cluster.NodeID]*Host{}
	var rh *RouterHost

	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
		for _, id := range shard {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
		net.Close()
	}()

	// One election generator per node, seeded apart from the fabric so the two
	// streams never alias, the same discipline runClusterSeed uses.
	nodeSeed := func(id cluster.NodeID) uint64 {
		return seed*0x9E3779B97F4A7C15 + uint64(id)*0x100000001B3
	}
	for _, id := range shard {
		node, err := OpenNode(dirs[id], id, groupCfg[id], 3, testRNG(nodeSeed(id)), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := net.Endpoint(id, h)
			if terr != nil {
				t.Fatalf("endpoint %d: %v", id, terr)
			}
			return tr
		})
		if err != nil {
			t.Fatalf("host %d: %v", id, err)
		}
		hosts[id] = host
	}

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	rh, err = NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := net.Endpoint(routerID, h)
		if terr != nil {
			t.Fatalf("router endpoint: %v", terr)
		}
		return tr
	})
	if err != nil {
		t.Fatalf("router host: %v", err)
	}

	// advance is this test's round and, unlike the sealed sweep's advance, it also
	// ticks the RouterHost. net.Clock().Now() is the right clock to feed: the
	// ManualClock advances by one on every net.Tick, so it is monotone and moves
	// exactly one tick per round, the same cadence the nodes tick their own clocks
	// at. Feeding it to rh.Tick lets the Router time an unanswered attempt out on
	// the very clock the cluster runs on, which is what 4.1a made possible and what
	// runClusterSeed deliberately does not do.
	advance := func() {
		tickHosts(t, hosts, shard)
		net.Tick()
		if terr := rh.Tick(net.Clock().Now()); terr != nil {
			t.Fatalf("router host tick: %v", terr)
		}
	}
	// drivePoll spends a bounded round budget waiting for one op to resolve, and
	// because advance ticks rh, the wait itself drives the retransmit.
	drivePoll := func(opID uint64, budget int) (RouteResult, bool) {
		for i := 0; i < budget; i++ {
			advance()
			if res, ok := rh.Result(opID); ok {
				return res, true
			}
		}
		return RouteResult{}, false
	}

	// Bring the single shard to an elected leader.
	const electBudget = 600
	leader := cluster.None
	for i := 0; i < electBudget; i++ {
		advance()
		if leader = hostLeaderOf(hosts, shard); leader != cluster.None {
			break
		}
	}
	if leader == cluster.None {
		t.Fatalf("shard did not elect a leader within %d rounds", electBudget)
	}

	// Mute the leader toward the router: block only leader -> routerID. The leader
	// still receives client requests (routerID -> leader stays open) and still
	// replicates with its peers (no leader-to-peer edge is touched), so it keeps
	// quorum, commits the write, and holds office; only its ack to the router is
	// lost. Leadership cannot churn out from under the test, because the mute never
	// blocks a heartbeat.
	net.Partition(leader, routerID)

	// Issue EXACTLY ONE operation. No reissueUntilOK and no second Upsert: the
	// caller emits once and then only polls. The router's first attempt lands on
	// the leader, directly or after a follower's NotLeader redirect whose reply is
	// not muted, the leader commits and answers OK, and that OK is swallowed by the
	// mute.
	const writeID uint64 = 7
	vec := vecFor(writeID)
	opID, err := rh.Upsert(writeID, vec)
	if err != nil {
		t.Fatalf("upsert: %v", err)
	}

	// Drive past retransmitTimeout so at least one retransmit fires, but stay well
	// under the op's budget of 3*len(group) = 9 attempts so it cannot exhaust. Each
	// retransmit re-aims at the SAME muted leader: emitAttempt only moves targetIdx
	// on a NotLeader reply, and a muted leader never gets one back to the router. So
	// while the mute holds, every attempt answers into the void and the op cannot
	// resolve. This window both runs the retransmit machinery and sets up the
	// sub-check below.
	const muteWindow = int(retransmitTimeout)*2 + 20
	for i := 0; i < muteWindow; i++ {
		advance()
	}

	// Sub-check, robust rather than fragile: with the mute still up and no random
	// drops in this fabric, the leader's ack is the only lost frame, so the op
	// provably cannot have resolved yet. If it had, the heal below would not be what
	// recovered it and the test would be a false green.
	if res, ok := rh.Result(opID); ok {
		t.Fatalf("op resolved while the leader was muted (%+v); the heal is not what recovered it", res)
	}

	// Heal the leader -> router channel. The write is already committed on the
	// leader, so the next retransmit's reply crosses immediately and carries the
	// commit index.
	net.Heal(leader, routerID)

	// The caller still does nothing but poll. A retransmit emitted after the heal
	// reaches the leader and its ack now lands, flipping the op to a definitive OK.
	// That OK is the protocol recovering a lost frame on its own clock, not the
	// caller re-issuing.
	const recoverBudget = 400
	res, done := drivePoll(opID, recoverBudget)
	if !done {
		t.Fatalf("op did not recover within %d rounds after healing the muted leader", recoverBudget)
	}
	if res.Status != StatusOK || res.Exhausted || res.Index == 0 {
		t.Fatalf("recovered op is not a clean write ack: %+v", res)
	}

	if herr := rh.Err(); herr != nil {
		t.Fatalf("router host poisoned: %v", herr)
	}
	for _, id := range shard {
		if herr := hosts[id].Err(); herr != nil {
			t.Fatalf("host %d poisoned: %v", id, herr)
		}
	}
}

// TestClusterDST_CommittedLogIsFaithful audits the committed log of every shard
// through the read-only accessor of 4.2 (Node.CommittedCommands, backed by
// Raft.CommittedEntries) and asserts it is a FAITHFUL and COMPLETE record of the
// converged state (DEFER-013). It runs a small two-shard cluster of real nodes
// under crash chaos to convergence, then for each shard reads a replica's
// committed commands, replays them in index order, and asserts: no phantoms
// (every committed id is one the schedule wrote), correct sharding (every id
// maps to the shard whose log holds it), and a faithful replay (every replica's
// committed log replays to exactly the oracle's live set for that shard, so the
// replicas agree on the resulting state).
//
// It is a dedicated test with its own small harness: it never touches
// runClusterSeed or the sealed sweep, so the 500-seed sweep's numbers stay
// exactly as they were. The harness is the deterministic pump of the router
// integration tests over raw nodes, not SimNet, so the audit reads
// Node.CommittedCommands directly without reaching through a Host and without a
// clock or goroutine of its own.
//
// The claim is deliberately log-fidelity, NOT physical exactly-once. A client
// reqID never travels in a log entry (command.go), and a re-issue or a
// retransmission commits duplicate idempotent entries the node does not
// deduplicate. The schedule repeats ids on purpose, so duplicate committed
// upserts of one id are the common case; the replay overwrites and the final
// state is correct, and the checker counts those duplicates as expected, never
// as a violation. The accessor is read-only by construction: the audit only
// reads committed entries and decodes them, it never proposes, applies or emits.
func TestClusterDST_CommittedLogIsFaithful(t *testing.T) {
	// Seed budget follows TestClusterDST_Seeded's pattern but with its OWN env,
	// NAYLAMP_FAITHFUL_SEEDS, so scaling this audit does not also scale the sealed
	// sweep and vice versa: each is a multi-minute cost under race, and one knob
	// governing both would couple them. The default stays modest, 40, and short
	// drops to 6, so a local go test is quick; the DONE of >=500 seeds is met by
	// NAYLAMP_FAITHFUL_SEEDS=500 in CI. NAYLAMP_FAITHFUL_SEED (singular) pins one
	// seed for a replay.
	seeds := 40
	if testing.Short() {
		seeds = 6
	}
	if env := os.Getenv("NAYLAMP_FAITHFUL_SEEDS"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_FAITHFUL_SEEDS=%q invalid", env)
		}
		seeds = v
	}
	start, end := 1, seeds
	if env := os.Getenv("NAYLAMP_FAITHFUL_SEED"); env != "" {
		v, err := strconv.Atoi(env)
		if err != nil || v < 1 {
			t.Fatalf("NAYLAMP_FAITHFUL_SEED=%q invalid", env)
		}
		start, end = v, v
	}
	for s := start; s <= end; s++ {
		checkFaithfulSeed(t, uint64(s)) //nolint:gosec // s ranges over positive seed numbers
	}
}

// checkFaithfulSeed runs one seed of the log-fidelity audit end to end.
func checkFaithfulSeed(t *testing.T, seed uint64) {
	t.Helper()

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
	nodes := map[cluster.NodeID]*Node{}

	nodeSeed := func(id cluster.NodeID, gen uint64) uint64 {
		return seed*0x9E3779B97F4A7C15 + uint64(id)*0x100000001B3 + gen
	}
	open := func(id cluster.NodeID) {
		n, err := OpenNode(dirs[id], id, groupCfg[id], 3, testRNG(nodeSeed(id, restarts[id])), NodeOptions{})
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		nodes[id] = n
	}
	for _, id := range allIDs {
		open(id)
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()

	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("seed %d: new router: %v", seed, err)
	}

	// commit routes one write to its shard's leader and drives it to a definitive
	// OK ack, re-electing and re-issuing past a transient leaderless window. The
	// pump moves messages but never ticks, so leadership cannot change mid-write;
	// driveUntilLeader before each attempt is what recovers after a crash.
	commit := func(sh int, mk func() (uint64, [][]byte, error)) {
		for attempt := 0; attempt < 6; attempt++ {
			_ = driveUntilLeader(t, nodes, shardIDs[sh], 400)
			opID, frames, oerr := mk()
			if oerr != nil {
				t.Fatalf("seed %d: router op: %v", seed, oerr)
			}
			pumpWithRouter(t, nodes, router, frames, 8000)
			if res, ok := router.Result(opID); ok && res.Status == StatusOK && !res.Exhausted && res.Index != 0 {
				return
			}
		}
		t.Fatalf("seed %d: a write to shard %d never committed", seed, sh)
	}

	shardOf := func(v cluster.NodeID) int {
		for sh := range shardIDs {
			for _, id := range shardIDs[sh] {
				if id == v {
					return sh
				}
			}
		}
		return 0
	}

	oracle := map[uint64][]float32{}
	seen := map[uint64]bool{}
	chaos := testRNG(seed ^ 0xF117DE10F1DE1174)
	downNode := cluster.None

	const rounds = 24
	for step := 0; step < rounds; step++ {
		// One client op. Ids repeat across rounds by design, so the same id commits
		// several upsert entries: exactly the idempotent duplicate the checker must
		// tolerate. Writes go only to a shard with every node present: a raw router
		// is never ticked, so a request aimed at a crashed node is dropped with no
		// retransmit and the op would never resolve. Skipping an impaired shard,
		// like the sweep does, keeps the oracle an exact model of what committed.
		id := uint64(1 + chaos.IntN(clusterIDRange)) //nolint:gosec // 1+IntN(range) is a small positive int
		sh := sm.ShardFor(id)
		if downNode == cluster.None || shardOf(downNode) != sh {
			seen[id] = true
			if chaos.IntN(10) < 7 {
				vec := vecFor(id)
				commit(sh, func() (uint64, [][]byte, error) { return router.Upsert(id, vec) })
				oracle[id] = vec
			} else {
				commit(sh, func() (uint64, [][]byte, error) { return router.Delete(id) })
				delete(oracle, id)
			}
		}

		// Single-slot crash chaos: at most one node down at a time, so every shard
		// keeps quorum and the committed log keeps growing under fault.
		if chaos.IntN(10) < 3 {
			if downNode == cluster.None {
				v := allIDs[chaos.IntN(len(allIDs))]
				_ = nodes[v].Close()
				delete(nodes, v)
				downNode = v
			} else {
				restarts[downNode]++
				open(downNode) // recovery is real: OpenNode replays the committed log from disk
				downNode = cluster.None
			}
		}
	}

	// Quiesce: restart any crashed node and drive each shard to convergence, so
	// every present replica has applied the same committed prefix.
	if downNode != cluster.None {
		restarts[downNode]++
		open(downNode)
	}
	for sh := range shardIDs {
		_ = driveUntilLeader(t, nodes, shardIDs[sh], 400)
		if !driveUntilConverged(t, nodes, shardIDs[sh], 3000) {
			t.Fatalf("seed %d: shard %d did not converge", seed, sh)
		}
	}

	// Audit each shard's committed log through the read-only accessor, per replica.
	// Converged replicas can hold committed logs that differ by a trailing
	// state-neutral entry: a follower's commit index lags the leader by a re-upsert
	// of an already-present value or a delete of an absent id, neither of which
	// moves StateHash, so convergence does not wait on it. Every replica still
	// replays to the same live set, so the fidelity claim is about the replayed
	// STATE, not raw log equality. Checking every replica against the oracle proves
	// (2) no gaps and (4) the replicas agree, and it stays robust to that lag.
	//
	// It also folds task 4.2.6 (FaithfulMatchesObservable) in here rather than a
	// separate test: on every converged replica the same replay must match what the
	// node's index actually SERVES. The observable is served from the applied state
	// and the replay comes from the committed log; on a converged replica applied
	// equals commit, which driveUntilConverged guarantees above, so the two
	// coincide. That closes the triangulation oracle == replay == observable.
	enumQuery := []float32{1, 0, 0}
	for sh := range shardIDs {
		want := map[uint64][]float32{}
		for id, v := range oracle {
			if sm.ShardFor(id) == sh {
				want[id] = v
			}
		}
		for _, id := range shardIDs[sh] {
			cmds, cerr := nodes[id].CommittedCommands()
			if cerr != nil {
				t.Fatalf("seed %d: shard %d node %d committed commands: %v", seed, sh, id, cerr)
			}
			replay := map[uint64][]float32{}
			for _, c := range cmds {
				// (3) Correct sharding: the log of shard sh holds only ids that map there.
				if sm.ShardFor(c.ID) != sh {
					t.Fatalf("seed %d: shard %d node %d committed id %d that maps to shard %d", seed, sh, id, c.ID, sm.ShardFor(c.ID))
				}
				// (1) No phantoms: every committed id is one the schedule wrote.
				if !seen[c.ID] {
					t.Fatalf("seed %d: shard %d node %d committed a phantom id %d the schedule never wrote", seed, sh, id, c.ID)
				}
				switch c.Op {
				case opUpsert:
					replay[c.ID] = c.Vec
				case opDelete:
					delete(replay, c.ID)
				default:
					t.Fatalf("seed %d: shard %d node %d committed an unknown op %d", seed, sh, id, c.Op)
				}
			}
			// (2) and (4): the replay reproduces exactly the oracle's live set for
			// this shard, on every replica. Duplicate upserts collapsed to one live
			// value along the way, which is the idempotency the checker relies on.
			if len(replay) != len(want) {
				t.Fatalf("seed %d: shard %d node %d replay holds %d live ids, oracle maps %d there", seed, sh, id, len(replay), len(want))
			}
			for wid, v := range want {
				rv, ok := replay[wid]
				if !ok {
					t.Fatalf("seed %d: shard %d node %d replay is missing acked id %d", seed, sh, id, wid)
				}
				if !sameVec32(rv, v) {
					t.Fatalf("seed %d: shard %d node %d id %d replay vec %v, oracle %v", seed, sh, id, wid, rv, v)
				}
			}

			// FaithfulMatchesObservable (task 4.2.6): the replay must equal what this
			// replica's index actually serves. Checked on EVERY replica, not just one:
			// a Search on this tiny index is cheap and it proves each replica's served
			// state agrees with its own committed log, from the same applied-equals-
			// commit point, so a lagging follower is compared against its own served
			// state and stays consistent. An enumerate with k above the live size
			// returns exactly the served set.
			got, gerr := nodes[id].Search(enumQuery, clusterIDRange)
			if gerr != nil {
				t.Fatalf("seed %d: shard %d node %d observable enumerate: %v", seed, sh, id, gerr)
			}
			if len(got) != len(replay) {
				t.Fatalf("seed %d: shard %d node %d observable serves %d ids, log replays %d", seed, sh, id, len(got), len(replay))
			}
			for rid := range replay {
				near, serr := nodes[id].Search(vecFor(rid), 1)
				if serr != nil {
					t.Fatalf("seed %d: shard %d node %d observable search id %d: %v", seed, sh, id, rid, serr)
				}
				if len(near) != 1 || near[0].ID != rid {
					t.Fatalf("seed %d: shard %d node %d observable nearest to id %d = %+v, want that id", seed, sh, id, rid, near)
				}
			}
		}
	}
}

// sameVec32 reports whether two float32 vectors are bit-for-bit equal, which the
// exact round trip through encodeUpsert and decodeCommand preserves.
func sameVec32(a, b []float32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestClusterDST_ReadIndexLinearizableLiteral makes the ReadIndex barrier
// literal (DEFER-014). It is a REINFORCEMENT of what 3.5 already proves
// observably (read-your-writes under chaos), not a new property: it exposes the
// read index R through the read-only accessor Node.ReadIndex and asserts, with
// explicit indices, that R >= W (W is the commit index of a write that landed
// before the read) and that the served state has applied >= R, which is exactly
// ReadServable's predicate, while a Search still returns the written id. So the
// index relationship 3.5 only observed by its effect is now stated by number.
//
// It runs its own small cluster of real nodes over the deterministic pump, never
// the sealed sweep. The accessor is read-only and touches neither the wire nor
// consensus, so the search-without-index wire guard stays intact and untouched:
// the codec side is exercised by TestClientWire_MalformedFailsLoudly (its "ok
// both write and search" case) and the router side by
// TestRouter_SearchGuardsAndRetries, so this piece references that coverage
// rather than duplicating it.
func TestClusterDST_ReadIndexLinearizableLiteral(t *testing.T) {
	seeds := 8
	if testing.Short() {
		seeds = 3
	}
	for s := 1; s <= seeds; s++ {
		checkReadIndexLiteral(t, uint64(s)) //nolint:gosec // s ranges over positive seed numbers
	}
}

// checkReadIndexLiteral runs one seed of the literal read-index audit.
func checkReadIndexLiteral(t *testing.T, seed uint64) {
	t.Helper()

	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	nodes := map[cluster.NodeID]*Node{}
	for _, id := range ids {
		n, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(seed*0x100000001B3+uint64(id)), NodeOptions{})
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		nodes[id] = n
	}
	defer func() {
		for _, n := range nodes {
			_ = n.Close()
		}
	}()

	lead := driveUntilLeader(t, nodes, ids, 400)
	leader := nodes[lead]

	// A write lands and commits at index W before the read is registered.
	const wid uint64 = 7
	vec := vecFor(wid)
	w, out, err := leader.Upsert(wid, vec)
	if err != nil {
		t.Fatalf("seed %d: upsert on leader %d: %v", seed, lead, err)
	}
	pump(t, nodes, out, 4000)

	// Register a linearizable read on the leader and drive its confirmation round
	// so the read index is recorded in n.reads.
	ctx, rout, err := leader.BeginRead()
	if err != nil {
		t.Fatalf("seed %d: begin read on leader %d: %v", seed, lead, err)
	}
	pump(t, nodes, rout, 4000)

	// R is the read index the barrier captured. Read it WITHOUT consuming the ctx,
	// so ReadServable below still resolves the read normally.
	r, ok := leader.ReadIndex(ctx)
	if !ok {
		t.Fatalf("seed %d: read index not recorded for ctx %d", seed, ctx)
	}
	// Literal linearizability, half one: the read index is at least the commit
	// index of the write that preceded the read.
	if r < w {
		t.Fatalf("seed %d: read index %d is below the prior write's commit index %d", seed, r, w)
	}

	// Literal linearizability, half two: the read becomes servable only once the
	// applied state has reached R, which is exactly ReadServable's predicate
	// (applied >= R). It should already hold on the leader, which applies as it
	// commits, so ReadServable resolves on the first check; the bounded loop is a
	// guard, not an expectation.
	servable := false
	for i := 0; i < 400; i++ {
		if leader.ReadServable(ctx) {
			servable = true
			break
		}
		pump(t, nodes, tickAll(t, nodes, ids), 4000)
	}
	if !servable {
		t.Fatalf("seed %d: read ctx %d never became servable (applied never reached R=%d)", seed, ctx, r)
	}

	// The observable consequence of the barrier: the served state reflects the
	// write, so a Search returns the written id. This is read-your-writes, now
	// with the index relationship R >= W made literal above.
	got, err := leader.Search(vec, 1)
	if err != nil {
		t.Fatalf("seed %d: served search: %v", seed, err)
	}
	if len(got) != 1 || got[0].ID != wid {
		t.Fatalf("seed %d: served read does not reflect the write: got %+v, want id %d", seed, got, wid)
	}
}
