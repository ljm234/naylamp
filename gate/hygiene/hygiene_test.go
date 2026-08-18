// Regression rows for the defects this tool shipped with on 17 August 2026.
// Five of them were found by running the program and reading its output, and
// the rest by two adversarial readings of the code, so each row names the
// defect it guards and the real line from this workspace that exposed it.
//
// WHAT IS NOT COVERED, so nobody reads the file as a wall it is not. There is
// no row for the corpus excluding this program's own directory, none for the
// corpus excluding _test.go, and none for the order of the classification
// switch. Those three are guarded only by a person reading the diff.
//
// AND SEVERAL RULES OVERLAP, which limits what a single row can prove. On
// "2026/08/10" the year rule, the date rule and the path rule all fire, so
// removing any one of them alone leaves these rows green. The rows assert the
// OUTCOME, that the token is gone, and not that one named rule removed it.
//
// This package is outside go.work on purpose (see the header of hygiene.go), so
// CI does not run these. They run by naming the files:
//
//	go test gate/hygiene/hygiene.go gate/hygiene/hygiene_test.go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// repoRoot returns the repository these tests sit in, or skips. Two rows read
// the real gate/ scripts, and when the files are copied elsewhere, which is
// what a mutation run does, the relative path stops resolving. Skipping says
// that out loud instead of failing and looking like the code broke.
func repoRoot(t *testing.T) string {
	t.Helper()
	root := filepath.Join("..", "..")
	if _, err := os.Stat(filepath.Join(root, "gate", "common.sh")); err != nil {
		t.Skip("not running inside the repository, gate/common.sh is not reachable from here")
	}
	return root
}

func TestSignificantDigits_SeparatesAClockFromARecall(t *testing.T) {
	// The defect: tiers were counted by decimal places, which put the 0.01 wall
	// clock of a failing test in the same class as the 0.9990 recall of the
	// SIFT run. 24 artifacts of one bundle were declared backed on that 0.01.
	cases := []struct {
		tok  string
		want int
		why  string
	}{
		{"0.9990", 4, "recall of the SIFT run, the SIFT1M row of the recall table in NAYLAMP_PHASE_1.md"},
		{"0.01", 1, "wall clock of a failing test in NAYLAMP_MUTATION_GATE_2026-08-05_dcd50cb_EVIDENCE"},
		{"0.219", 3, "package time of the same failing test"},
		{"4988.87", 6, "the PASS line of sift_run.log"},
		{"310.61", 5, "the 1000 seed sweep of DEFER-044"},
		{"7239", 4, "worstCedeRound of the every-node-answers rotation-off row of the targeting grid in NAYLAMP_LIVENESS_ARC.md"},
		{"2537", 4, "packets captured with no framing magic, the T4 gate entry of NAYLAMP_ARC_4.7.md"},
		{"3.5", 2, "a ratio, collides everywhere"},
		{"0.2125074", 7, "distance in NAYLAMP_DEFER053_REPRO/evidencia/f4diag_raw.txt"},
	}
	for _, c := range cases {
		if got := significantDigits(c.tok); got != c.want {
			t.Errorf("significantDigits(%q) = %d, want %d (%s)", c.tok, got, c.want, c.why)
		}
	}
}

func TestTierOf_OnlyFourOrMoreIsDecisive(t *testing.T) {
	cases := []struct {
		tok  string
		want tier
	}{
		{"0.9990", tierDecisive},
		{"7239", tierDecisive},
		{"0.219", tierUsable},
		{"456", tierUsable},
		{"0.01", tierWeak},
		{"72", tierWeak},
	}
	for _, c := range cases {
		if got := tierOf(c.tok); got != c.want {
			t.Errorf("tierOf(%q) = %v, want %v", c.tok, got, c.want)
		}
	}
}

