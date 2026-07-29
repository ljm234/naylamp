package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"naylamp/engine/cluster"
)

// This file holds the red arms of the three audit checks and the green controls
// that keep each red attributable. A check that cannot go red for its own reason
// is not evidence of anything, so every check here is shown failing for the
// reason it exists and passing for the cases that merely look like that reason.

// writeManifestFile lays down a manifest and returns its path, so a test can
// exercise the parser and the checker together rather than hand-building the
// oracle and assuming the two agree.
func writeManifestFile(t *testing.T, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "manifest.txt")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	return path
}

// verifyWith opens a manifest file, lays down the committed log, and runs the
// audit, returning the verdict and the joined evidence.
func verifyWith(t *testing.T, manifestLines []string, cmds [][]byte) (bool, string) {
	t.Helper()
	man, err := readManifest(writeManifestFile(t, manifestLines...))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	cfg, cerr := configFromFlags(1, "")
	if cerr != nil {
		t.Fatalf("config: %v", cerr)
	}
	dir := t.TempDir()
	writeCommittedLog(t, dir, cmds)
	ok, reasons := verifyLog(dir, 1, cfg, 3, man)
	return ok, strings.Join(reasons, "\n")
}

// --- P1 red arm: an acknowledged write that is missing ---

func TestVerifyLog_RedWhenAConfirmedWriteIsMissing(t *testing.T) {
	ok, out := verifyWith(t,
		[]string{"put 1 1,0,0 confirmed", "put 2 0,1,0 confirmed"},
		[][]byte{upsertPayload(1, []float32{1, 0, 0})}, // id 2 never made it
	)
	if ok {
		t.Fatalf("a missing acknowledged write must be red, got faithful:\n%s", out)
	}
	if !strings.Contains(out, "acknowledged id=2") {
		t.Fatalf("the red must name the lost acknowledged write, got:\n%s", out)
	}
}

// --- P1 red arm: a phantom id nobody ever emitted ---

func TestVerifyLog_RedWhenAnIDWasNeverEmitted(t *testing.T) {
	ok, out := verifyWith(t,
		[]string{"put 1 1,0,0 confirmed"},
		[][]byte{
			upsertPayload(1, []float32{1, 0, 0}),
			upsertPayload(99, []float32{9, 9, 9}), // never emitted by the workload
		},
	)
	if ok {
		t.Fatalf("a phantom must be red, got faithful:\n%s", out)
	}
	if !strings.Contains(out, "phantom id=99") {
		t.Fatalf("the red must name the phantom, got:\n%s", out)
	}
}

// --- P1 green control: an uncertain operation that did NOT land ---

func TestVerifyLog_GreenWhenAnUncertainWriteIsAbsent(t *testing.T) {
	ok, out := verifyWith(t,
		[]string{"put 1 1,0,0 confirmed", "put 2 0,1,0 uncertain"},
		[][]byte{upsertPayload(1, []float32{1, 0, 0})}, // id 2 absent, legitimately
	)
	if !ok {
		t.Fatalf("an unanswered operation that did not land is not a defect, got red:\n%s", out)
	}
	if !strings.Contains(out, "uncertain_ids_absent=1") {
		t.Fatalf("the absent unanswered operation must be counted, got:\n%s", out)
	}
}

// --- P1 green control: an uncertain operation that DID land ---
//
// This is the case the two-state checker got wrong, and the one the hardware
// gate actually recorded: the client timed out under a partition while the
// write committed anyway.

func TestVerifyLog_GreenWhenAnUncertainWriteIsPresent(t *testing.T) {
	ok, out := verifyWith(t,
		[]string{"put 1 1,0,0 confirmed", "put 2 0,1,0 uncertain"},
		[][]byte{
			upsertPayload(1, []float32{1, 0, 0}),
			upsertPayload(2, []float32{0, 1, 0}), // landed despite the timeout
		},
	)
	if !ok {
		t.Fatalf("an unanswered operation that did land is not a phantom, got red:\n%s", out)
	}
	if !strings.Contains(out, "uncertain_ids_present=1") {
		t.Fatalf("the present unanswered operation must be counted, got:\n%s", out)
	}
	if strings.Contains(out, "phantom id=") {
		t.Fatalf("an unanswered operation must never be reported as a phantom, got:\n%s", out)
	}
}

