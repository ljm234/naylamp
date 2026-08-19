package dst

import (
	"strings"
	"testing"

	"naylamp/engine/naylamp"
	"naylamp/engine/vector"
)

// buildCollection returns a real collection driven through the public API, with
// ids 1..n upserted. The tests below diverge the ORACLE from it rather than
// mutating the engine, so everything here runs on an untouched engine and on
// every push.
func buildCollection(t *testing.T, n uint64) *naylamp.Collection {
	t.Helper()
	eng := naylamp.New()
	col, err := eng.CreateCollection("sim", 4, vector.CosineDistance, 5)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}
	for id := uint64(1); id <= n; id++ {
		if err := col.Upsert(id, vectorFor(id)); err != nil {
			t.Fatalf("Upsert(%d): %v", id, err)
		}
	}
	return col
}

// vectorFor is a deterministic vector per id, distinct enough that each id is
// its own nearest neighbor.
func vectorFor(id uint64) []float32 {
	return []float32{float32(id), 1, float32(id % 3), 0.5}
}

// TestCheckInvariants_CompensatedPairSurvivesTheCountAndDiesOnTheSet is the
// defender of the whole point of the second invariant. The oracle expects ten
// ids and the index holds ten ids, so the cardinals agree and the count check
// passes; but one id on each side is different, which is the compensated pair a
// count can never see. It also pins the ORDER: the failure has to be reported as
// a set mismatch, not as unreachability, even though id 99 is unreachable too.
func TestCheckInvariants_CompensatedPairSurvivesTheCountAndDiesOnTheSet(t *testing.T) {
	col := buildCollection(t, 10)

	orc := newOracle()
	for id := uint64(1); id <= 9; id++ {
		orc.upsert(id, vectorFor(id))
	}
	orc.upsert(99, vectorFor(99))

	// The pair is compensated, so the first invariant has nothing to say.
	if col.Len() != orc.count() {
		t.Fatalf("test setup is not a compensated pair: engine %d, oracle %d", col.Len(), orc.count())
	}

	err := checkInvariants(col, orc)
	if err == nil {
		t.Fatal("checkInvariants passed a compensated pair")
	}
	msg := err.Error()

	if !strings.Contains(msg, "index set mismatch") {
		t.Errorf("message does not carry the set verdict: %q", msg)
	}
	if !strings.Contains(msg, "the index holds 1 ids the oracle does not expect ([10])") {
		t.Errorf("message does not name the ghost id 10: %q", msg)
	}
	if !strings.Contains(msg, "the oracle expects 1 ids the index does not hold ([99])") {
		t.Errorf("message does not name the missing id 99: %q", msg)
	}
	// The verdict this one must not be confused with: it is what would be
	// reported if the set check ran after reachability, and the gate splits its
	// verdicts by exactly these strings. There is no guard against the count
	// verdict here because there could not be one: the setup above fails the test
	// unless the two cardinals already agree, so invariant 1 cannot fire. What
	// pins invariant 1 is TestCheckInvariants_ShortOracleIsACountFailure below.
	if strings.Contains(msg, "expected as closest match") || strings.Contains(msg, "query returned nothing") {
		t.Errorf("a set failure was reported as unreachability: %q", msg)
	}
}

// TestCheckInvariants_GreenWhenTheOracleAgrees is the control. Without it the
// test above would pass just as well against a checker that always failed.
func TestCheckInvariants_GreenWhenTheOracleAgrees(t *testing.T) {
	col := buildCollection(t, 10)

	orc := newOracle()
	for id := uint64(1); id <= 10; id++ {
		orc.upsert(id, vectorFor(id))
	}

	if err := checkInvariants(col, orc); err != nil {
		t.Fatalf("checkInvariants on an agreeing oracle: %v", err)
	}
}

// TestCheckInvariants_ShortOracleIsACountFailure is the positive defender of
// invariant 1, and it was missing: with it gone, deleting the count check
// outright left every other test in this file green, so the rule that the count
// and the set each keep a red arm of their own was held up by an instrument that
// only exists on a mutation copy. Here the oracle is simply one id short, which
// breaks the cardinal and the set at once, and the assertion is that the count
// is what reports it. That also pins the 1-before-2 order for this shape.
func TestCheckInvariants_ShortOracleIsACountFailure(t *testing.T) {
	col := buildCollection(t, 10)

	orc := newOracle()
	for id := uint64(1); id <= 9; id++ {
		orc.upsert(id, vectorFor(id))
	}

	err := checkInvariants(col, orc)
	if err == nil {
		t.Fatal("checkInvariants passed with the oracle one id short")
	}
	if !strings.Contains(err.Error(), "count mismatch: engine has 10, oracle expects 9") {
		t.Fatalf("the count is not what reported it: %q", err.Error())
	}
}

// TestCheckInvariants_MissingIdIsAttributedToTheSetAndNotToReachability covers
// the direction DEFER-049 files as already covered, in NAYLAMP_DEFERRED_BACKLOG.md,
// which is not in this repository. It is: an id the oracle expects
// and the index does not hold cannot come back as its own nearest neighbor, so
// invariant 3 would catch it. What it would NOT do is say what broke, and that
// is what this pins. The counts are made to agree so the first invariant stays
// out of the way.
func TestCheckInvariants_MissingIdIsAttributedToTheSetAndNotToReachability(t *testing.T) {
	col := buildCollection(t, 5)

	orc := newOracle()
	for id := uint64(1); id <= 4; id++ {
		orc.upsert(id, vectorFor(id))
	}
	orc.upsert(77, vectorFor(77))

	err := checkInvariants(col, orc)
	if err == nil {
		t.Fatal("checkInvariants passed with an id the index does not hold")
	}
	if !strings.Contains(err.Error(), "the oracle expects 1 ids the index does not hold ([77])") {
		t.Errorf("the missing direction is not reported as such: %q", err.Error())
	}
	if strings.Contains(err.Error(), "expected as closest match") {
		t.Errorf("the missing id was reported as a graph failure: %q", err.Error())
	}
}