func TestIsHex_DigitsAloneAreANumber(t *testing.T) {
	// The defect: \b[0-9a-f]{7,}\b matches any run of seven or more DECIMAL
	// digits, because the digits are a subset of the hex alphabet. It ate the
	// 4226497 of "dist=0.4226497" in NAYLAMP_TLS_GATE_2026-08-10_095946b.txt.
	if isHex("4226497") {
		t.Error("isHex(4226497) = true; a run of digits with no letter is a number, not a hash")
	}
	if isHex("1000000") {
		t.Error("isHex(1000000) = true; same defect, and this one is a corpus size")
	}
	if !isHex("8f690f05c4306ecf762a14d163f098b533132921") {
		t.Error("isHex(commit sha) = false; a real sha must still be dropped")
	}
}

// extractOne runs the real extraction over a single line and returns the
// figures that survived every rule, which is what the search actually sees.
func extractOne(line string) map[string]tier {
	figs, _, _ := extract([]string{line})
	out := map[string]tier{}
	for _, f := range figs {
		out[f.text] = f.tier
	}
	return out
}

func TestExtract_KeepsTheFiguresTheRulesUsedToEat(t *testing.T) {
	cases := []struct {
		name string
		line string
		want string
		tier tier
	}{
		{
			// Defect: reDecimal ended in \b, and there is no word boundary
			// between the last digit and the s of a Go test duration. The whole
			// class of figure the rule exists for was invisible.
			name: "go test duration followed by s",
			line: "ok  \tnaylamp/engine/hnsw\t4988.87s",
			want: "4988.87",
			tier: tierDecisive,
		},
		{
			// Defect: unguarded hex rule, see TestIsHex above.
			name: "distance with seven decimals",
			line: "F4 devuelto primero: dist=0.4226497",
			want: "0.4226497",
			tier: tierDecisive,
		},
		{
			// Defect: reColonNum took any colon and swallowed the level
			// histogram of an HNSW graph in NAYLAMP_DEFER053_REPRO/evidencia/mech_raw.txt.
			name: "go map printed with colons",
			line: "ZZ reparto de niveles: map[0:4840 1:157 2:3]",
			want: "4840",
			tier: tierDecisive,
		},
		{
			// Defect: the single letter n was a carried label, and in
			// NAYLAMP_DEFER053_REPRO/evidencia/who_raw.txt the n is the tail
			// of "k=n" while 4999 is the measurement, cited twice in the
			// workspace.
			name: "measurement after a k equals n",
			line: "ZZW alcanzables desde una consulta k=n: 4999 de 5000",
			want: "4999",
			tier: tierDecisive,
		},
		{
			// Defect: the carried label rule looked at the whole line, so on a
			// seed sweep, where every line names a seed, it deleted every
			// figure. 3218 tokens of NAYLAMP_REACH_GRID_2026-07-27.txt
			// reached the search as zero.
			name: "measurement on a line that also names a seed",
			line: "placement leader placed off the first target seed 20: worstCedeRound=7239 budget=8000",
			want: "7239",
			tier: tierDecisive,
		},
	}
	for _, c := range cases {
		got := extractOne(c.line)
		tr, ok := got[c.want]
		if !ok {
			t.Errorf("%s: %q was eaten; the line was %q", c.name, c.want, c.line)
			continue
		}
		if tr != c.tier {
			t.Errorf("%s: %q came out %v, want %v", c.name, c.want, tr, c.tier)
		}
	}
}

func TestExtract_StillDropsWhatCarriesNoMeasurement(t *testing.T) {
	// The other half. Loosening the rules above must not reopen the failure
	// the tool was written to prevent: eleven artifacts were once declared
	// backed on the strength of the year 2026 alone.
	cases := []struct {
		name string
		line string
		gone string
	}{
		{"bare year", "run of 12 de agosto de 2026 sobre la copia", "2026"},
		{"slash date in a gate log", "gate: node 1: 2026/08/10 role=leader", "2026"},
		{"fractional seconds of a clock", "node 1: 20:21:11.694423 role=leader", "694423"},
		{"port after a colon", "gate: captured packets on port 9401 of host", "9401"},
		{"file and line reference", "servicehealth_dst_test.go:766: cell leader-answers", "766"},
		{"seed as a labelled input", "run with seed 424 over the budget", "424"},
	}
	for _, c := range cases {
		if _, present := extractOne(c.line)[c.gone]; present {
			t.Errorf("%s: %q survived and should not have; the line was %q", c.name, c.gone, c.line)
		}
	}
}

