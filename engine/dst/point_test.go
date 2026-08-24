package dst

import (
	"encoding/binary"
	"fmt"
	"hash/crc64"
	"math"
	"math/rand/v2"
	"sort"
	"testing"
	"time"

	"naylamp/engine/naylamp"
	"naylamp/engine/vector"
)

// This file holds the two defenders the central property of Phase 1 was missing
// at the top of its declared point. Both live here, in package dst, because they
// need the invariant checkers next door and because keeping them here leaves the
// gate with two test binaries instead of three.
//
// The property is stated in NAYLAMP_PHASE_1.md, outside this repository, and its
// three clauses are: (i) the index's live id set is exactly the ids upserted and
// not deleted, in both directions; (ii) every live id is reachable, meaning a
// query with its own vector returns it first; and (iii) a k-NN query returns
// min(k, live) live ids and the returned set agrees with brute force above a
// recall floor, at the point declared there. The point is gaussian data from a
// fixed seed, cosine distance, k=10, efSearch=300, dim between 32 and 64, and
// recall@10 >= 0.95 for n up to 50000.
//
// WHAT THESE TWO ADD IS THE SURFACE AND THE TOP OF THE POINT, NOT THE CLAUSES.
// The clauses already have defenders: the seeded sweep in this package asserts
// all three on every push. What it does not do is assert them where the property
// says they hold, which is "any collection built by the engine's API", and at the
// size the point declares: the sweep runs dim=16 and a hundred ids, one layer
// below nothing but with a corpus three orders of magnitude short of the bound.
// The three recall assertions in package hnsw do reach 50000, and they build with
// NewIndex plus a hand-wired vector.Store, one layer BELOW Engine.CreateCollection.
// So at the top of the point the API was untested and below it the size was; this
// file is the one place both are true at once.
//
// The two items this closes are DEFER-047, for the recall floor measured through
// the API, and DEFER-048, for the shape half of clause (iii) asserted on
// Collection rather than two layers up in the router. Both are in
// NAYLAMP_DEFERRED_BACKLOG.md, outside this repository.

