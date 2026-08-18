// Command hygiene reports which raw evidence artifacts back a figure that is
// cited somewhere, and which ones back nothing that can be found. It never
// deletes anything. The decision stays human.
//
// WHY THIS EXISTS. Clause 5 of the protocol at the end of
// NAYLAMP_DEFERRED_BACKLOG.md says an artifact survives when it backs a cited
// figure, and it names the procedure: (1) open the file and take the figures it
// MEASURES, not the ones it carries as parameter, path, date, port or seed;
// (2) search for THOSE figures, not for the file name. The rule was written
// after a sweep searched by file name instead, found zero hits for
// sift_run.log, and came within one step of deleting the only raw output of a
// 4989.358s run. A rule with a hole applied by hand deletes one file by
// mistake. The same rule applied by a program deletes at machine speed, so this
// program is deliberately built to report and stop.
//
// WHAT IT CANNOT DO, said here rather than discovered later. It cannot tell a
// measured figure from a carried one with certainty. It applies the exclusion
// rules listed in the report, counts every token each rule drops, and prints
// those counts, so the reader can see the size of what the tool decided on its
// own. A figure it drops is a figure it never searched for.
//
// A WEAK LEAD IS NEVER A DELETION CANDIDATE. Not after a second look, not with
// a flag, not by anyone in a hurry. The report puts those files in their own
// class, prints both sides of every hit, and names for each one what would move
// it to backed and what would move it to loose, and a human does the moving.
//
// The reason is that this exact margin is where clause 5 has already gone wrong
// twice, once as a near miss and once for real. The near miss was sift_run.log,
// carrying the only raw output of a 4989.358s run: nobody cited it by name, the
// sweep searched by name, and it came within one step of being deleted. The
// real loss was cluster_bench.txt, scale_result.txt and scale_sweep_result.txt,
// taken by a make clean with no copy in the workspace, and the first of those
// held the simulated baseline of Subphase 3.5, which now survives only rounded
// in prose because re-running the benchmark would measure a different tree.
// Both failures happened at the same edge: a file whose figures were there but
// whose link to a claim was not searchable. That edge is this class. A program
// that deletes on a weak lead reproduces both failures at machine speed, which
// is the one thing this program exists to prevent.
//
// HOW THIS CODE CITES THE WORKSPACE, decided 17 August 2026. The rule is
// written in full in the hard rule of DEFER-035, in
// NAYLAMP_DEFERRED_BACKLOG.md, and that item is where it lives; what follows is
// what this package has to obey, not a second copy of the reasoning.
//
// Every document named here lives OUTSIDE this repository, in the workspace
// directory the -workspace flag points at, so a clone does not carry any of
// them. They are cited by document name and by the name of the thing inside,
// never by line number. Two things break a line number here that do not break
// it in a document. A comment freezes at the commit while the document keeps
// moving, and NAYLAMP_DEFERRED_BACKLOG.md moved its own lines six times in
// August, the last of them on the day this was written. And the reader who most
// needs the citation is the one working from a fresh checkout, who does not
// have the file at all: for them the name says what to go and get, and a number
// says nothing.
//
// Five citations in this package were written the wrong way and were changed
// before any of it was committed: the provenance note of DEFER-016 in
// NAYLAMP_DEFERRED_BACKLOG.md, the surgical mute bullet and the targeting grid
// row of NAYLAMP_LIVENESS_ARC.md, the T4 gate entry of NAYLAMP_ARC_4.7.md and
// the SIFT1M row of the recall table in NAYLAMP_PHASE_1.md. Line numbers that
// DO survive in this package are inside test fixtures, where
// "raft.go:1002-1003" is the sample text a rule has to blank, not a reference
// anyone should resolve.
//
// Usage:
//
//	go run gate/hygiene/hygiene.go -workspace ~/Desktop/Naylamp_workspace
//
// Exit status is 0 whenever the scan completes. Candidates are not failures.
//
// ARCHIVE THE REPORT THAT DECIDES A DELETION. The report goes to stdout and
// evaporates with the terminal, and by clause 5 a measurement with no file is
// not evidence. And this one is the measurement a deletion rests on. A report
// that decided something and was not archived leaves the deletion with nothing
// behind it, and the file it removed is exactly what cannot be consulted
// afterwards to check the reasoning.
//
// This program still writes nothing. That is its rule and it does not bend for
// its own output: the redirect belongs to the operator, who is the one who can
// say which tree the run describes.
//
//	WS=~/Desktop/Naylamp_workspace
//	go run gate/hygiene/hygiene.go -workspace "$WS" \
//	  > "$WS/NAYLAMP_HYGIENE_$(date +%F)_$(git rev-parse --short HEAD).txt"
//
// The name carries the date and the short sha because that is the convention
// every artifact has followed since 29 July 2026, when the run anchored to
// c1b4350 started it, and for the same reason: the verdicts depend on the tree
// and on the workspace as they stood, and a name with neither cannot say which
// run it was. The seven artifacts older than that carry a date and no sha,
// which is why this says since and not always. Anyone deleting on the strength
// of a report writes the artifact name next to the deletion, in the runbook,
// the way clause 5 asks.
//
// WHY IT LIVES IN THE REPOSITORY AND NOT IN THE WORKSPACE, decided 17 August
// 2026. The thing it judges is the workspace, which is not under version
// control, so the obvious place would have been beside it. The argument that
// wins is the opposite one and it is measured: the rules in this file changed
// eleven times in a single day, and every one of those changes silently moved
// which artifacts would have been proposed for deletion. A rule that starts
// dropping a class of figure is invisible without a diff.
//
// AND THAT ARGUMENT IS NOT YET CASHED, said here because writing it as though
// it were would be the defect this program exists to catch. As of the day it
// was written the directory is UNTRACKED: git ls-files gate/hygiene is empty,
// git log over it has no commits, and a git clean would take the whole thing.
// Until someone commits it there is no history to read and the reason above is
// an intention. It is left standing rather than softened because the fix is one
// command by whoever owns the commit, not a rewording here.
//
// OUTSIDE go.work, INSIDE CI. go.work lists only ./engine and every step of
// .github/workflows/ci.yml runs with working-directory: engine, so no package
// pattern reaches this directory. The workflow has a step of its own that names
// both files. To run the same checks by hand:
//
//	test -z "$(gofmt -l gate/hygiene/hygiene.go gate/hygiene/hygiene_test.go)"
//	go vet gate/hygiene/hygiene.go gate/hygiene/hygiene_test.go
//	go test gate/hygiene/hygiene.go gate/hygiene/hygiene_test.go
//
// The first is wrapped in test -z and not left as a bare gofmt -l, because
// gofmt exits 0 even when it lists a file, so on its own it would never make
// anything red. The workflow runs these three verbatim.
//
// ~~Keeping it outside CI is what stops a reporting tool from being able to
// turn the pipeline red over an artifact nobody has read yet.~~ THAT REASON
// WAS FALSE and the correction is kept beside it because it explains why the
// exclusion looked right. Nothing in the test suite reads the workspace: its
// only disk access is under gate/ in this repository, the shell scripts that
// declare the ports, and the ws paths in the tests are synthetic strings under
// /tmp that are never opened. Artifacts are
// read in main alone, and CI never runs main. So the step cannot go red over
// an artifact, and it earns its place by what a person had to catch by hand
// twice on the day this was written, comment width and format drift.
//
// hygiene_test.go carries one row per defect this file shipped with, and the
// rows were mutation checked on the day they were written: reverting the
// trailing word boundary, the hex guard, the raw line token count and the
// single letter label each put a named row in red, and the unmutated tree came
// back green. Anyone who moves this into the module owns making CI green too.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// tier ranks a figure by how much a search for it can decide. A figure that
// matches everything decides nothing, so the tier travels with every finding
// instead of being folded away into a single verdict.
type tier int

