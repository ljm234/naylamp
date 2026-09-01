// Regression rows for the defects this tool shipped with on 17 August 2026.
// Five of them were found by running the program and reading its output, and
// the rest by two adversarial readings of the code, so each row names the
// defect it guards and the real line from this workspace that exposed it.
//
// WHAT IS NOT COVERED, so nobody reads the file as a wall it is not. There is
// no row for the corpus excluding this program's own directory and none for
// the corpus excluding _test.go. Those two are guarded only by a person
// reading the diff.
//
// That paragraph used to say THREE and named the order of the classification
// switch as the third. The old count is named here rather than swapped in
// silence, which is what the hard rule of DEFER-064 asks of a comment. That
// rule gives as its reason that a Go comment does not take a strike, and the
// header of hygiene.go breaks it in one place and is right to: a whole false
// SENTENCE reads better struck than paraphrased. A count does not. A struck
// THREE beside a live TWO is two numbers where the reader needs one.
// The switch order is covered now, by the last row of this
// file: its workspace holds a raw that is BOTH absolute by shape AND
// decisively backed, which is the only shape that can tell the two leading
// cases apart, and swapping them moves that raw out of the section the row
// reads. Measured and not argued, and the tense matters: BEFORE this row
// existed, swapping the two cases left the step green on all three of its
// commands. It does not any more, which is the point: swapped, this row goes
// red and every other row here still passes.
//
// WHICH END EACH ROW PINS, which clause 12 of the protocol at the end of
// NAYLAMP_DEFERRED_BACKLOG.md asks every red arm of this house to say out
// loud, on the grounds that an arm which does not say what it misses gets read
// as covering everything.
//
// Every row but the last asks a function what it returns, so it pins the
// PREDICATE and leaves the SITE loose. These are the ways of retiring the
// keptByShape call from report that leave all of them green: consuming treeSrc,
// keeping the call and throwing both answers away, writing it inside a branch
// that never runs, and moving it behind the switch it feeds. Deleting the line
// outright is the only form that does not compile, and it fails on treeSrc
// going unused rather than on anything this file checks.
//
// The last row runs the program and reads its report, so it pins the SITE and
// leaves the predicate loose: remove a guard from inside keptByShape and it
// stays green while the row above that owns that guard goes red. One row, not
// three, and the distinction is worth keeping because each of those rows owns
// a different half of the predicate. Neither kind replaces the other, and the
// split is not a claim: it is the table of
// naylamp-hygiene-cierre-20260831T222748Z.txt, in the runs directory of the
// workspace, which is the run anchored to this file as it stands. The table of
// the run named sitio-antes is the other half, what the fifteen rows saw
// before this one existed.
//
// AND SEVERAL RULES OVERLAP, which limits what a single row can prove. On
// "2026/08/10" the year rule, the date rule and the path rule all fire, so
// removing any one of them alone leaves these rows green. The rows assert the
// OUTCOME, that the token is gone, and not that one named rule removed it.
//
// This package is outside go.work on purpose (see the header of hygiene.go), so
// no package pattern reaches these. They run by being named:
//
//	go test gate/hygiene/hygiene.go gate/hygiene/hygiene_test.go
//
// That line used to read "so CI does not run these", and it was corrected on
// 31 August 2026 after standing false for long enough that the sibling header
// grew a section called OUTSIDE go.work, INSIDE CI to say the opposite.
// ci.yml has a step that names both files and runs exactly the command above.
// What is true is the first half: no pattern reaches them, so they run where
// somebody wrote the names down.
package main