func TestExtract_TotalCountsBeforeTheRulesRun(t *testing.T) {
	// Defect: total was incremented inside the loops over the already blanked
	// line, so the denominator of the report's own transparency claim was
	// understated by 25 to 45 per cent. It has to count the raw line.
	line := "gate: node 1: 2026/08/10 20:21:11.694423 role=leader term=2 port=9401"
	_, total, dropped := extract([]string{line})
	if total < 8 {
		t.Errorf("total = %d, want at least 8: it must count the raw line, not the blanked one", total)
	}
	if len(dropped) == 0 {
		t.Error("no rule reported a drop on a line that is all dates, clocks and labels")
	}
}

func TestIsRunbook_MatchesByNameAndNotByPosition(t *testing.T) {
	// Defect: the first version took any .txt at the root of a bundle, which
	// promoted nineteen raw outputs into the corpus where they could vouch for
	// each other. Of the twenty files that shape matched, one was a runbook.
	ws := filepath.Join("/tmp", "ws")
	cases := []struct {
		path string
		want bool
		why  string
	}{
		{filepath.Join(ws, "NAYLAMP_DEFER053_REPRO", "COMO_REPRODUCIR.txt"), true, "the only real runbook in this workspace"},
		{filepath.Join(ws, "NAYLAMP_OMNIBUS_GATE_2026-07-29_c1b4350_EVIDENCE", "node1.txt"), false, "raw output at a bundle root"},
		{filepath.Join(ws, "NAYLAMP_OMNIBUS_GATE_2026-07-29_c1b4350_EVIDENCE", "omnibus-manifest.txt"), false, "raw output at a bundle root"},
		{filepath.Join(ws, "sift_run.log"), false, "loose in the workspace root, belongs to no bundle"},
	}
	for _, c := range cases {
		if got := isRunbook(ws, c.path); got != c.want {
			t.Errorf("isRunbook(%s) = %v, want %v (%s)", c.path, got, c.want, c.why)
		}
	}
}

func TestSignificantDigits_RoundIntegersAreParameters(t *testing.T) {
	// The defect: counting trailing zeros everywhere made 5000, 50000 and
	// 1000000 decisive, and four raw files were kept by "F2POS n=5000
	// churn=50000", which is their own command line read back to them. The
	// threshold is two trailing zeros, because one happens to a measured count.
	cases := []struct {
		tok  string
		want int
		why  string
	}{
		{"5000", 1, "corpus size chosen by the operator"},
		{"50000", 1, "churn count chosen by the operator"},
		{"1000000", 1, "SIFT corpus size"},
		{"4840", 4, "nodes on layer 0, measured, and it merely ends in a zero"},
		{"0.9990", 4, "trailing zeros in a decimal ARE significant"},
		{"1200", 2, "efSearch, a parameter"},
	}
	for _, c := range cases {
		if got := significantDigits(c.tok); got != c.want {
			t.Errorf("significantDigits(%q) = %d, want %d (%s)", c.tok, got, c.want, c.why)
		}
	}
}