// The campaign's constants. They stay named constants here and never
// move to an environment variable, because a size that can be overridden from the
// environment is a size the artifact cannot state, and because GOFLAGS can supply
// any test flag a command line omits. The gate designed to read them out of this
// source, anchoring by function name rather than by line, does not exist yet.
const (
	// pointDim is 64, the top of the interval the point declares. The point says
	// dim from 32 to 64 and this samples one value; that is a sample and not
	// coverage, and the gate declares it as such.
	pointDim = 64

	// pointK is the k the point declares.
	pointK = 10

	// pointQueries is how many query vectors the recall floor averages over. It
	// matches the count the tree's own 50000 case uses, so the two numbers are
	// comparable.
	pointQueries = 50

	// pointFloor is the recall floor the property claims. It is the claimed
	// number and not the measured one, on purpose and for the same reason the
	// three assertions in package hnsw give: a threshold pinned to today's output
	// turns any change into a failure, while this one falsifies what the phase
	// promised.
	pointFloor = 0.95

	// The three seeds match what the tree's 50000 case passes, so the generator,
	// the index construction and the query stream are the same three streams.
	//
	// WHAT THAT BUYS AND WHAT IT DOES NOT. It buys that a difference in recall
	// between the two cannot come from the seeds. It does NOT buy that the two
	// measure the same corpus: that case builds a pristine 50000, and this one
	// builds 60009 and deletes a seeded 10009, so its live 50000 is a different set
	// of vectors reached through a graph that has absorbed 10009 deletions. The two
	// figures differ in the third decimal, 0.994 there against 0.990 here, and that
	// gap is the deletions and not noise.
	pointCorpusSeed = 1
	pointIndexSeed  = 2
	pointQuerySeed  = 99

	// pointDeleteSeed drives the shuffle that picks which ids the campaign
	// deletes.
	pointDeleteSeed = 7

	// THE CAMPAIGN BUILDS MORE THAN IT KEEPS, and that is the whole reason it is
	// shaped this way rather than as "build the bound and delete". Deleting from
	// 50000 leaves 39991 live, and then clauses (i) and (ii) are exercised at 80
	// per cent of the bound rather than at it, which is exactly the gap the gate's
	// exclusion 13 exists to name. Building 60009 and deleting 10009 lands the
	// LIVE set on 50000, so the deletes are still inside the sequence and the
	// checks still happen at the declared top.
	//
	// The deletes are not optional. Without them the "none too many" direction of
	// clause (i) is unreachable, since a ghost is what a half-done delete leaves,
	// and the liveness half of clause (iii) means nothing when no id is dead.
	pointBuilt = 60009
	pointLive  = 50000

	// The short arm keeps the proportion and drops the size, the same shape the
	// seeded sweep in this package uses for its budget. Everything the campaign
	// asserts runs here too, including the degenerate rung, so what the push path
	// defends is the whole of both defenders and not a subset of them.
	pointShortBuilt = 1200

	// The corpus digests were taken on 24 August 2026 by running makeRandomVectors
	// from package hnsw and hashing its output the way corpusDigest does. That
	// helper cannot be called from here: it is a test helper in another package,
	// and this package cannot import that one without inverting the dependency.
	//
	// WHAT THE PIN CATCHES IS ONE SIDE, and saying which matters. It catches drift
	// in pointCorpus below, which is the copy. It does NOT catch drift in the
	// original: if makeRandomVectors changes, this test stays green against a
	// constant that has stopped describing anything, and the two corpora part
	// company in silence. Closing that needs the two generators compared in one
	// process, which needs a home neither package can give it today.
	pointDigestFull  = 0x660124a695c1d333
	pointDigestShort = 0x795ec92ac9aeb421

	// pointDefectSample caps how many shape failures print in full. A broken index
	// breaks every query in the stream, and fifty copies of one line say nothing the
	// first one did not; the count of how many failed goes in a line of its own, so
	// the cap hides no information.
	pointDefectSample = 5
)