// The tier is decided by SIGNIFICANT DIGITS, and getting here cost the first
// three versions of this file. Counting decimal places instead put 0.01, the
// wall clock of a failing test, in the same class as 0.9990, the recall of the
// SIFT run, and 24 artifacts of one bundle were declared backed because some
// unrelated test elsewhere also took 0.01s. Counting integer width instead sent
// 7239, 6415 and 2537 to the unsearched pile, and those three are published
// figures: 7239 in the targeting grid table of NAYLAMP_LIVENESS_ARC.md, and
// 6415 and 2537 in prose, in the service health entry of NAYLAMP_PHASE_4.md
// and the T4 gate entry of NAYLAMP_ARC_4.7.md, which holds no tables at all.
// Calling all three table figures was wrong and is corrected here rather than
// smoothed over. Significant digits separate them correctly: 0.01 has
// one, 0.9990 has four, 7239 has four.
const (
	// tierDecisive is four or more significant digits (0.9990, 310.61, 4988.87,
	// 7239, 0.2125074). A search for one of these rarely collides, so a hit is
	// evidence.
	tierDecisive tier = iota
	// tierUsable is exactly three significant digits (0.219, 456, 1.75). A hit
	// is worth reading and is not enough to keep a file on its own.
	tierUsable
	// tierWeak is two significant digits or fewer: 4, 72, 0.01, 3.5. These are
	// NOT searched. The corpus matches them everywhere, so neither a hit nor a
	// miss decides anything, and letting one of them justify keeping a file is
	// the exact failure clause 5 names when it says a gate artifact would
	// survive on the 9401 of its port. Counted and shown, never used to decide.
	tierWeak
)

// significantDigits counts the digits that carry information in a numeric
// token. Leading zeros never count. Trailing zeros count in a DECIMAL, because
// 0.9990 is a recall someone measured to four places, and do NOT count in an
// integer, because a round integer is how this project writes its parameters.
//
// That asymmetry is the second correction this function needed. Counting
// trailing zeros everywhere made 5000, 50000 and 1000000 decisive, and those
// are the corpus sizes the runs are told to use, not anything the runs
// produced: four raw files were being kept by "F2POS n=5000 churn=50000", which
// is their own command line read back to them.
func significantDigits(tok string) int {
	digits := strings.TrimLeft(strings.ReplaceAll(tok, ".", ""), "0")
	if !strings.Contains(tok, ".") {
		// Only a run of TWO or more trailing zeros is stripped, and the
		// threshold is not arbitrary. One trailing zero happens to a measured
		// count: 4840 nodes on layer 0 of an HNSW graph is a real number that
		// merely ends in a zero, and stripping it demoted a measurement. Two or
		// more is how a person writes a parameter: 5000, 50000, 1000000 are all
		// corpus sizes someone chose, and those were keeping four raw files
		// alive on their own command lines.
		if trimmed := strings.TrimRight(digits, "0"); len(digits)-len(trimmed) >= 2 {
			digits = trimmed
		}
	}
	return len(digits)
}

// tierOf ranks a token by how much a search for it can settle.
func tierOf(tok string) tier {
	switch n := significantDigits(tok); {
	case n >= 4:
		return tierDecisive
	case n == 3:
		return tierUsable
	default:
		return tierWeak
	}
}

func (t tier) String() string {
	switch t {
	case tierDecisive:
		return "DECISIVE"
	case tierUsable:
		return "USABLE"
	default:
		return "WEAK"
	}
}

// figure is one numeric token taken from a candidate artifact, with the line it
// came from so a human can judge whether the tool classified it correctly.
type figure struct {
	text string
	tier tier
	line int
	ctx  string
}

// citation is one place in the corpus where a figure was found. The line TEXT
// travels with it because a weak hit cannot be judged from a file name and a
// number: deciding whether the 300 of a gate log and the 300 of a phase
// document are the same measurement or two unrelated parameters takes reading
// both lines, and the report exists to put them side by side.
type citation struct {
	file string
	line int
	text string
}

// finding is the verdict for one candidate artifact.
type finding struct {
	path string
	// bundle is the evidence bundle this file lives in, empty when the file is
	// loose in the workspace root. The distinction is not cosmetic: clause 5
	// says evidence lives in ONE bundle with its runbook inside, so a file
	// inside a bundle is governed by that runbook and a loose file is governed
	// by nothing until someone decides. The loose ones are the hygiene
	// question; bundle internals are reported apart so they cannot pad it.
	bundle string
	// shapeKeep is set when the file is kept by SHAPE rather than by a cited
	// figure, which is the amplification clause 5 took on 17 August 2026 after
	// this program showed that two kinds of raw carry no figures at all. The
	// string is the reason, and it is printed, because a file kept without a
	// figure has to say out loud what kept it.
	shapeKeep string
	size      int64
	total     int // numeric tokens seen before any rule ran
	dropped   map[string]int
	weak      int
	searched  []figure
	backing   map[string][]citation // figure text -> where it is cited
	backTier  map[string]tier       // figure text -> how much that citation can decide
	exclusive []figure              // searched figures found nowhere in the corpus
}