func TestBlank_RunsTheSameRulesOnACorpusLine(t *testing.T) {
	// The defect: the rules ran only on the artifact, never on the corpus, so
	// the 1002 of an object id matched the 1002 of "raft.go:1002-1003", a line
	// number, and the 9490 of a probe matched "CLIENT_PORT=9490". Clause 5
	// applies its own step to both sides or it does not apply it at all.
	//
	// rePorts is package state that only main fills, which this row found the
	// hard way by going red: without the assignment below the port cases pass
	// through untouched. Filling it from the real repository also checks the
	// wiring, so a broken declaredPorts shows up here and not in a report.
	saved := rePorts
	rePorts = declaredPorts(repoRoot(t))
	defer func() { rePorts = saved }()
	if rePorts == nil {
		t.Fatal("declaredPorts returned nil against the real repo; the port rule is dead")
	}

	cases := []struct {
		name string
		line string
		gone string
	}{
		{"line number in a document", "`confirmRead` (`raft.go:1002-1003`) cuenta con `len`", "1002"},
		{"port declared in a shell script", "CLIENT_PORT=9490", "9490"},
		{"port in a bracketed address", "corta el egreso hacia el cliente en PRIV[1]:9490 y deja", "9490"},
	}
	for _, c := range cases {
		if strings.Contains(blank(c.line, nil), c.gone) {
			t.Errorf("%s: %q survived blanking of a corpus line: %q", c.name, c.gone, c.line)
		}
	}
}

// shapeFixture builds the smallest inputs keptByShape needs, so the class the
// clause gained on 17 August 2026 has rows of its own. Before these, seven
// destructive mutations of that function left the whole suite green.
func shapeFixture(t *testing.T) (ws string, corpus map[string][]string, tree []string) {
	t.Helper()
	ws = filepath.Join("/tmp", "ws")
	corpus = map[string][]string{
		filepath.Join(ws, "NAYLAMP_ARC_4.7.md"):                     {"la evidencia esta en gate-run.txt de aquella corrida"},
		filepath.Join(ws, "BUNDLE_EVIDENCE", "COMO_REPRODUCIR.txt"): {"el crudo es inside.txt, generado por el paso 3"},
	}
	tree = []string{"func TestAlreadyInTheTree(t *testing.T) {"}
	return ws, corpus, tree
}

func TestKeptByShape_Form2IsAbsoluteAndOnlyForSourceMissingFromTheTree(t *testing.T) {
	ws, corpus, tree := shapeFixture(t)
	absent := []string{"func TestProof_ForgedAppRespCommitsWithoutQuorum(t *testing.T) {"}
	reason, absolute := keptByShape(ws, absent, filepath.Join(ws, "proofs.txt"), corpus, tree)
	if reason == "" || !absolute {
		t.Fatalf("source absent from the tree was not kept absolutely: reason=%q absolute=%v", reason, absolute)
	}
	if !strings.Contains(reason, "FORM 2") {
		t.Errorf("reason does not name the form that kept it: %q", reason)
	}

	// And the other half, which is what stops the rule from keeping everything:
	// a test that DOES exist in the tree must not trigger form 2.
	present := []string{"func TestAlreadyInTheTree(t *testing.T) {"}
	if reason, absolute := keptByShape(ws, present, filepath.Join(ws, "present.txt"), corpus, tree); absolute {
		t.Errorf("a test that exists in the tree triggered form 2: %q", reason)
	}
}

func TestKeptByShape_Form1NeedsBothAVerdictAndAnOutsideCitation(t *testing.T) {
	ws, corpus, tree := shapeFixture(t)
	cited := filepath.Join(ws, "gate-run.txt")

	withVerdict := []string{"gate: PASS T4.1 forged peer rejected", "exit=1"}
	reason, absolute := keptByShape(ws, withVerdict, cited, corpus, tree)
	if reason == "" {
		t.Fatal("a cited artifact carrying verdicts was not kept by form 1")
	}
	if absolute {
		t.Error("form 1 must not be absolute; only form 2 is")
	}

	// A name cited over a file with no verdict in it proves nothing. The clause
	// requires both halves and so does this.
	noVerdict := []string{"algunas notas sueltas sin veredicto ninguno"}
	if reason, _ := keptByShape(ws, noVerdict, cited, corpus, tree); reason != "" {
		t.Errorf("a cited file with no verdict was kept anyway: %q", reason)
	}

	// And a verdict with nobody naming it is not kept either.
	uncited := filepath.Join(ws, "nobody-names-this.txt")
	if reason, _ := keptByShape(ws, withVerdict, uncited, corpus, tree); reason != "" {
		t.Errorf("an uncited verdict file was kept anyway: %q", reason)
	}
}