// TestPoint_TheThreeClausesTogetherByTheAPI drives one collection through the
// engine's public API and asserts all three clauses of the central property on
// it, at the top of the declared point.
//
// THE THREE FALL ON ONE COLLECTION AND THAT IS THE POINT OF THE TEST. Clause
// (iii) is a conjunction: a query returns min(k, live) LIVE ids AND agrees with
// brute force. Asserting the shape on one collection and the floor on another
// never satisfies it anywhere. The same argument covers (i) and (ii): the
// property opens with "on any collection built by the engine's API", so the
// three have to hold together on one such collection or the sentence has not
// been exercised.
//
// THE ORDER INSIDE IS FIXED HERE AND NOT LEFT TO WHOEVER READS IT, because it
// decides which clause a failure is attributed to. Exact before threshold, so a
// missed floor cannot bury a broken set; and the degenerate rung AFTER the
// reachability sweep, because Search really implements min(k, reachable from the
// descended entry point) and not min(k, live). The two coincide only while
// clause (ii) holds, so a graph that has fragmented would fail the degenerate
// length check, and reporting that as a shape defect would blame clause (iii)
// for a clause (ii) failure.
//
// EVERY CHECK USES t.Errorf AND NOT t.Fatalf, for the same reason the order is
// fixed: the gate splits its verdicts by clause, and a checker that stops at the
// first failure leaves the others unrun, which the gate's rules count as not
// passed rather than as green. One collection has to produce one verdict per
// clause even when the first of them is red.
func TestPoint_TheThreeClausesTogetherByTheAPI(t *testing.T) {
	built := pointBuilt
	wantDigest := uint64(pointDigestFull)
	if testing.Short() {
		built = pointShortBuilt
		wantDigest = uint64(pointDigestShort)
	}
	// The product goes through int64 because built*pointLive is 3,000,450,000 at
	// full size, which overflows a 32-bit int, and 386 is a target this module
	// still compiles for.
	live := int(int64(built) * pointLive / pointBuilt)

	// The progress lines are not decoration. At full size this runs for minutes
	// on a machine nobody is watching, and a run that is going wrong has to be
	// visible in the log before its timeout rather than only after it: a timeout
	// panic names the test and dumps goroutines, and prints none of what the test
	// had accumulated. They need -v on the command line to reach the log.
	//
	// NOTHING RUNS THE FULL ARM TODAY, and that goes here rather than in a document
	// nobody reads next to the code: CI passes -short on the whole tree, its one
	// unshortened step names another test, and no scheduled workflow exists. So the
	// 50000 bound and the digest below are exercised only by hand until the job
	// that runs them is written. The neighbouring case in package hnsw says the
	// same about itself, and it says it because someone who opens a test to find
	// out who defends a bound should not have to go looking.
	t.Logf("P1.point: building %d, deleting %d, leaving %d live, dim=%d k=%d", built, built-live, live, pointDim, pointK)

	// Every phase below prints its own elapsed time. A run that is going slowly has
	// to say WHERE, not just that it is: a timeout panic names the test and nothing
	// else, so the last line printed is the only diagnosis anyone gets. These are
	// also the numbers that decide whether the scheduled job's allowance still
	// covers this test after a change, and reading them off a log beats guessing
	// from a total.
	phase := time.Now()
	since := func() float64 {
		d := time.Since(phase).Seconds()
		phase = time.Now()
		return d
	}

	corpus := pointCorpus(built, pointDim, pointCorpusSeed)
	gotDigest := corpusDigest(corpus)
	if gotDigest != wantDigest {
		t.Fatalf("P1.point: corpus digest is %016x, want %016x: the generator here has drifted from the one in package hnsw, so this run would measure a different point under the same name", gotDigest, wantDigest)
	}
	t.Logf("P1.point: corpus digest %016x, matches the constant taken from the generator in package hnsw", gotDigest)

	eng := naylamp.New()
	col, err := eng.CreateCollection("point", pointDim, vector.CosineDistance, pointIndexSeed)
	if err != nil {
		t.Fatalf("P1.point: CreateCollection: %v", err)
	}

	// The oracle is the same one the seeded sweep keeps, so the three invariant
	// checkers below are the ones that already run on every push and not a second
	// implementation of them.
	orc := newOracle()
	for i, v := range corpus {
		if err := col.Upsert(v.ID, v.Data); err != nil {
			t.Fatalf("P1.point: Upsert(%d): %v", v.ID, err)
		}
		orc.upsert(v.ID, v.Data)
		if (i+1)%10000 == 0 {
			t.Logf("P1.point: upserted %d / %d", i+1, built)
		}
	}
	t.Logf("P1.point: build %.2fs", since())

	victims := pointVictims(corpus, built-live, pointDeleteSeed)
	for _, id := range victims {
		if err := col.Delete(id); err != nil {
			t.Fatalf("P1.point: Delete(%d): %v", id, err)
		}
		orc.delete(id)
	}
	t.Logf("P1.point: deleted %d, %d live, %.2fs", len(victims), orc.count(), since())

	// Clause (i), and the bookkeeping that is not a clause. The count goes first
	// and keeps its own label because it watches the STORE while the set watches
	// the INDEX, and only the second of those is what clause (i) speaks about.
	// Reporting a store defect as a clause failure was a real error once and it
	// has a number, so the two never share a verdict.
	if err := checkStoreCount(col, orc); err != nil {
		t.Errorf("P1.point.ledger: %v", err)
	}
	if err := checkIndexSet(col, orc); err != nil {
		t.Errorf("P1.point.exact: %v", err)
	}
	t.Logf("P1.point.exact: set compared, %.2fs", since())

	// Clause (ii), paid in full over every live id and never sampled. The clause
	// says EVERY live id is reachable, and a sample turns an exact claim into a
	// rate: it stops being falsifiable by one counterexample and starts needing a
	// confidence, which is the apparatus clauses (i) and (ii) exist to avoid.
	if err := checkReachability(col, orc); err != nil {
		t.Errorf("P1.point.reach: %v", err)
	}
	t.Logf("P1.point.reach: swept %d live ids, %.2fs", orc.count(), since())

	queries := pointQueryVectors(pointQueries, pointDim, pointQuerySeed)

	// Clause (iii), both halves, over ONE pass of the query stream. The shape and
	// the floor look at the same answers, so asking twice would double the cost and
	// leave open the possibility of the two halves judging different results.
	// The floor is accumulated here and REPORTED last, after the degenerate rung,
	// because it is the only threshold in the property and a missed threshold must
	// not be able to bury an exact check.
	shapeOK, hits, reported, failedQuery := 0, 0, 0, 0
	for qi, q := range queries {
		got, err := col.Query(q, pointK)
		if err != nil {
			// Unreachable through this test: Query fails only on a wrong dim or a
			// non-positive k, and both are constants here. It is reported rather
			// than swallowed because a silent skip would still count pointK toward
			// the recall denominator below and depress the floor for a reason that
			// is not recall.
			// Labelled as the query and not as the shape, because the shape check
			// did not run on it and an unrun check is not a failed one.
			t.Errorf("P1.point.query: query %d failed: %v", qi, err)
			failedQuery++
			continue
		}
		// THE TWO HALVES JUDGE THE SAME ANSWER AND NEITHER SKIPS ON THE OTHER'S
		// FAILURE, which is the whole reason they share a loop rather than taking
		// the obvious early `continue`.
		//
		// A first draft did take it, and that coupled the two halves of clause (iii).
		// Measured: the mutation that stops truncating to k took the floor from
		// green to 0.0000, and the one that seeds layer 0 twice took it to 0.8200,
		// when neither of them touches recall at all. One mutation reddened two
		// clauses and nothing downstream could say which one it had caught.
		//
		// That is grouping verdicts, which is what the property's own grading rule
		// forbids and why the three recall points are graded one by one rather than
		// together: grouping lets a point that bites hide two that do not. The
		// defect survived writing this file, writing the paragraph above that says
		// the two halves are scored apart, and reading it back; what found it was
		// running the mutations. Hence the shape of the loop, and hence this
		// comment sitting where the mistake was rather than in a note.
		// THE NUMERATOR IS COUNTED OVER A DEDUPLICATED, k-CAPPED VIEW, and that is
		// not defensive tidying: without it a DEFECT CAN RAISE THE FLOOR. Measured
		// on a mutated copy: efSearch=18 alone reports 0.9380, and efSearch=18 plus
		// the mutation that seeds layer 0 twice reports 0.9440, because a duplicate
		// that happens to be a true neighbour is counted twice against a
		// denominator fixed at k. The second tree is strictly worse and scored
		// higher. Truncation defects do the same from the other side, by drawing
		// hits from more ids than k while the denominator still says k.
		//
		// A first draft of this loop had the opposite bug, a shape failure skipping
		// the recall accumulation, which turned a defect into a false RED. Fixing
		// that one carelessly produced this one, a false GREEN, which by this
		// project's grading rule is the worse of the two: a red gets investigated
		// and a green does not.
		truth := pointBruteForce(q, orc, pointK)
		counted := make(map[uint64]struct{}, pointK)
		for _, g := range got {
			if len(counted) == pointK {
				break
			}
			if _, dup := counted[g.ID]; dup {
				continue
			}
			counted[g.ID] = struct{}{}
			if truth[g.ID] {
				hits++
			}
		}

		if bad := pointShapeDefect(got, orc, pointK); bad != nil {
			// A broken index breaks every query in the stream, so the same line
			// would print fifty times and say nothing the first one did not. The
			// count of how many failed is what carries the information, and it goes
			// in the summary below.
			if reported < pointDefectSample {
				t.Errorf("P1.point.shape: query %d at k=%d over %d live: %v", qi, pointK, orc.count(), bad)
				reported++
			}
			continue
		}
		shapeOK++
	}
	if failed := len(queries) - shapeOK - failedQuery; failed > reported {
		t.Errorf("P1.point.shape: %d queries failed the shape check, %d of them printed above", failed, reported)
	}
	t.Logf("P1.point.shape: %d/%d queries returned min(k, live) distinct live ids at k=%d, %.2fs with the brute force inside", shapeOK, len(queries), pointK, since())

	// Clause (iii), shape half, DEGENERATE CASE, and at the top of the point.
	//
	// The degenerate case is fewer live than k, and reaching it by deleting would
	// mean deleting almost the whole collection. It is reachable from the other
	// side with one query, because Search raises its own efSearch to k whenever k
	// is larger, so asking for live+1 makes the layer-0 walk exhaustive and the
	// truncation to k never fires. That is what makes min(k, live) with k above
	// live affordable at this size at all.
	//
	// Two things about this rung go in the artifact rather than being inherited.
	// It runs with layer 0 NOT pruning, since ef equals k which exceeds the live
	// count, so the argument that reachability at 50000 is stronger than the
	// sweep's because layer 0 prunes there does not carry over to it. And what it
	// asserts is a reachability statement as much as a shape one: it says one
	// query reaches every live node.
	degenK := orc.count() + 1
	degen, err := col.Query(queries[0], degenK)
	if err != nil {
		t.Errorf("P1.point.shape: degenerate query at k=%d failed: %v", degenK, err)
	} else if bad := pointShapeDefect(degen, orc, degenK); bad != nil {
		t.Errorf("P1.point.shape: degenerate query at k=%d over %d live: %v", degenK, orc.count(), bad)
	} else {
		t.Logf("P1.point.shape: degenerate query at k=%d returned %d distinct live ids, %.2fs", degenK, len(degen), since())
	}

	// Clause (iii), floor half.
	//
	// THE GROUND TRUTH WAS RECOMPUTED OVER THE SURVIVORS, inside the loop above.
	// Reusing the truth from before the deletes would sink recall mechanically,
	// because a true neighbour that was deleted cannot be returned by anyone, and
	// would turn the gate red for something that is not a defect.
	recall := float64(hits) / float64(len(queries)*pointK)

	// The line below is what a gate would parse, so it prints on every run and not
	// only on failure. Without it a run that never happened and a run that passed
	// produce the same output, which is the shape of a green that means nothing.
	t.Logf("P1.point.floor: recall@%d = %.4f over %d queries at %d live, floor %.2f", pointK, recall, len(queries), orc.count(), pointFloor)
	if recall < pointFloor {
		t.Errorf("P1.point.floor: recall@%d = %.4f at %d live, want >= %.2f", pointK, recall, orc.count(), pointFloor)
	}
}