// TestVerifyLog_UncertainOverwriteLeavesTheValueUnjudged fixes the subtle case:
// an answered put followed by an unanswered overwrite of the SAME id. The id
// must still be required present, because the answered entry is committed, but
// its final value cannot be predicted and must not be judged.
func TestVerifyLog_UncertainOverwriteLeavesTheValueUnjudged(t *testing.T) {
	lines := []string{"put 1 1,0,0 confirmed", "put 1 0,0,9 uncertain"}
	// Whichever value survived, the verdict is the same.
	for _, landed := range [][]float32{{1, 0, 0}, {0, 0, 9}} {
		ok, out := verifyWith(t, lines, [][]byte{upsertPayload(1, landed)})
		if !ok {
			t.Fatalf("an id whose last write was unanswered must not be judged on its value (landed %v), got red:\n%s", landed, out)
		}
	}
	// But losing it entirely is still a lost acknowledged write.
	ok, out := verifyWith(t, lines, nil)
	if ok {
		t.Fatalf("the answered write on that id was still lost, which must be red:\n%s", out)
	}
	if !strings.Contains(out, "acknowledged id=1") {
		t.Fatalf("the red must name the lost acknowledged write, got:\n%s", out)
	}
}

// TestVerifyLog_LostConfirmedWriteHidesBehindALandedUncertainOne pins the
// declared blind spot of an id-keyed oracle, so it stays a known shape instead
// of being discovered during a graded run. An answered write is lost while an
// unanswered write on the SAME id lands: the id is present, which satisfies the
// requirement, and the value is unpredictable, which suppresses the comparison,
// so the copy reads faithful even though an acknowledged write really was lost.
// The test asserts the current behaviour on purpose. If a later change makes the
// checker catch this, this test is the one that should be rewritten, and its
// failure is the signal that the blind spot closed.
func TestVerifyLog_LostConfirmedWriteHidesBehindALandedUncertainOne(t *testing.T) {
	ok, out := verifyWith(t,
		[]string{"put 5 1,0,0 confirmed", "put 5 0,0,9 uncertain"},
		[][]byte{upsertPayload(5, []float32{0, 0, 9})}, // only the unanswered write landed
	)
	if !ok {
		t.Fatalf("the blind spot is documented as reading faithful; if this now reds, the limit closed and the doc comment plus this test must be updated:\n%s", out)
	}
	// The workload the gate writes avoids the shape entirely, which is the
	// mitigation the doc comment names: no unanswered operation aimed at an id
	// that already carries an answered one.
	okClean, outClean := verifyWith(t,
		[]string{"put 5 1,0,0 confirmed", "put 6 0,0,9 uncertain"},
		[][]byte{upsertPayload(6, []float32{0, 0, 9})}, // the answered write on 5 is lost
	)
	if okClean {
		t.Fatalf("with the ids kept apart, the lost acknowledged write must be caught:\n%s", outClean)
	}
	if !strings.Contains(outClean, "acknowledged id=5") {
		t.Fatalf("the red must name the lost acknowledged write, got:\n%s", outClean)
	}
}