import (
	"os"
	"os/exec"
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
//
// The three rows it serves pin the PREDICATE and say nothing about the SITE,
// because they call keptByShape themselves. What pins the site is the last row
// of this file, which does not call it at all.
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

// --- The wiring row. It is the only one here that runs the program.

// hygieneBinary compiles the command from the source these tests sit beside and
// returns the binary. The source path is relative to the test's own directory on
// purpose: a mutation copy of this package then measures the mutated source and
// not the tree's, which is the whole point of a copy.
//
// The toolchain is found with exec.LookPath and not with runtime.GOROOT, which
// is deprecated and whose own note says to use the system path instead. LookPath
// is enough even when go is absent from the PATH of the shell that invoked the
// tests, because the go command puts GOROOT/bin on the PATH of the binary it
// runs; measured both ways on 31 August 2026, once with go on the PATH and once
// with an emptied environment and go called by its full path.
//
// Not finding it is a Fatal and not a Skip, which is the opposite of what
// repoRoot does at the top of this file, and the difference is the reason and
// not the taste. The first version of this sentence said "forty lines up" and
// the distance was 429; it was a positional anchor written in the same pass
// that added a protocol clause against positional anchors, which is why the
// name is here and the number is gone. repoRoot skips because these two files legitimately travel outside the
// repository, and a mutation copy is exactly that trip. A missing toolchain is
// never a legitimate state for a test that the toolchain just built. Said
// plainly so nobody reads more into it: this row DOES still skip through
// repoRoot, so what a Fatal pins here is narrow, that a reachable toolchain is
// never silently absent.
func hygieneBinary(t *testing.T, root string) string {
	t.Helper()
	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Fatalf("no go toolchain reachable, and this row cannot build the program without one: %v", err)
	}
	bin := filepath.Join(t.TempDir(), "hygiene")
	src := filepath.Join(root, "gate", "hygiene", "hygiene.go")
	if out, err := exec.Command(goBin, "build", "-o", bin, src).CombinedOutput(); err != nil {
		t.Fatalf("go build %s: %v\n%s", src, err, out)
	}
	return bin
}