// decisivelyBacked reports whether at least one DECISIVE figure of this file is
// cited elsewhere. Only that answers clause 5 on its own. A citation of a
// weaker figure goes in the report too, under its own heading, so that the
// difference between the two is on the page rather than in this function.
// figureOf returns the figure this file contributed under a given text, so the
// report can print the line it came from next to the line that cites it.
func (f finding) figureOf(text string) (figure, bool) {
	for _, g := range f.searched {
		if g.text == text {
			return g, true
		}
	}
	return figure{}, false
}

func (f finding) decisivelyBacked() bool {
	for t, tr := range f.backTier {
		if tr == tierDecisive && len(f.backing[t]) > 0 {
			return true
		}
	}
	return false
}

var (
	// Tokens that are almost never a measurement produced by a run.
	// Dates come in both shapes in this workspace: 2026-08-10 in the documents
	// and 2026/08/10 in the gate logs. Missing the second shape let a log line
	// through with its date intact.
	reDate = regexp.MustCompile(`\b\d{4}[-/]\d{2}[-/]\d{2}\b`)
	// The fractional seconds are part of the clock, not a measurement. Without
	// the optional group, the .694423 of a leader election timestamp in
	// NAYLAMP_TLS_GATE_2026-08-10_095946b.txt was promoted to DECISIVE, and
	// three such fractions were the only figures that file offered.
	reClock    = regexp.MustCompile(`\b\d{1,2}:\d{2}:\d{2}(\.\d+)?\b`)
	reFileLine = regexp.MustCompile(`[A-Za-z0-9_./-]+\.[A-Za-z]{2,4}:\d+`)
	// Guarded by isHex below, and the guard is the whole point: the decimal
	// digits are a subset of [0-9a-f], so an unguarded version ate the 4226497
	// of "dist=0.4226497" in a TLS gate artifact and took a DECISIVE figure
	// down with it. A run of digits with no letter in it is a number.
	reHex     = regexp.MustCompile(`\b[0-9a-f]{7,}\b`)
	reIPPort  = regexp.MustCompile(`\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b`)
	rePathNum = regexp.MustCompile(`/[A-Za-z0-9_.-]*\d[A-Za-z0-9_.-]*`)
	// A bare year is a date without its month and day. The first run of this
	// tool marked eleven artifacts as backed on the strength of "2026" alone,
	// which is the failure this program was written to prevent.
	reYear = regexp.MustCompile(`\b(19|20)\d{2}\b`)
	// A number introduced by a colon is a port, a line or an index, never a
	// measurement. The clause names the case: an artifact would survive on the
	// 9401 of its port, counted there at eighteen files of the workspace on 16
	// August 2026. The count is quoted with its date rather than restated,
	// because it moves with every artifact written.
	//
	// The colon rule that used to live here is gone, and its removal is
	// measured rather than tidied away: over 83 artifacts it never dropped a
	// single token, because everything it would have caught was already taken
	// by file:line, ip/port or carried-label first. A rule announced in the
	// report and firing zero times is a rule that lies about what the tool did.
	//
	// What replaces it catches the case that matters and that no other rule
	// saw: a number with the port word AFTER it. Spanish prose in this registry
	// writes "el 9401 de su puerto", and the label rule only looks to the left.
	rePortAfter = regexp.MustCompile(`(?i)\b\d+\s+(de\s+su\s+|del\s+|de\s+)?(puerto|port)\b`)
	// A number introduced by a colon that follows a name or a bracket is a port
	// or an index. This rule was removed once for never firing, and putting it
	// back is the price of running the pipeline over the corpus as well: on
	// that side it catches the "PRIV[1]:9490" of the surgical mute bullet in
	// NAYLAMP_LIVENESS_ARC.md, which was helping keep a whole gate artifact
	// alive on two port numbers. It is NOT the only rule that reaches that
	// line, and saying it was made this comment claim more than it earns:
	// declared-port takes the same 9490 from gate/common.sh, and is the only
	// thing that takes the bare 9401 two clauses later, where no pattern says
	// port at all. The character before the colon must NOT be a digit,
	// so the level histogram "map[0:4840" and the per replica counts
	// "command_counts=1:15" are left where they are.
	reNamedColon = regexp.MustCompile(`[A-Za-z_\])]:\d+`)

	// No trailing \b on purpose, and this one cost a rewrite. With it, a Go test
	// duration written as 542.32s or 4988.87s does not match at all, because
	// there is no word boundary between the last digit and the s. That is the
	// class of figure this whole rule exists for. The 4988.87s of the SIFT run
	// is named as exclusive to sift_run.log in the provenance note of DEFER-016
	// in NAYLAMP_DEFERRED_BACKLOG.md, and NOT in clause 5, which carries the
	// 4989.358s instead: getting that citation wrong here would repeat the
	// defect clause 5 corrected in itself this same week. The first version of
	// this tool kept sift_run.log for a different reason, its recall numbers,
	// so it would have called the motivating case right while being blind to
	// the figure that motivated it.
	reDecimal = regexp.MustCompile(`\b\d+\.\d+`)
	reInteger = regexp.MustCompile(`\b\d+`)

	// A label marks the number BESIDE IT as an input to the run rather than an
	// output of it. This has to bind to the token and not to the line: the
	// first version dropped every number on any line mentioning a seed, and on
	// a seed sweep that is every line, so 3218 tokens of
	// NAYLAMP_REACH_GRID_2026-07-27.txt reached the search as zero. A rule that
	// silently deletes the measurements it was meant to sort is the same defect
	// clause 5 was corrected for, one layer down.
	// The single letter labels k and n were in this list and came out: in
	// NAYLAMP_DEFER053_REPRO/evidencia/who_raw.txt the line reads "alcanzables
	// desde una consulta k=n: 4999 de 5000", where the n is the tail of "k=n"
	// and 4999 is the measurement. The rule ate it, and 4999 is cited twice in
	// the workspace. A label short enough to appear inside other prose is not a
	// label.
	reCarried = regexp.MustCompile(`(?i)\b(seed|semilla|puerto|port|pid|uid|gid|addr|host|dim|maxid|version|term|node|nodo|round|ronda|tick|go1|count)\s*[=:#]?\s*\d+`)
)