// TestVerifyLog_ManifestWithoutStandingsReadsAsAllConfirmed is the backward
// compatibility pin: the manifest faithlog.sh writes carries no markers, and it
// must keep meaning exactly what it meant, every operation answered.
func TestVerifyLog_ManifestWithoutStandingsReadsAsAllConfirmed(t *testing.T) {
	man, err := readManifest(writeManifestFile(t, "put 1 1,0,0", "del 2", "put 3 0,0,1"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	for _, id := range []uint64{1, 2, 3} {
		if !man.confirmedIDs()[id] {
			t.Fatalf("id %d must be confirmed in an unmarked manifest", id)
		}
		if man.isAmbiguous(id) {
			t.Fatalf("id %d must not be ambiguous in an unmarked manifest", id)
		}
	}
	// And an unmarked manifest still reds on a missing write, which is the
	// behaviour faithlog.sh depends on.
	ok, out := verifyWith(t, []string{"put 1 1,0,0", "put 2 0,1,0"}, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	if ok {
		t.Fatalf("an unmarked manifest must still red on a missing write:\n%s", out)
	}
}

// TestVerifyLog_TheExistingGateWorkloadIsUnaffected runs the literal manifest
// the log-fidelity gate writes today, line for line as its manifest_put and
// manifest_del emit it, through the parser and the checker. The gate was not
// changed by this work, so its green must stay green and its reds must stay red
// for the same reasons; anything else would mean a sealed instrument quietly
// changed meaning under it.
func TestVerifyLog_TheExistingGateWorkloadIsUnaffected(t *testing.T) {
	gateManifest := []string{"put 1 1,0,0", "put 2 0,1,0", "put 3 0,0,1", "del 2", "put 5 1,1,1"}
	gateLog := [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
		upsertPayload(3, []float32{0, 0, 1}),
		deletePayload(2),
		upsertPayload(5, []float32{1, 1, 1}),
		upsertPayload(5, []float32{1, 1, 1}), // the idempotent duplicate the gate expects absorbed
	}

	if ok, out := verifyWith(t, gateManifest, gateLog); !ok {
		t.Fatalf("the gate's own workload must still verify faithful:\n%s", out)
	}

	// The three defects the gate injects must still be caught, by name.
	for _, tc := range []struct {
		name string
		log  [][]byte
		want string
	}{
		{"phantom", append(append([][]byte{}, gateLog...), upsertPayload(42, []float32{4, 2, 0})), "phantom id=42"},
		{"missing", gateLog[1:], "acknowledged id=1"},
		{"wrong-value", append(append([][]byte{}, gateLog[:4]...), upsertPayload(5, []float32{9, 9, 9})), "id=5 replays to"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ok, out := verifyWith(t, gateManifest, tc.log)
			if ok {
				t.Fatalf("the gate's %s defect must still be caught:\n%s", tc.name, out)
			}
			if !strings.Contains(out, tc.want) {
				t.Fatalf("the %s red must still name %q, got:\n%s", tc.name, tc.want, out)
			}
		})
	}
}

func TestReadManifest_RejectsAnUnknownTrailingWord(t *testing.T) {
	if _, err := readManifest(writeManifestFile(t, "put 1 1,0,0 maybe")); err == nil {
		t.Fatal("an unrecognised trailing word must be rejected, not read as a standing")
	}
}

// TestReadManifest_RejectsMalformedLinesWithoutPanicking covers the shapes a
// hand-edited or half-written manifest can take. The bare-standing line is the
// one that matters: stripping the marker is what empties the field list, so the
// emptiness check has to sit after the strip or the parser indexes into nothing.
// A parser that crashes on a malformed line is a poor instrument for a register
// whose whole value is clean evidence.
func TestReadManifest_RejectsMalformedLinesWithoutPanicking(t *testing.T) {
	for _, line := range []string{
		"confirmed",       // a standing with no operation
		"uncertain",       // the same, the other marker
		"put 5 confirmed", // a put missing its vector
		"del confirmed",   // a del missing its id
		"put 1 x,y,z",     // an unparseable vector
		"del 1 2 3",       // too many fields
		"frobnicate 1",    // an operation that does not exist
	} {
		t.Run(line, func(t *testing.T) {
			if _, err := readManifest(writeManifestFile(t, line)); err == nil {
				t.Fatalf("a malformed manifest line must be an error, not accepted: %q", line)
			}
		})
	}
}

// --- P2 red arm: two digests that differ ---

func TestStateHash_RedWhenTwoReplicasHoldDifferentData(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	writeCommittedLog(t, dirB, [][]byte{upsertPayload(1, []float32{0, 0, 9})}) // same id, divergent value

	lineA, okA := stateHashOf(dirA, 1, cfg, 3)
	lineB, okB := stateHashOf(dirB, 2, cfg, 3)
	if !okA || !okB {
		t.Fatalf("both copies must read:\n%s\n%s", lineA, lineB)
	}
	if digestOf(t, lineA) == digestOf(t, lineB) {
		t.Fatalf("replicas holding different data must produce different digests:\n%s\n%s", lineA, lineB)
	}
}

// TestStateHash_GreenWhenTwoReplicasHoldTheSameData is the control that keeps
// the red above attributable: identical data must agree, or a difference would
// mean nothing.
func TestStateHash_GreenWhenTwoReplicasHoldTheSameData(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	cmds := [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
		deletePayload(2),
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, cmds)
	writeCommittedLog(t, dirB, cmds)

	lineA, okA := stateHashOf(dirA, 1, cfg, 3)
	lineB, okB := stateHashOf(dirB, 2, cfg, 3)
	if !okA || !okB {
		t.Fatalf("both copies must read:\n%s\n%s", lineA, lineB)
	}
	if digestOf(t, lineA) != digestOf(t, lineB) {
		t.Fatalf("replicas holding the same data must agree:\n%s\n%s", lineA, lineB)
	}
	if !strings.Contains(lineA, "do NOT prove state machine safety") {
		t.Fatalf("the line must carry the scope of the claim, got:\n%s", lineA)
	}
}

// TestStateHash_ConvergesAfterAnOverwrittenDivergence is the honesty pin for the
// scope this command declares. Two replicas that DID diverge at one index
// converge to the same digest once a later committed put overwrites that id, so
// the digest reports equal. The check is a monitor for a surviving divergence,
// not a proof that none happened, and this test exists so that limit is
// recorded in the suite rather than only in a comment.
func TestStateHash_ConvergesAfterAnOverwrittenDivergence(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{
		upsertPayload(7, []float32{1, 0, 0}), // A applied one value here
		upsertPayload(7, []float32{5, 5, 5}),
	})
	writeCommittedLog(t, dirB, [][]byte{
		upsertPayload(7, []float32{0, 1, 0}), // B applied a DIFFERENT one
		upsertPayload(7, []float32{5, 5, 5}),
	})

	lineA, _ := stateHashOf(dirA, 1, cfg, 3)
	lineB, _ := stateHashOf(dirB, 2, cfg, 3)
	if digestOf(t, lineA) != digestOf(t, lineB) {
		t.Fatalf("the overwrite should have hidden the divergence, which is the limit under test:\n%s\n%s", lineA, lineB)
	}
}

// digestOf pulls the digest field out of a state-hash evidence line.
func digestOf(t *testing.T, line string) string {
	t.Helper()
	for _, f := range strings.Fields(line) {
		if strings.HasPrefix(f, "digest=") {
			return strings.TrimPrefix(f, "digest=")
		}
	}
	t.Fatalf("no digest in line: %s", line)
	return ""
}

// --- P3 red arm: a disagreement inside the shared prefix ---

func TestCompareLogs_RedWhenReplicasDisagreeInsideTheSharedPrefix(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
	})
	writeCommittedLog(t, dirB, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(9, []float32{9, 9, 9}), // different command at the same index
	})

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	out := strings.Join(lines, "\n")
	if ok {
		t.Fatalf("a disagreement inside the shared prefix must be red:\n%s", out)
	}
	if !strings.Contains(out, "disagree at command 2") {
		t.Fatalf("the red must name the index, got:\n%s", out)
	}
}