// shapeWorkspace writes the smallest workspace that puts one raw in each class
// the shape verdict decides, plus one that has to stay out of every one of them.
//
// The repository is a SIBLING of the workspace and not a child, and that is not
// tidiness: the program walks the workspace collecting candidates, so a
// repository underneath it would be judged as evidence and the fixture would
// stop describing what it says it describes.
func shapeWorkspace(t *testing.T) (ws, repo string) {
	t.Helper()
	base := t.TempDir()
	ws = filepath.Join(base, "ws")
	repo = filepath.Join(base, "repo")
	write := func(dir, name, body string) {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	// The citing document. It names two of the raws, and it carries the decisive
	// figure of one of them, which is what turns that one into a check of the
	// order of the classification switch and not only of the call.
	write(ws, "NAYLAMP_NOTA_FORMA.md", "# Nota de la forma\n\n"+
		"La corrida dejo sus veredictos en veredictos.txt, que es el crudo que esta nota nombra.\n"+
		"El paquete tardo 4988.87s, y la unica copia de esa fuente esta en fuente-citada.txt.\n")

	// FORM 1: verdicts inside, named from outside its bundle, no decisive figure
	// of its own. Loose in the workspace root, so it belongs to no bundle.
	write(ws, "veredictos.txt", "gate: PASS T4 forged peer rejected\n"+
		"gate: PASS T5 quorum held\nexit=0\n")

	// FORM 2: Go test source that is not in the tree. Absolute by its own comment.
	write(ws, "fuente.txt", "func TestPruebaQueNoViveEnElArbol(t *testing.T) {\n"+
		"\tt.Fatal(\"copia unica de esta fuente\")\n}\n")

	// FORM 2 again, and this one also carries a decisive figure the document
	// cites. It is the only shape that separates the first two cases of the
	// classification switch, because it satisfies both of them.
	write(ws, "fuente-citada.txt", "func TestOtraQueNoViveEnElArbol(t *testing.T) {\n"+
		"\tt.Fatal(\"copia unica, y ademas cita una cifra decisiva\")\n}\n"+
		"ok  \tnaylamp/engine/hnsw\t4988.87s\n")

	// Neither verdicts nor source nor a cited figure. It must NOT be kept by
	// shape, and without it the row would pass just as well if everything landed
	// in that section.
	write(ws, "ninguno.txt", "notas sueltas sin veredicto y sin fuente ninguna\n")

	// The repository the program reads for the tree source and the declared
	// ports. A Test function that DOES exist, so form 2 has something to be
	// absent from, and one port declaration so the run resembles a real one.
	write(repo, "arbol.go", "package arbol\n\nfunc TestQueSiViveEnElArbol(t *testing.T) {}\n")
	write(repo, filepath.Join("gate", "common.sh"), "CLIENT_PORT=9490\n")
	return ws, repo
}

// shapeSection returns the KEPT BY SHAPE block of a report. A missing header
// yields the empty string, which fails every assertion below rather than
// quietly matching nothing.
func shapeSection(report string) string {
	const abre, cierra = "KEPT BY SHAPE (", "WEAK LEAD ONLY ("
	i := strings.Index(report, abre)
	if i < 0 {
		return ""
	}
	rest := report[i:]
	if j := strings.Index(rest, cierra); j >= 0 {
		return rest[:j]
	}
	return rest
}

func TestReport_ShapeVerdictReachesTheReportAndOutranksBacked(t *testing.T) {
	// THE DEFECT, and it was measured before this row was written rather than
	// feared. The census of DEFER-077 in NAYLAMP_DEFERRED_BACKLOG.md found this
	// file among the red arms that exercise the primitive and leave the call
	// site untouched: retire the keptByShape call from report and the whole
	// hygiene step of CI stays green, gofmt clean, vet at zero, every row above
	// passing. Four different ways of retiring it do that. Nothing in this file
	// noticed, because nothing in this file ran the program.
	//
	// So this row does not call keptByShape at all. It builds the command, runs
	// it the way the header of hygiene.go tells an operator to run it, and reads
	// which section each raw landed in. The program reports and stops, so what it
	// prints IS its observable effect, and the effect cannot appear unless the
	// execution went through the call.
	ws, repo := shapeWorkspace(t)
	bin := hygieneBinary(t, repoRoot(t))

	out, err := exec.Command(bin, "-workspace", ws, "-repo", repo).Output()
	if err != nil {
		t.Fatalf("the program did not complete: %v", err)
	}
	report := string(out)
	shape := shapeSection(report)
	if shape == "" {
		t.Fatal("the report has no KEPT BY SHAPE section at all")
	}

	// Form 1 and form 2, the two shapes clause 5 took on 17 August 2026, each
	// named by the reason the report prints beside it. Asserting the reason and
	// not only the file name is what keeps a raw from satisfying this row by
	// arriving in that section for some other cause.
	for _, c := range []struct{ file, form string }{
		{"veredictos.txt", "FORM 1"},
		{"fuente.txt", "FORM 2"},
	} {
		if !strings.Contains(shape, c.file) {
			t.Errorf("%s is not in KEPT BY SHAPE; the shape verdict is not reaching the report", c.file)
			continue
		}
		if !strings.Contains(shape, c.form) {
			t.Errorf("%s is kept, but the report never names %s as the reason", c.file, c.form)
		}
	}

	// The order of the classification switch. This raw satisfies the first two
	// cases at once, so it is the only one that can tell them apart: form 2 is
	// absolute and has to win, and if the backed case is moved in front of it
	// the raw leaves this section for BACKED. Nothing else in this file sees
	// that swap.
	if !strings.Contains(shape, "fuente-citada.txt") {
		t.Error("fuente-citada.txt left KEPT BY SHAPE; a decisively backed raw is outranking the absolute form")
	}

	// And the half that stops the row from passing on an empty predicate: a raw
	// with no verdict, no absent source and no cited figure must stay out. Without
	// this, everything landing in the section would read as success.
	if strings.Contains(shape, "ninguno.txt") {
		t.Error("ninguno.txt is kept by shape, so the section is keeping files it has no reason to keep")
	}
}