// pointShapeDefect reports what is wrong with a query result under clause (iii)'s
// shape half, and nil when nothing is. It checks the three things
// that sentence says, and says which one failed rather than just that one did.
//
// The three are the length, min(k, live); that the ids are distinct, because
// "min(k, live) live ids" reads as distinct ids and nothing in the tree asserted
// it before this; and that every returned id is live.
//
// THE LIVENESS CHECK IS ENTAILED HERE AND IT STAYS ANYWAY, which is worth saying
// plainly because a check that cannot fail is usually worth deleting. Search can
// only return ids the index holds, so once the set check above has passed on this
// same state, every returned id is in the oracle by construction. What liveness
// buys is a defender that survives the set check being moved, removed or pointed
// at another object, and it costs one map lookup per returned id. It is not
// scored as a red arm of its own, and the artifact says so.
func pointShapeDefect(got []vector.Neighbor, orc *oracle, k int) error {
	want := k
	if orc.count() < k {
		want = orc.count()
	}
	if len(got) != want {
		return fmt.Errorf("returned %d ids, want min(k, live) = %d", len(got), want)
	}
	seen := make(map[uint64]struct{}, len(got))
	for _, n := range got {
		if _, dup := seen[n.ID]; dup {
			return fmt.Errorf("id %d returned more than once", n.ID)
		}
		seen[n.ID] = struct{}{}
		if !orc.has(n.ID) {
			return fmt.Errorf("id %d was returned but is not live", n.ID)
		}
	}
	return nil
}