// TestCompareLogs_RedWhenTheSameIDCarriesADifferentValue is the red arm that
// holds the VALUE comparison, and it is separate from the one above on purpose.
// The red arm that differs by id passes even if the vector is never compared at
// all, so on its own it leaves the divergence this check exists to catch
// unpinned: two replicas applying different values to the SAME id at the SAME
// position is exactly the shape of a state machine divergence.
func TestCompareLogs_RedWhenTheSameIDCarriesADifferentValue(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
	})
	writeCommittedLog(t, dirB, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{9, 9, 9}), // same id and op, divergent value
	})

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	out := strings.Join(lines, "\n")
	if ok {
		t.Fatalf("the same id carrying a different value must be red:\n%s", out)
	}
	if !strings.Contains(out, "disagree at command 2") {
		t.Fatalf("the red must name the position, got:\n%s", out)
	}
}

// TestCompareLogs_RedWhenAPutAndADeleteCollide holds the opcode comparison, the
// third field the equality test reads, so no part of it is left unpinned.
func TestCompareLogs_RedWhenAPutAndADeleteCollide(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{upsertPayload(4, []float32{1, 0, 0})})
	writeCommittedLog(t, dirB, [][]byte{deletePayload(4)}) // same id, opposite operation

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	if ok {
		t.Fatalf("a put on one replica and a delete on another at the same position must be red:\n%s", strings.Join(lines, "\n"))
	}
}

