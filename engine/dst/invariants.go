package dst

import (
	"fmt"
	"sort"

	"naylamp/engine/naylamp"
)

// idSample caps how many ids a set mismatch prints per direction. The two
// counts in the message are always exact, so the cap hides nothing: it only
// keeps a failure readable when the two sets differ by thousands of ids, which
// is reachable the moment this checker is pointed at a collection the size of
// the recall tests rather than at the simulation's hundred.
const idSample = 10

// checkInvariants verifies the engine agrees with the oracle. These are the
// properties that must ALWAYS hold, no matter what random sequence of
// operations ran. A violation means a real bug in the engine.
//
// THE ORDER MATTERS AND ONLY ONE PAIR OF IT IS ASSERTED. Run returns on the
// first violation, so whichever check fires is the one that names the defect,
// and the gate that consumes this sweep splits its verdicts by the message it
// reads, that gate being the one designed in
// NAYLAMP_PROPUESTA_GATE_PHASE1_2026-08-10.md, also outside this repository. Invariant 2 therefore runs BEFORE invariant 3: an id the index does not
// hold at all is a failure of set identity, and reporting it as unreachability
// would blame the graph for a node that is not there. That pair is pinned by a
// test. Its cost goes with it: for a defect that violates both, invariant 2
// fires first and invariant 3 does not run, so what invariant 3 would have said
// is unknown rather than green.
//
// The 1-before-2 pair is pinned too, by TestCheckInvariants_ShortOracleIsACountFailure,
// where an oracle one id short breaks the cardinal and the set at once and the
// count is what has to report it. What that test records is the CHOICE, not a
// reason for it: invariant 1 keeps its number so that "the first invariant"
// still means the store count where it is cited that way, which is clause (i)
// of the central property of Phase 1 in NAYLAMP_PHASE_1.md and the title of
// DEFER-049 in NAYLAMP_DEFERRED_BACKLOG.md, both outside this repository. For a
// defect that trips both there is no argument here for why the count is the
// better verdict, and the test records the choice so it cannot drift unnoticed.
func checkInvariants(col *naylamp.Collection, orc *oracle) error {
	if err := checkStoreCount(col, orc); err != nil {
		return err
	}
	if err := checkIndexSet(col, orc); err != nil {
		return err
	}
	return checkReachability(col, orc)
}

// THE THREE ARE SEPARATE FUNCTIONS SO A CALLER CAN RUN ALL THREE AND REPORT ALL
// THREE, which the sweep above deliberately does not do. Splitting them changes
// nothing for the sweep: checkInvariants composes them in the same order and
// still returns on the first failure, and the messages are the same strings, so
// the fifteen red-arm rows that quote them are untouched.
//
// What needed the split is the campaign in point_test.go. It runs ONE
// collection, so first-failure would publish one clause and leave the other two
// unrun, and the gate that consumes this splits its verdicts by clause. A test
// that has to say something about each of the three cannot use a checker that
// stops at the first.

// checkStoreCount is invariant 1: the engine holds exactly as many vectors as
// the oracle expects. This is the STORE's count, because Collection.Len reads
// the store, and it is bookkeeping about the harness rather than one of the
// three clauses of the central property of Phase 1.
func checkStoreCount(col *naylamp.Collection, orc *oracle) error {
	if col.Len() != orc.count() {
		return fmt.Errorf("count mismatch: engine has %d, oracle expects %d", col.Len(), orc.count())
	}
	return nil
}

// checkIndexSet is invariant 2: the INDEX holds exactly the ids the oracle
// expects, as a SET and in both directions. The count cannot see this: a
// compensated pair, one id lost plus one ghost, keeps the cardinal and breaks
// the set. And the count watches the store while this watches the index, which
// is the object clause (i) speaks about.
func checkIndexSet(col *naylamp.Collection, orc *oracle) error {
	return compareIDSets(col.IndexIDs(), orc.ids())
}