func main() {
	var workspace, repo string
	var showAll bool
	flag.StringVar(&workspace, "workspace", "", "directory holding the raw artifacts to judge (required)")
	flag.StringVar(&repo, "repo", "", "repository whose source counts as a citing site (default: <workspace>/Naylamp)")
	flag.BoolVar(&showAll, "v", false, "list every searched figure, not only the exclusive ones")
	flag.Parse()

	if workspace == "" {
		fmt.Fprintln(os.Stderr, "hygiene: -workspace is required")
		os.Exit(2)
	}
	if repo == "" {
		repo = filepath.Join(workspace, "Naylamp")
	}

	rePorts = declaredPorts(repo)

	corpus, err := collectCorpus(workspace, repo)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hygiene: reading corpus: %v\n", err)
		os.Exit(2)
	}
	candidates, err := collectCandidates(workspace)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hygiene: reading candidates: %v\n", err)
		os.Exit(2)
	}

	report(workspace, repo, corpus, candidates, showAll)
}

// collectCorpus gathers the places where a figure can be CITED. Per clause 5
// those are the registry documents, a line of the tree, or the body of a
// backlog item. Other raw artifacts are deliberately NOT corpus: one raw
// echoing another proves nothing about either.
func collectCorpus(workspace, repo string) (map[string][]string, error) {
	corpus := make(map[string][]string)
	add := func(root string, keep func(string) bool) error {
		return filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if d.IsDir() {
				base := d.Name()
				if base == ".git" || base == "node_modules" || base == "sift" {
					return filepath.SkipDir
				}
				return nil
			}
			if !keep(p) {
				return nil
			}
			lines, err := readLines(p)
			if err != nil {
				return nil
			}
			corpus[p] = lines
			return nil
		})
	}
	// Registry documents in the workspace, plus the runbook of each evidence
	// bundle. The runbook has to count: clause 5 says the reproduction cost
	// goes IN THE RUNBOOK, and NAYLAMP_DEFER053_REPRO/COMO_REPRODUCIR.txt cites
	// 0.2125074, a measurement of a raw file sitting beside it. Leaving .txt
	// out of the corpus made that citation invisible while still judging the
	// runbook as if it were raw output.
	if err := add(workspace, func(p string) bool {
		if strings.Contains(p, string(filepath.Separator)+"Naylamp"+string(filepath.Separator)) {
			return false
		}
		return strings.HasSuffix(p, ".md") || isRunbook(workspace, p)
	}); err != nil {
		return nil, err
	}
	// The tree: source, workflows, gate scripts, Makefile, and its own docs.
	// This program's own directory is excluded, and the reason is not tidiness.
	// Its comments quote real figures from this workspace to explain the rules,
	// so leaving it in made it cite the very numbers it was judging: a run
	// reported 542.32 as "cited at gate/hygiene/hygiene.go". An instrument
	// cannot be its own evidence.
	self := filepath.Join(repo, "gate", "hygiene")
	if err := add(repo, func(p string) bool {
		if strings.HasPrefix(p, self+string(filepath.Separator)) {
			return false
		}
		// Test files are excluded, and the reason is the clause itself. Step (1)
		// says to drop what a run CARRIES as a parameter, and a _test.go file is
		// made of parameters: DropProb: 0.12 in raft_test.go and dropProb :=
		// 0.02 + ... in cluster_dst_test.go were counting as citations and
		// keeping artifacts alive. The clause applies its own step to the corpus
		// or it does not apply it at all.
		if strings.HasSuffix(p, "_test.go") {
			return false
		}
		switch {
		case strings.HasSuffix(p, ".go"),
			strings.HasSuffix(p, ".yml"),
			strings.HasSuffix(p, ".yaml"),
			strings.HasSuffix(p, ".sh"),
			strings.HasSuffix(p, ".md"),
			filepath.Base(p) == "Makefile":
			return true
		}
		return false
	}); err != nil {
		return nil, err
	}
	return corpus, nil
}

// collectCandidates gathers the raw outputs whose survival is in question:
// .txt and .log under the workspace, excluding the repository itself and the
// SIFT dataset, which is data and not evidence.
func collectCandidates(workspace string) ([]string, error) {
	var out []string
	err := filepath.WalkDir(workspace, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			switch d.Name() {
			case ".git", "Naylamp", "sift", "node_modules":
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(p, ".txt") && !strings.HasSuffix(p, ".log") {
			return nil
		}
		// This program's own archived reports are not evidence, and leaving
		// them in was a measured mistake rather than a theoretical one. The
		// archive command in the header redirects stdout, and a shell creates
		// that file before the program starts, so the very first archived run
		// scanned its own half written output: 1327 bytes, and it came out
		// BACKED by a 0.9990 it had just copied out of another file's entry.
		// An instrument cannot be its own evidence, which is the same reason
		// the corpus excludes this package's source.
		if strings.HasPrefix(filepath.Base(p), "NAYLAMP_HYGIENE_") {
			return nil
		}
		// A bundle runbook is prose about the evidence, not evidence. It is
		// corpus, so it is not also a candidate.
		if isRunbook(workspace, p) {
			return nil
		}
		out = append(out, p)
		return nil
	})
	sort.Strings(out)
	return out, err
}

func readLines(path string) ([]string, error) {
	f, err := os.Open(path) //nolint:gosec // operator supplied directory, not untrusted input
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()
	var lines []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<22)
	for sc.Scan() {
		lines = append(lines, sc.Text())
	}
	return lines, sc.Err()
}