// TestCompareLogs_RefusesSnapshot and TestStateHash_RefusesSnapshot hold the
// refusal each new subcommand inherits from verify-log. A compacted copy has had
// its committed prefix folded away, so position k on it is not position k on an
// uncompacted peer and neither a digest nor a comparison means what it says.
// Without these, both refusal paths are dead to the suite.
func TestCompareLogs_RefusesSnapshot(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	writeCommittedLog(t, dirB, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	if err := os.WriteFile(filepath.Join(dirB, snapshotFileName), []byte("x"), 0o600); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	out := strings.Join(lines, "\n")
	if ok {
		t.Fatalf("a compacted copy must be refused, not compared:\n%s", out)
	}
	if !strings.Contains(out, "snapshot-present") {
		t.Fatalf("the refusal must name the reason, got:\n%s", out)
	}
}

func TestStateHash_RefusesSnapshot(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dir := t.TempDir()
	writeCommittedLog(t, dir, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	if err := os.WriteFile(filepath.Join(dir, snapshotFileName), []byte("x"), 0o600); err != nil {
		t.Fatalf("write snapshot: %v", err)
	}

	line, ok := stateHashOf(dir, 1, cfg, 3)
	if ok {
		t.Fatalf("a compacted copy must be refused, not digested:\n%s", line)
	}
	if !strings.Contains(line, "snapshot-present") {
		t.Fatalf("the refusal must name the reason, got:\n%s", line)
	}
}

// TestAuditToolsRefuseAPathThatDoesNotExist holds the guard that keeps a typo
// from being read as an empty replica. Opening a node CREATES its directory, so
// without this both tools would digest or compare a replica they invented, and
// two typos would agree with each other perfectly.
func TestAuditToolsRefuseAPathThatDoesNotExist(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	missingA := filepath.Join(t.TempDir(), "not-there")
	missingB := filepath.Join(t.TempDir(), "also-not-there")

	line, ok := stateHashOf(missingA, 1, cfg, 3)
	if ok {
		t.Fatalf("state-hash must refuse a path that does not exist, got:\n%s", line)
	}
	if !strings.Contains(line, "no-such-directory") {
		t.Fatalf("the refusal must name the reason, got:\n%s", line)
	}
	if _, serr := os.Stat(missingA); serr == nil {
		t.Fatal("state-hash must not create the directory it was pointed at")
	}

	okCmp, lines := compareLogs([]replicaDir{{1, missingA}, {2, missingB}}, cfg, 3)
	if okCmp {
		t.Fatalf("two paths that do not exist must not compare as a match:\n%s", strings.Join(lines, "\n"))
	}
}

// --- P3 green control: a lagging follower is NOT a disagreement ---

func TestCompareLogs_GreenWhenAFollowerIsBehind(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2, 3}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	full := [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
		upsertPayload(3, []float32{0, 0, 1}),
	}
	dirA, dirB, dirC := t.TempDir(), t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, full)
	writeCommittedLog(t, dirB, full)
	writeCommittedLog(t, dirC, full[:1]) // behind by two, perfectly correct

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}, {3, dirC}}, cfg, 3)
	out := strings.Join(lines, "\n")
	if !ok {
		t.Fatalf("a replica that is merely behind must not be a mismatch:\n%s", out)
	}
	if !strings.Contains(out, "shared_prefix=1") {
		t.Fatalf("the shared prefix must be reported as 1, got:\n%s", out)
	}
	if !strings.Contains(out, "command_counts=1:3,2:3,3:1") {
		t.Fatalf("every length must be reported so a short prefix is visible, got:\n%s", out)
	}
}