// checkReachability is invariant 3: every id the oracle expects must be
// findable. We query with each expected vector's own data and confirm its id
// comes back as the closest match (a vector is always nearest to itself).
//
// This one returns on the FIRST id that fails, so which one it names is
// whatever order ids() hands back. That order used to be the map's, which made
// the message vary between runs of the same seed while the run itself stayed
// reproducible; ids() sorts now, and the comment there carries the measurement.
// The fear that fixing it would move the literal ids quoted by archived gate
// rows was measured before acting and did not hold. Three quotes of these
// messages carry a literal id outside gate/out, all three in the fixture of
// gate/p1.sh and all three fed by this function: the P1.reach row, and the two
// P1.point.reach rows, which reach here through the point campaign. Only the
// first is output of a mutation this gate can run, and forty runs of the
// sinreparar mutant, twenty sorted and twenty not, all named id 67. The other
// two name no run: no mutation here turns P1.point.reach red, so nothing
// re-measures them. And the pattern all three are there to exercise reads no
// id, so the P1.pre control is green either way, which was checked.
func checkReachability(col *naylamp.Collection, orc *oracle) error {
	for _, id := range orc.ids() {
		data := orc.vectors[id]

		results, err := col.Query(data, 1)
		if err != nil {
			return fmt.Errorf("query for id %d failed: %w", id, err)
		}
		if len(results) == 0 {
			return fmt.Errorf("id %d expected to exist but query returned nothing", id)
		}
		if results[0].ID != id {
			return fmt.Errorf("id %d expected as closest match, got id %d", id, results[0].ID)
		}
	}
	return nil
}

// compareIDSets reports whether the index's live id set is exactly the oracle's,
// in both directions, and the message below names each side with its own count.
// It takes plain slices
// and no engine handle, so it is testable on its own, and it returns one error
// carrying both directions because both can be non-empty at once and that pair
// is precisely what a count cannot see.
//
// THE OUTPUT IS A FUNCTION OF THE TWO SETS AND NOT OF THE ORDER THE IDS ARRIVE
// IN WITHIN EITHER ARGUMENT, and two things make that true rather than nearly
// true. Both sides go through a map
// before anything is counted, so an id repeated in an argument counts once and
// the printed counts are set sizes, not occurrence tallies. And both difference
// lists are sorted before printing, because a map hands them back in a different
// order on every run and TestDST_Reproducible proves determinism by comparing the
// two runs' error STRINGS: an unsorted message would make that defender go red on
// the formatting of an error while the engine was behaving identically.
// Index.Export sorts for the same reason and says so.
func compareIDSets(index, oracle []uint64) error {
	expected := make(map[uint64]struct{}, len(oracle))
	for _, id := range oracle {
		expected[id] = struct{}{}
	}

	held := make(map[uint64]struct{}, len(index))
	for _, id := range index {
		held[id] = struct{}{}
	}

	var extra []uint64
	for id := range held {
		if _, ok := expected[id]; !ok {
			extra = append(extra, id)
		}
	}

	var missing []uint64
	for id := range expected {
		if _, ok := held[id]; !ok {
			missing = append(missing, id)
		}
	}

	if len(extra) == 0 && len(missing) == 0 {
		return nil
	}

	sortIDs(extra)
	sortIDs(missing)
	return fmt.Errorf("index set mismatch: the index holds %d ids the oracle does not expect (%s), the oracle expects %d ids the index does not hold (%s)",
		len(extra), formatIDs(extra), len(missing), formatIDs(missing))
}

// formatIDs renders a list of ids for a failure message, capped at idSample and
// saying how many it left out. An empty list prints as [], so the message reads
// the same whether a direction is clean or the whole mismatch is on one side.
func formatIDs(ids []uint64) string {
	if len(ids) <= idSample {
		return fmt.Sprintf("%v", ids)
	}
	return fmt.Sprintf("%v plus %d more", ids[:idSample], len(ids)-idSample)
}

// sortIDs sorts ascending in place, for the two lists compareIDSets prints.
func sortIDs(ids []uint64) {
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
}