// blank removes from a line every shape that carries a number without measuring
// anything, and counts what each rule took under the rule's own name. Passing a
// nil map skips the counting.
//
// IT RUNS ON BOTH SIDES, and the first version did not, which is the defect
// that produced the worst result this tool has given. Step (1) of clause 5 says
// to discard what a run CARRIES as parameter, path, date, port or seed, and
// applying that only to the artifact left the corpus raw. So the 1002 of an
// object id matched the 1002 of "raft.go:1002-1003", a line number; the 9490 of
// a probe matched "CLIENT_PORT=9490" in gate/common.sh; and worst of all, the
// 9401 of a port matched the sentence in clause 5 that names 9401 as the
// example of what must never save a file. The clause applies its own step to
// both sides or it does not apply it at all.
func blank(raw string, dropped map[string]int) string {
	line := raw
	for _, r := range []struct {
		name  string
		re    *regexp.Regexp
		guard func(string) bool // when set, only matches passing it are dropped
	}{
		{name: "date", re: reDate},
		{name: "clock", re: reClock},
		{name: "bare-year", re: reYear},
		{name: "file:line", re: reFileLine},
		{name: "sha/hex", re: reHex, guard: isHex},
		{name: "ip/port", re: reIPPort},
		{name: "path", re: rePathNum},
		{name: "carried-label", re: reCarried},
		{name: "port-after", re: rePortAfter},
		{name: "named-colon", re: reNamedColon},
		{name: "declared-port", re: rePorts},
	} {
		if r.re == nil {
			continue
		}
		line = r.re.ReplaceAllStringFunc(line, func(hit string) string {
			if r.guard != nil && !r.guard(hit) {
				return hit
			}
			if dropped != nil {
				dropped[r.name] += len(reInteger.FindAllString(hit, -1))
			}
			return " "
		})
	}
	return line
}

// extract pulls the numeric tokens out of one artifact and classifies them.
// Every token dropped is counted under the name of the rule that dropped it, so
// the report can show how much the tool decided without being asked.
func extract(lines []string) (figs []figure, total int, dropped map[string]int) {
	dropped = make(map[string]int)
	seen := make(map[string]bool)

	for i, raw := range lines {
		line := blank(raw, dropped)

		// Counted on the RAW line, before any rule ran, because this number is
		// the denominator of the report's own transparency claim. Counting it
		// on the blanked line understated it by 25 to 45 per cent, which made
		// the tool look as though it had decided less than it had.
		total += len(reInteger.FindAllString(raw, -1))

		for _, tok := range reDecimal.FindAllString(line, -1) {
			if seen[tok] {
				continue
			}
			seen[tok] = true
			figs = append(figs, figure{text: tok, tier: tierOf(tok), line: i + 1, ctx: window(raw, tok)})
		}
		// Remove the decimals already taken so their halves are not counted
		// again as integers.
		line = reDecimal.ReplaceAllString(line, " ")
		for _, tok := range reInteger.FindAllString(line, -1) {
			t := tierOf(tok)
			if seen[tok] {
				continue
			}
			seen[tok] = true
			figs = append(figs, figure{text: tok, tier: t, line: i + 1, ctx: window(raw, tok)})
		}
	}
	return figs, total, dropped
}

// isHex reports whether a run of [0-9a-f] is really a hash and not a number
// that happens to use only those digits. A commit sha carries letters; a
// measurement does not.
func isHex(s string) bool {
	return strings.ContainsAny(s, "abcdef")
}

func trim(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > 110 {
		return s[:110] + "..."
	}
	return s
}

// window returns the part of a line around a figure, so the number the reader
// has to judge is inside what gets printed. Cutting the first 110 characters
// instead hid the figure in three of the four collisions the weak lead section
// showed, which turned the one section written for a human to read into a
// section a human could not read.
func window(line, fig string) string {
	at := strings.Index(line, fig)
	if at < 0 {
		return trim(line)
	}
	const before, after = 45, 65
	start, end := at-before, at+len(fig)+after
	prefix, suffix := "...", "..."
	if start <= 0 {
		start, prefix = 0, ""
	}
	if end >= len(line) {
		end, suffix = len(line), ""
	}
	return prefix + strings.TrimSpace(line[start:end]) + suffix
}