func TestKeptByShape_ABundleCannotVouchForItsOwnContents(t *testing.T) {
	// The defect: the check compared DIRECTORIES, and
	// NAYLAMP_OMNIBUS_GATE_2026-08-10_095946b_NOTAS.md lives in the workspace
	// root, outside this repository. Its bundle
	// came out empty and it vouched for the very files it was written to list.
	ws, corpus, tree := shapeFixture(t)
	inside := filepath.Join(ws, "BUNDLE_EVIDENCE", "inside.txt")
	verdict := []string{"gate: PASS everything", "exit=0"}
	if reason, _ := keptByShape(ws, verdict, inside, corpus, tree); reason != "" {
		t.Errorf("a bundle runbook kept a file of its own bundle: %q", reason)
	}

	// The same file cited from a document OUTSIDE the bundle is kept.
	corpus[filepath.Join(ws, "NAYLAMP_PHASE_4.md")] = []string{"evidencia en inside.txt, de la corrida sellada"}
	if reason, _ := keptByShape(ws, verdict, inside, corpus, tree); reason == "" {
		t.Error("a citation from outside the bundle did not keep the file")
	}
}

func TestDeclaredPorts_ReadsThePortsTheRepoDeclares(t *testing.T) {
	// The lexical rules cannot tell a bare 9401 in prose from a measurement,
	// and clause 5 names that number as the example of what must never keep a
	// file. What separates them is that the repository declares its ports, so
	// the tool reads the declaration. This row guards that it still parses.
	re := declaredPorts(repoRoot(t))
	if re == nil {
		t.Fatal("declaredPorts found no port declarations under gate/; the shell files moved or the pattern broke")
	}
	for _, p := range []string{"9401", "9490"} {
		if !re.MatchString(p) {
			t.Errorf("declared port %s is not matched; gate/common.sh declares it", p)
		}
	}
	if re.MatchString("4988") {
		t.Error("a measurement matched the declared port pattern")
	}
}

func TestCollectCandidates_SkipsThisProgramsOwnReports(t *testing.T) {
	// The defect this guards is not hypothetical, it shipped. The archive
	// command in the header redirects stdout, and a shell creates that file
	// before the program starts, so the first archived run scanned its own
	// half written output at 1327 bytes and came out BACKED by a 0.9990 it had
	// just copied from another file's entry. An instrument cannot be its own
	// evidence.
	ws := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(ws, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	report := write("NAYLAMP_HYGIENE_2026-08-17_3a23d76.txt", "0.9990 copied out of another entry\n")
	other := write("NAYLAMP_SOMEGATE_2026-08-17.txt", "measured 4988.87s over the run\n")

	got, err := collectCandidates(ws)
	if err != nil {
		t.Fatal(err)
	}
	var sawReport, sawOther bool
	for _, p := range got {
		if p == report {
			sawReport = true
		}
		if p == other {
			sawOther = true
		}
	}
	if sawReport {
		t.Error("an archived hygiene report was collected as a candidate; the tool would judge its own output")
	}
	// The other half, so the row cannot pass by collecting nothing at all.
	if !sawOther {
		t.Error("an ordinary artifact was skipped; the exclusion is too wide")
	}
}

func TestBundleOf_SeparatesLooseFromBundled(t *testing.T) {
	ws := filepath.Join("/tmp", "ws")
	if got := bundleOf(ws, filepath.Join(ws, "sift_run.log")); got != "" {
		t.Errorf("bundleOf(loose file) = %q, want empty", got)
	}
	want := "NAYLAMP_DEFER053_REPRO"
	if got := bundleOf(ws, filepath.Join(ws, want, "evidencia", "min2_raw.txt")); got != want {
		t.Errorf("bundleOf(bundled file) = %q, want %q", got, want)
	}
}