// pointCorpus generates the campaign's vectors. It is a line-by-line copy of
// makeRandomVectors in package hnsw, and it is a copy because that one is a test
// helper in a package this one cannot import: naylamp imports hnsw, so the edge
// back would close a cycle. The digest constants above are what keep the copy
// honest; see the comment on them.
func pointCorpus(n, dim int, seed uint64) []vector.Vector {
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for test data
	vecs := make([]vector.Vector, n)
	for i := range vecs {
		data := make([]float32, dim)
		for j := range data {
			data[j] = float32(rng.NormFloat64())
		}
		vecs[i] = vector.Vector{ID: uint64(i + 1), Data: data} //nolint:gosec // i is a loop index over a slice, so i+1 is positive and fits
	}
	return vecs
}

// pointQueryVectors generates the query stream, in the same order and from the
// same generator the tree's 50000 case uses, so the recall figures compare.
func pointQueryVectors(n, dim int, seed uint64) [][]float32 {
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for test data
	out := make([][]float32, n)
	for i := range out {
		q := make([]float32, dim)
		for j := range q {
			q[j] = float32(rng.NormFloat64())
		}
		out[i] = q
	}
	return out
}

// pointVictims picks which ids the campaign deletes: a seeded shuffle of every
// id, cut to the count wanted. A shuffle rather than a per-id coin toss because
// the count has to come out exact, and the whole shape of the campaign is that
// the live set lands on the declared bound and not near it.
func pointVictims(corpus []vector.Vector, n int, seed uint64) []uint64 {
	ids := make([]uint64, 0, len(corpus))
	for _, v := range corpus {
		ids = append(ids, v.ID)
	}
	rng := rand.New(rand.NewPCG(seed, 0)) //nolint:gosec // deterministic RNG for test data
	rng.Shuffle(len(ids), func(i, j int) { ids[i], ids[j] = ids[j], ids[i] })
	return ids[:n]
}