// search looks for one figure across the corpus as a whole token. It returns
// at most a handful of sites: the point is to show that the figure is cited and
// where, not to enumerate every echo.
func search(corpus map[string][]string, self, fig string) []citation {
	re := regexp.MustCompile(`(^|[^0-9.])` + regexp.QuoteMeta(fig) + `([^0-9]|$)`)
	var hits []citation
	paths := make([]string, 0, len(corpus))
	for p := range corpus {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, p := range paths {
		if p == self {
			continue
		}
		for i, l := range corpus[p] {
			// The corpus line goes through the same rules as the artifact. A
			// line number, a port or a seed on this side is no more a citation
			// than it is a measurement on the other.
			if re.MatchString(blank(l, nil)) {
				hits = append(hits, citation{file: p, line: i + 1, text: window(l, fig)})
				if len(hits) >= 6 {
					return hits
				}
				break
			}
		}
	}
	return hits
}

func report(workspace, repo string, corpus map[string][]string, candidates []string, showAll bool) {
	fmt.Println("NAYLAMP evidence hygiene report")
	fmt.Println("===============================")
	fmt.Println()
	fmt.Println("This program reports and stops. It writes nothing and removes nothing.")
	fmt.Println("A candidate is a file whose measured figures were not found anywhere")
	fmt.Println("in the corpus, which is where a human starts reading, not where a file ends.")
	fmt.Println()
	fmt.Printf("workspace : %s\n", workspace)
	fmt.Printf("repo      : %s\n", repo)
	fmt.Printf("corpus    : %d files that can cite a figure (docs, tree source, gate scripts)\n", len(corpus))
	fmt.Printf("candidates: %d raw artifacts under judgement\n", len(candidates))
	fmt.Println()
	fmt.Println("RULES APPLIED, so that what the tool decided on its own is visible:")
	fmt.Println("  dropped before searching: dates, clock times, file:line refs, hex/sha,")
	fmt.Println("  ip and port, numbers inside a path, numbers introduced by a colon, and")
	fmt.Println("  any number on a line carrying an input label (seed, port, dim, version).")
	fmt.Println("  The same rules run on BOTH sides: a line number or a port in a document")
	fmt.Println("  is no more a citation than it is a measurement in a raw file.")
	fmt.Println("  Tiers go by SIGNIFICANT digits, not by width. Leading zeros never count;")
	fmt.Println("  trailing zeros count in a decimal (0.9990 is measured to four places) and")
	fmt.Println("  not in an integer (5000 is a corpus size someone chose). Four or more is")
	fmt.Println("  DECISIVE and only a DECISIVE figure keeps a file on its own; three is")
	fmt.Println("  USABLE and is a lead; two or fewer is never searched at all.")
	fmt.Println()

	treeSrc := readTreeSource(repo)
	var keep, shape, lead, ask []finding
	for _, c := range candidates {
		lines, err := readLines(c)
		if err != nil {
			fmt.Printf("  SKIPPED %s: %v\n", c, err)
			continue
		}
		st, _ := os.Stat(c)
		figs, total, dropped := extract(lines)

		f := finding{path: c, total: total, dropped: dropped, bundle: bundleOf(workspace, c),
			backing: map[string][]citation{}, backTier: map[string]tier{}}
		if st != nil {
			f.size = st.Size()
		}
		for _, g := range figs {
			if g.tier == tierWeak {
				f.weak++
				continue
			}
			f.searched = append(f.searched, g)
			if hits := search(corpus, c, g.text); len(hits) > 0 {
				f.backing[g.text] = hits
				f.backTier[g.text] = g.tier
			} else {
				f.exclusive = append(f.exclusive, g)
			}
		}
		var absolute bool
		f.shapeKeep, absolute = keptByShape(workspace, lines, c, corpus, treeSrc)
		switch {
		// Form 2 goes ahead of everything, because its comment says it is
		// absolute and the switch has to agree with the comment. Before this,
		// a raw holding source absent from the tree that also happened to have
		// one cited figure came out BACKED and never printed the reason that
		// actually keeps it.
		case absolute:
			shape = append(shape, f)
		case f.decisivelyBacked():
			keep = append(keep, f)
		case f.shapeKeep != "":
			shape = append(shape, f)
		case len(f.backing) > 0:
			lead = append(lead, f)
		default:
			ask = append(ask, f)
		}
	}

	fmt.Printf("BACKED (%d): at least one DECISIVE figure is cited outside the file.\n", len(keep))
	fmt.Println("These stay. The citing site is what clause 5 asks to be written beside them.")
	fmt.Println()
	for _, f := range keep {
		fmt.Printf("  %s  (%d bytes)\n", rel(workspace, f.path), f.size)
		fmt.Printf("     %d tokens seen, %d searched, %d weak and not searched\n", f.total, len(f.searched), f.weak)
		// DECISIVE figures come first, and this was a display defect worth
		// naming rather than quietly fixing. The class is DEFINED by having a
		// decisive figure cited, and sorting the list alphabetically buried
		// them: NAYLAMP_REACH_GRID_2026-07-27.txt showed 109, 119 and 124, all
		// three digit collisions, while the 2439, 4489 and 7239 that actually
		// earn it sat twenty rows down under a truncation. The verdict was
		// right and the evidence shown for it was the weakest available, which
		// reads exactly like a file kept on noise.
		texts := make([]string, 0, len(f.backing))
		for t := range f.backing {
			texts = append(texts, t)
		}
		sort.Slice(texts, func(i, j int) bool {
			ti, tj := f.backTier[texts[i]], f.backTier[texts[j]]
			if ti != tj {
				return ti < tj
			}
			return texts[i] < texts[j]
		})
		shown := 0
		for _, t := range texts {
			if shown >= 3 && !showAll {
				fmt.Printf("     ... and %d more cited figures, none of them decisive\n", len(texts)-shown)
				break
			}
			c := f.backing[t][0]
			fmt.Printf("     %-12s [%s] cited at %s:%d\n", t, f.backTier[t], rel(workspace, c.file), c.line)
			shown++
		}
		if n := len(f.exclusive); n > 0 {
			fmt.Printf("     %d figure(s) exclusive to this file, e.g. %s (line %d)\n", n, f.exclusive[0].text, f.exclusive[0].line)
		}
		fmt.Println()
	}

	fmt.Printf("KEPT BY SHAPE (%d): kept by what the file IS, not by a figure it backs.\n", len(shape))
	fmt.Println("These are the two forms clause 5 took on 17 August 2026, after this program")
	fmt.Println("showed the two step procedure has nothing to say about a raw whose payload")
	fmt.Println("is verdicts or source. Most of these DO contain figures; what none of them")
	fmt.Println("has is a decisive figure cited elsewhere, so the token counts are printed")
	fmt.Println("here too and a reader can see exactly how much was searched.")
	fmt.Println()
	for _, f := range shape {
		fmt.Printf("  %s  (%d bytes)\n", rel(workspace, f.path), f.size)
		fmt.Printf("     %d tokens seen, %d searched, %d weak and not searched\n", f.total, len(f.searched), f.weak)
		fmt.Printf("     %s\n", f.shapeKeep)
		fmt.Println()
	}

	fmt.Printf("WEAK LEAD ONLY (%d): NOT backed, NOT loose, and NEVER a deletion candidate.\n", len(lead))
	fmt.Println()
	fmt.Println("WHAT THIS CLASS MEANS. No figure of these files with four or more")
	fmt.Println("significant digits was found anywhere in the corpus. What WAS found is a")
	fmt.Println("figure of three, and three significant digits collide: the 300 of a gate")
	fmt.Println("log and the 300 of a phase document can be the same measurement or two")
	fmt.Println("unrelated parameters, and no amount of searching settles which.")
	fmt.Println()
	fmt.Println("So this class is where the mechanised rule stops and a person starts. The")
	fmt.Println("other three classes audit themselves: a decisive citation is checkable by")
	fmt.Println("reading one line, and an absence of figures is checkable by opening the")
	fmt.Println("file. This one cannot be checked without judging what a number MEANS on")
	fmt.Println("both sides, so each file below is named with its own reason, and with what")
	fmt.Println("would move it either way. Never as a group.")
	fmt.Println()
	for _, f := range lead {
		fmt.Printf("  %s  (%d bytes)\n", rel(workspace, f.path), f.size)
		fmt.Printf("     %d tokens seen, %d searched, %d weak and not searched\n", f.total, len(f.searched), f.weak)

		texts := make([]string, 0, len(f.backing))
		for t := range f.backing {
			texts = append(texts, t)
		}
		sort.Strings(texts)

		fmt.Printf("     WHY WEAK: %d hit(s), all of three significant digits, none decisive.\n", len(texts))
		for i, t := range texts {
			if i >= 3 && !showAll {
				fmt.Printf("       ... and %d more hit(s), same class\n", len(texts)-i)
				break
			}
			c := f.backing[t][0]
			fmt.Printf("       %s  [%d significant digits]\n", t, significantDigits(t))
			if g, ok := f.figureOf(t); ok {
				fmt.Printf("         here : line %d: %s\n", g.line, g.ctx)
			}
			fmt.Printf("         there: %s:%d: %s\n", rel(workspace, c.file), c.line, c.text)
			if n := len(f.backing[t]); n > 1 {
				fmt.Printf("         and in %d more place(s), which widens the collision\n", n-1)
			}
		}

		// Only DECISIVE exclusives are offered. The first version offered
		// whatever was exclusive, and in both cases that existed the figure it
		// named was USABLE, so citing it would have left the file exactly where
		// it was: decisivelyBacked requires a decisive figure. Handing a reader
		// a procedure that does not work is worse than handing them none.
		var promotable []figure
		for _, g := range f.exclusive {
			if g.tier == tierDecisive {
				promotable = append(promotable, g)
			}
		}
		if n := len(promotable); n > 0 {
			fmt.Printf("     TO MOVE IT TO BACKED: cite one of its %d exclusive DECISIVE figure(s)\n", n)
			fmt.Printf("       in a document or a line of the tree, starting with %s (line %d): %s\n",
				promotable[0].text, promotable[0].line, promotable[0].ctx)
			fmt.Println("       Or read the two lines of a hit above and, if they are the same")
			fmt.Println("       measurement, write the site beside the file as clause 5 asks.")
		} else {
			fmt.Println("     TO MOVE IT TO BACKED: it holds NO decisive figure at all, so nothing")
			fmt.Println("       in it can be promoted by citing it. The only route is reading the")
			fmt.Println("       two lines of a hit above and confirming they are one measurement.")
		}
		fmt.Println("     TO MOVE IT TO LOOSE: confirm every hit above is a coincidence. Then")
		fmt.Println("       it is judged under the loose heading, where the expensive-raw")
		fmt.Println("       exception applies and its reproduction cost goes in the runbook.")
		fmt.Println()
	}

	var looseAsk, bundledAsk []finding
	for _, f := range ask {
		if f.bundle == "" {
			looseAsk = append(looseAsk, f)
		} else {
			bundledAsk = append(bundledAsk, f)
		}
	}

	byBundle := map[string]int{}
	for _, f := range bundledAsk {
		byBundle[f.bundle]++
	}
	fmt.Printf("INSIDE A BUNDLE, NOT BACKED ON THEIR OWN (%d): reported apart on purpose.\n", len(bundledAsk))
	fmt.Println("Clause 5 puts evidence in ONE bundle with its runbook inside, so these are")
	fmt.Println("governed by that runbook and not by an individual citation. They are NOT")
	fmt.Println("the hygiene question and they must not pad it.")
	fmt.Println()
	bnames := make([]string, 0, len(byBundle))
	for b := range byBundle {
		bnames = append(bnames, b)
	}
	sort.Strings(bnames)
	for _, b := range bnames {
		fmt.Printf("  %-52s %d file(s)\n", b, byBundle[b])
	}
	fmt.Println()

	fmt.Printf("LOOSE AND NOT BACKED (%d): this is the hygiene question, and the whole of it.\n", len(looseAsk))
	fmt.Println("No measured figure of these was found in the corpus, and no runbook covers")
	fmt.Println("them. Do NOT read this as a delete list. Clause 5 keeps a raw that is")
	fmt.Println("expensive to reproduce even when it backs no cited figure, and whoever")
	fmt.Println("invokes that exception writes the reproduction cost in the runbook.")
	fmt.Println()
	for _, f := range looseAsk {
		fmt.Printf("  %s  (%d bytes)\n", rel(workspace, f.path), f.size)
		fmt.Printf("     %d tokens seen, %d searched, %d weak and not searched\n", f.total, len(f.searched), f.weak)
		if len(f.searched) == 0 {
			fmt.Println("     Nothing searchable: this file carries no figure the rules kept.")
			fmt.Println("     Its payload may be verdicts rather than measurements, which is a")
			fmt.Println("     shape clause 5 does not cover. Open it before deciding anything.")
		}
		for i, g := range f.exclusive {
			if i >= 4 && !showAll {
				fmt.Printf("     ... and %d more\n", len(f.exclusive)-i)
				break
			}
			fmt.Printf("     %-12s [%s] line %d: %s\n", g.text, g.tier, g.line, g.ctx)
		}
		fmt.Println()
	}

	fmt.Println("DROPPED TOKENS BY RULE, across every candidate:")
	agg := map[string]int{}
	all := append([]finding{}, keep...)
	all = append(all, shape...)
	all = append(all, lead...)
	all = append(all, ask...)
	for _, f := range all {
		for k, v := range f.dropped {
			agg[k] += v
		}
	}
	names := make([]string, 0, len(agg))
	for k := range agg {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, n := range names {
		fmt.Printf("  %-14s %d\n", n, agg[n])
	}
	fmt.Println()
	fmt.Printf("Judged %d artifacts against %d citing files: %d backed, %d kept by shape, %d weak lead, %d in a bundle, %d loose and unbacked.\n",
		len(candidates), len(corpus), len(keep), len(shape), len(lead), len(bundledAsk), len(looseAsk))
}

// runbookNames are the prose files that describe a bundle rather than being
// evidence in it. The match is BY NAME and not by position, and the first
// version of this function got that wrong: it took any .txt at the root of a
// bundle, which promoted nineteen raw outputs, node1.txt and omnibus-manifest
// .txt among them, out of the candidate list and into the corpus, where they
// could vouch for each other. Of the twenty files that shape matched, exactly
// one was a runbook. A new runbook has to be added to this list to be seen,
// and that limit is written here rather than left to be discovered.
var runbookNames = []string{"COMO_REPRODUCIR", "RUNBOOK", "README", "NOTAS", "LEEME"}

var (
	// rePorts is filled by declaredPorts once the repository path is known, so
	// the blanking pipeline can drop the numbers this project calls ports
	// without any rule having to recognise them as ports.
	rePorts *regexp.Regexp

	reGoTestFunc = regexp.MustCompile(`func (Test\w+)\(`)
	reVerdict    = regexp.MustCompile(`\b(PASS|FAIL|OK|ok)\b|exit=\d`)
)

// keptByShape applies the two forms clause 5 gained on 17 August 2026, for raw
// output that carries no figures at all. It returns the reason to print, or "".
//
// Form 2 goes first because it is absolute: a raw whose payload is Go source
// that is NOT in the tree is the only copy of work not yet done, and no
// citation argument can outweigh that. NAYLAMP_DEFER027_PROOFS_2026-08-04.txt
// is the measured case, holding four TestProof functions that exist nowhere in
// engine/.
//
// Form 1 is the gate artifact, whose payload is named verdicts. Searching by
// FILE NAME is legitimate here and only here, because there is no figure to
// search for, and the clause requires both halves: the name has to be cited AND
// the file has to carry a verdict. A name cited over a file with no verdict in
// it proves nothing and is not kept by this path.
func keptByShape(workspace string, lines []string, path string, corpus map[string][]string, treeSrc []string) (reason string, absolute bool) {
	var missing []string
	for _, l := range lines {
		for _, m := range reGoTestFunc.FindAllStringSubmatch(l, -1) {
			if !containsAny(treeSrc, m[1]) {
				missing = append(missing, m[1])
			}
		}
	}
	if len(missing) > 0 {
		shown := missing[0]
		if len(missing) > 1 {
			shown = fmt.Sprintf("%s and %d more", shown, len(missing)-1)
		}
		return fmt.Sprintf("FORM 2: holds Go test source absent from the tree (%s). Only copy, kept whatever else it does or does not back", shown), true
	}

	verdicts := 0
	for _, l := range lines {
		if reVerdict.MatchString(l) {
			verdicts++
		}
	}
	if verdicts == 0 {
		return "", false
	}
	base := filepath.Base(path)
	own := bundleOf(workspace, path)
	for _, p := range sortedKeys(corpus) {
		// A document that describes a bundle is that bundle's inventory, not a
		// citation of it. Comparing DIRECTORIES was not enough and the miss was
		// measured: NAYLAMP_OMNIBUS_GATE_2026-08-10_095946b_NOTAS.md lives in
		// the workspace root, so its bundle came out empty and it vouched for
		// the very files it was written to list. The name is what ties a
		// document to a bundle, so the name is what gets compared.
		if own != "" && (bundleOf(workspace, p) == own || strings.Contains(filepath.Base(p), own)) {
			continue
		}
		for i, l := range corpus[p] {
			if strings.Contains(l, base) {
				note := ""
				// Two bundles hold files with the same base name, so a hit on
				// the name alone cannot tell which run the citing line means.
				// Said out loud rather than resolved, because resolving it takes
				// reading the line.
				if own != "" && !strings.Contains(l, own) {
					note = ". The citing line does not name this bundle, and the base name is shared, so check which run it means"
				}
				return fmt.Sprintf("FORM 1: carries %d verdict line(s), cited by name from outside its bundle at %s:%d%s",
					verdicts, rel(workspace, p), i+1, note), false
			}
		}
	}
	return "", false
}

// rePortDecl matches the shell assignments where this project declares the
// ports its gates use, such as NODE_PORT=9401 in gate/common.sh.
var rePortDecl = regexp.MustCompile(`(?m)^[A-Z_]*PORT[A-Z_]*=(\d+)`)

// declaredPorts reads the port numbers the repository declares for itself and
// returns a matcher that blanks exactly those numbers wherever they appear.
//
// This exists because the lexical rules cannot solve the case, and pretending
// otherwise would be worse than saying so. Both of these are prose:
//
//	the artifact:  [el nodo 1 (lider) escucha de verdad en 9401? y el nodo 3?]
//	the document:  deja intacto el raft par-a-par en 9401
//
// Nothing around either number says "port". No pattern separates that 9401
// from a measurement, and clause 5 names this exact number as the example of
// what must never keep a file alive. What does separate them is that the
// project DECLARES its ports, in gate/common.sh and gate/tls.sh, so the tool
// reads the declaration instead of guessing. New ports are picked up by being
// declared, which is where they were going to be written anyway.
func declaredPorts(repo string) *regexp.Regexp {
	seen := map[string]bool{}
	var vals []string
	entries, err := os.ReadDir(filepath.Join(repo, "gate"))
	if err != nil {
		return nil
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".sh") {
			continue
		}
		lines, err := readLines(filepath.Join(repo, "gate", e.Name()))
		if err != nil {
			continue
		}
		for _, l := range lines {
			for _, m := range rePortDecl.FindAllStringSubmatch(l, -1) {
				if !seen[m[1]] {
					seen[m[1]] = true
					vals = append(vals, regexp.QuoteMeta(m[1]))
				}
			}
		}
	}
	if len(vals) == 0 {
		return nil
	}
	sort.Strings(vals)
	return regexp.MustCompile(`\b(` + strings.Join(vals, "|") + `)\b`)
}

func containsAny(hay []string, needle string) bool {
	for _, h := range hay {
		if strings.Contains(h, needle) {
			return true
		}
	}
	return false
}

func sortedKeys(m map[string][]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// readTreeSource returns every line of every .go file under the repository,
// test files included. The corpus deliberately excludes _test.go because a
// parameter literal is not a citation, but for "does this symbol exist in the
// tree" the tests are exactly where a test function would live.
func readTreeSource(repo string) []string {
	var out []string
	_ = filepath.WalkDir(repo, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if d.Name() == ".git" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(p, ".go") {
			if lines, err := readLines(p); err == nil {
				out = append(out, lines...)
			}
		}
		return nil
	})
	return out
}

// isRunbook reports whether a path is a bundle's runbook. Clause 5 puts the
// reproduction cost in the runbook, so a runbook can cite a figure and is not
// itself raw output to be judged.
func isRunbook(workspace, path string) bool {
	r, err := filepath.Rel(workspace, path)
	if err != nil || !strings.Contains(r, string(filepath.Separator)) {
		return false // loose in the workspace root, so it belongs to no bundle
	}
	base := strings.ToUpper(filepath.Base(path))
	for _, n := range runbookNames {
		if strings.HasPrefix(base, n) {
			return true
		}
	}
	return false
}

// bundleOf returns the top level directory the artifact sits in, relative to
// the workspace, or "" when the artifact is loose in the workspace root.
func bundleOf(workspace, path string) string {
	r, err := filepath.Rel(workspace, path)
	if err != nil {
		return ""
	}
	parts := strings.Split(r, string(filepath.Separator))
	if len(parts) <= 1 {
		return ""
	}
	return parts[0]
}

func rel(base, p string) string {
	if r, err := filepath.Rel(base, p); err == nil {
		return r
	}
	return p
}