// TestCompareLogs_DisagreementPastTheSharedPrefixIsNotJudged fixes the boundary
// itself: the replicas differ at an index only one of them has, which the check
// must not read as disagreement, because no replica claims anything there.
func TestCompareLogs_DisagreementPastTheSharedPrefixIsNotJudged(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}),
		upsertPayload(2, []float32{0, 1, 0}),
	})
	writeCommittedLog(t, dirB, [][]byte{
		upsertPayload(1, []float32{1, 0, 0}), // agrees where it overlaps, then stops
	})

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	if !ok {
		t.Fatalf("content past the shared prefix must not be judged:\n%s", strings.Join(lines, "\n"))
	}
}

// TestCompareLogs_EmptySharedPrefixSaysSoRatherThanClaimingAgreement pins the
// vacuous case: with nothing in common the check has attested nothing, and the
// evidence line must say that instead of reading as a clean pass.
func TestCompareLogs_EmptySharedPrefixSaysSoRatherThanClaimingAgreement(t *testing.T) {
	cfg, err := configForReplicas([]cluster.NodeID{1, 2}, "")
	if err != nil {
		t.Fatalf("config: %v", err)
	}
	dirA, dirB := t.TempDir(), t.TempDir()
	writeCommittedLog(t, dirA, [][]byte{upsertPayload(1, []float32{1, 0, 0})})
	writeCommittedLog(t, dirB, nil)

	ok, lines := compareLogs([]replicaDir{{1, dirA}, {2, dirB}}, cfg, 3)
	out := strings.Join(lines, "\n")
	if !ok {
		t.Fatalf("an empty log is lag, not disagreement:\n%s", out)
	}
	if !strings.Contains(out, "attests nothing") {
		t.Fatalf("a vacuous comparison must say so, got:\n%s", out)
	}
}

func TestParseReplicaDirs_RejectsADuplicateID(t *testing.T) {
	if _, err := parseReplicaDirs([]string{"1=/tmp/a", "1=/tmp/b"}); err == nil {
		t.Fatal("the same replica id given twice must be rejected")
	}
}

// TestParseReplicaDirs_RejectsADuplicateDirectory holds the OTHER half of the
// guard, and it needs its own test because the id check fires first: a case that
// repeats the id never reaches the directory check, so the directory half could
// be deleted with the whole suite still green. Two DISTINCT ids pointed at one
// path is the shape that reaches it, and it is the more dangerous typo of the
// two. A copy compared against itself agrees at every position, and because the
// shared prefix is then nonzero the vacuous-comparison hedge never fires, so the
// run reports a clean match over a comparison that was never made.
func TestParseReplicaDirs_RejectsADuplicateDirectory(t *testing.T) {
	if _, err := parseReplicaDirs([]string{"1=/tmp/a", "2=/tmp/a"}); err == nil {
		t.Fatal("two ids pointed at the same directory must be rejected; a copy agrees with itself and proves nothing")
	}
	// The guard compares cleaned paths, not the raw flag text, so redundant
	// separators and dot elements do not slip a repeat past it. The cleaning is
	// lexical only, which is worth knowing rather than assuming: a case variant,
	// a relative spelling of an absolute path, and a symlinked parent all still
	// read as different directories. The gate passes three distinct plain names,
	// so none of those is reachable there today.
	if _, err := parseReplicaDirs([]string{"1=/tmp/a", "2=/tmp/./a"}); err == nil {
		t.Fatal("the same directory spelled with a dot element must still be rejected")
	}
	// And the case that must keep working: distinct ids on distinct paths.
	if _, err := parseReplicaDirs([]string{"1=/tmp/a", "2=/tmp/b", "3=/tmp/c"}); err != nil {
		t.Fatalf("three distinct replicas on distinct paths must be accepted: %v", err)
	}
}