// pointBruteForce returns the exact top-k over the LIVE set, as a set of ids.
// It walks the oracle rather than the collection's store, which the API does not
// expose, and that is the right object anyway: the oracle is what the property's
// "upserted and not deleted" means.
func pointBruteForce(q []float32, orc *oracle, k int) map[uint64]bool {
	type scored struct {
		id uint64
		d  float32
	}
	all := make([]scored, 0, orc.count())
	for id, data := range orc.vectors {
		all = append(all, scored{id, vector.CosineDistance(q, data)})
	}
	// Ties break by id so the top-k does not depend on map order. The gaussian
	// corpus makes an exact tie between two distinct vectors practically
	// impossible, which is why nothing here has needed it; it costs one comparison
	// and removes the dependency rather than relying on that.
	sort.Slice(all, func(i, j int) bool {
		if all[i].d != all[j].d {
			return all[i].d < all[j].d
		}
		return all[i].id < all[j].id
	})
	if k < len(all) {
		all = all[:k]
	}
	out := make(map[uint64]bool, len(all))
	for _, s := range all {
		out[s.id] = true
	}
	return out
}

// corpusDigest hashes a corpus so the generator above can be compared against the
// one in package hnsw byte for byte. Ids and float bits both go in, so a
// generator that produced the right values in the wrong order would not match.
func corpusDigest(vecs []vector.Vector) uint64 {
	tab := crc64.MakeTable(crc64.ECMA)
	var h uint64
	buf := make([]byte, 0, 8+4*pointDim)
	for _, v := range vecs {
		buf = binary.LittleEndian.AppendUint64(buf[:0], v.ID)
		for _, f := range v.Data {
			buf = binary.LittleEndian.AppendUint32(buf, math.Float32bits(f))
		}
		h = crc64.Update(h, tab, buf)
	}
	return h
}