func TestCompareIDSets(t *testing.T) {
	cases := []struct {
		name   string
		index  []uint64
		oracle []uint64
		want   string // empty means no error
	}{
		{
			name:   "equal sets agree",
			index:  []uint64{1, 2, 3},
			oracle: []uint64{3, 1, 2},
		},
		{
			name:   "both empty agree",
			index:  nil,
			oracle: nil,
		},
		{
			name:   "a ghost in the index",
			index:  []uint64{1, 2, 3},
			oracle: []uint64{1, 2},
			want:   "index set mismatch: the index holds 1 ids the oracle does not expect ([3]), the oracle expects 0 ids the index does not hold ([])",
		},
		{
			name:   "an id missing from the index",
			index:  []uint64{1, 2},
			oracle: []uint64{1, 2, 3},
			want:   "index set mismatch: the index holds 0 ids the oracle does not expect ([]), the oracle expects 1 ids the index does not hold ([3])",
		},
		{
			name:   "both directions at once, which is what the count cannot see",
			index:  []uint64{1, 2, 4},
			oracle: []uint64{1, 2, 3},
			want:   "index set mismatch: the index holds 1 ids the oracle does not expect ([4]), the oracle expects 1 ids the index does not hold ([3])",
		},
		{
			name:   "an empty index against a full oracle",
			index:  nil,
			oracle: []uint64{2, 1},
			want:   "index set mismatch: the index holds 0 ids the oracle does not expect ([]), the oracle expects 2 ids the index does not hold ([1 2])",
		},
		{
			// A repeated id is one id. Neither caller can produce one today,
			// since both sides come from map keys, but the counts in the message
			// are meant to be set sizes and this is the input class that would
			// turn them into occurrence tallies.
			name:   "a repeated id counts once on either side",
			index:  []uint64{4, 4, 4, 7},
			oracle: []uint64{7, 9, 9},
			want:   "index set mismatch: the index holds 1 ids the oracle does not expect ([4]), the oracle expects 1 ids the index does not hold ([9])",
		},
		{
			// The cap boundary, from below and from above. Nothing else in this
			// file sits on it, so an off-by-one in the comparison would print
			// "plus 0 more" and no test would notice.
			name:   "exactly the cap prints every id and no tail",
			index:  []uint64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10},
			oracle: nil,
			want:   "index set mismatch: the index holds 10 ids the oracle does not expect ([1 2 3 4 5 6 7 8 9 10]), the oracle expects 0 ids the index does not hold ([])",
		},
		{
			name:   "one past the cap prints the tail",
			index:  []uint64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
			oracle: nil,
			want:   "index set mismatch: the index holds 11 ids the oracle does not expect ([1 2 3 4 5 6 7 8 9 10] plus 1 more), the oracle expects 0 ids the index does not hold ([])",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := compareIDSets(tc.index, tc.oracle)
			if tc.want == "" {
				if err != nil {
					t.Fatalf("compareIDSets = %v, want nil", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("compareIDSets = nil, want %q", tc.want)
			}
			if err.Error() != tc.want {
				t.Fatalf("compareIDSets =\n  %q\nwant\n  %q", err.Error(), tc.want)
			}
		})
	}
}

// TestCompareIDSets_MessageDoesNotDependOnArgumentOrder defends the sort in
// compareIDSets. The reason the sort is there is written on the function.
func TestCompareIDSets_MessageDoesNotDependOnArgumentOrder(t *testing.T) {
	// Both sides arrive scrambled, because both sorts have to be exercised: the
	// index side reaches the real checker already ascending from Export, so a
	// test that fed it sorted would leave that sort untested.
	first := compareIDSets([]uint64{11, 2, 9, 5}, []uint64{9, 2, 40, 31})
	second := compareIDSets([]uint64{5, 9, 11, 2}, []uint64{31, 40, 2, 9})

	if first == nil || second == nil {
		t.Fatalf("both orders must fail: first=%v second=%v", first, second)
	}
	if first.Error() != second.Error() {
		t.Fatalf("the message depends on argument order:\n  %q\n  %q", first.Error(), second.Error())
	}
	if !strings.Contains(first.Error(), "([5 11])") || !strings.Contains(first.Error(), "([31 40])") {
		t.Fatalf("ids are not reported ascending: %q", first.Error())
	}
}

// TestCompareIDSets_LongMismatchIsCappedButCounted checks that a mismatch of
// thousands stays readable and that the cap hides no information: the counts are
// exact and the message says how many ids it left out.
func TestCompareIDSets_LongMismatchIsCappedButCounted(t *testing.T) {
	var index []uint64
	for id := uint64(1); id <= 25; id++ {
		index = append(index, id)
	}

	err := compareIDSets(index, nil)
	if err == nil {
		t.Fatal("compareIDSets = nil, want a mismatch")
	}
	want := "index set mismatch: the index holds 25 ids the oracle does not expect ([1 2 3 4 5 6 7 8 9 10] plus 15 more), the oracle expects 0 ids the index does not hold ([])"
	if err.Error() != want {
		t.Fatalf("compareIDSets =\n  %q\nwant\n  %q", err.Error(), want)
	}
}
