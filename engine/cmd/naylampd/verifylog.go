package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"naylamp/engine/cluster"
	"naylamp/engine/naylamp"
	"naylamp/engine/raft"
)

// snapshotFileName is the durable snapshot file the raft storage writes. It is
// named here, not imported, because the storage layer keeps the constant
// unexported; the verifier only needs to notice its presence and refuse to run
// (see the compaction guard in verifyLog).
const snapshotFileName = "raft-snapshot"

// verifyExitFaithful, verifyExitNotFaithful and verifyExitUsage are the process
// exit codes verify-log returns, so a gate script reads the verdict from the
// status alone: 0 when the copy is faithful, 1 when it is not (including a
// refusal to run or a log it cannot open), and 2 on a usage error.
const (
	verifyExitFaithful    = 0
	verifyExitNotFaithful = 1
	verifyExitUsage       = 2
)

// manifest is the oracle of what the client emitted, reconstructed by the gate
// from the client invocations, never from the log under audit.
//
// An operation carries one of three standings, because under a real failure the
// client's exit code does not divide the world in two. CONFIRMED means the
// client was answered: the operation is committed, so its absence from the log
// is an acknowledged write that was lost, and that is red. UNCERTAIN means the
// client got no answer and cannot know whether the operation ran: both its
// presence and its absence are correct, so neither is red. Anything the client
// never emitted at all is in neither set, and its presence in the log is a
// phantom, which stays red.
//
// The middle case is not hypothetical. The first hardware gate recorded a client
// reporting a timeout under a partition while the operation had in fact
// executed; a manifest built only from the answered operations omits it, and a
// two-state checker then calls a correct entry a phantom. Grading a real run
// needs the third standing or it reds for the wrong reason.
//
// seen is every id the workload emitted under either standing, so an uncertain
// id is never mistaken for a phantom. confirmed is the ids with at least one
// answered operation, and those are the ones whose absence is a verdict.
// ambiguous is the ids any uncertain operation touched: their final value cannot
// be predicted, so the replay comparison skips them in both directions and
// reports them as a count instead. live is the id to vector map left by
// replaying every operation in order, which is exact for an id no uncertain
// operation touched, and those are the only ids it is read for.
//
// DECLARED BLIND SPOT, and it is wider than one case. Once an unanswered
// operation touches an id, that id's VALUE is no longer checked in either
// direction, so anything the log says about it is accepted: a value no client
// ever proposed, a delete the workload never emitted, or an answered write that
// was lost and whose id survives only because the unanswered one landed. The
// oracle is keyed by id rather than by entry, and an unanswered operation makes
// the id's final content genuinely unpredictable, so suppressing the comparison
// is correct; what it costs is every other claim about that id.
//
// Presence is still enforced, so an id with any answered operation must appear.
// The gate closes most of the gap by choosing its workload: keep unanswered
// operations on ids of their own, and every id that carries an answered
// operation stays fully checked. Narrowing it inside the checker would need
// per-entry identity on the wire, which the client does not carry today, or a
// membership test against the values the manifest actually wrote, which is
// possible and deliberately not done here so the rule stays one sentence. The
// limit is pinned by a test so it stays a known shape rather than a surprise.
type manifest struct {
	seen      map[uint64]bool
	live      map[uint64][]float32
	confirmed map[uint64]bool
	ambiguous map[uint64]bool
}

// confirmedIDs returns the ids whose absence is a verdict. A manifest written
// before the standings existed carries no confirmed set, and every operation in
// it was an answered one, so the whole of seen is confirmed. That is what keeps
// an older manifest reading exactly as it did.
func (m manifest) confirmedIDs() map[uint64]bool {
	if m.confirmed == nil {
		return m.seen
	}
	return m.confirmed
}

// isAmbiguous reports whether an uncertain operation touched this id, in which
// case its final value is not predictable and no verdict is taken from it.
func (m manifest) isAmbiguous(id uint64) bool { return m.ambiguous[id] }

// note records one operation against an id. An id stays confirmed once any
// answered operation named it, because that entry is committed whatever a later
// unanswered operation did, and it becomes ambiguous once any unanswered one
// named it, because its final value can no longer be predicted. The two are not
// exclusive: an id can be required to be present and still have an unpredictable
// value, which is exactly the case a confirmed put followed by an unanswered
// overwrite produces.
func (m manifest) note(id uint64, uncertain bool) {
	m.seen[id] = true
	if uncertain {
		m.ambiguous[id] = true
		return
	}
	m.confirmed[id] = true
}

// splitStanding peels an optional trailing standing marker off a manifest line
// and reports whether it said the operation was unanswered. A line with no
// marker is confirmed, which is what makes an older manifest parse unchanged. A
// trailing word that is neither marker is left in place on purpose, because a
// put's last field is its vector and the two cannot be told apart here; it then
// fails the arity check the caller applies, so a typo is rejected there rather
// than swallowed as a standing.
func splitStanding(fields []string) ([]string, bool, error) {
	if len(fields) == 0 {
		return fields, false, errors.New("empty operation")
	}
	uncertain := false
	switch fields[len(fields)-1] {
	case standingConfirmed:
		fields = fields[:len(fields)-1]
	case standingUncertain:
		fields, uncertain = fields[:len(fields)-1], true
	default:
		return fields, false, nil
	}
	// Stripping the marker is what can empty the line, so the check belongs
	// here and not before: a line carrying nothing but a standing names no
	// operation, and it must be reported as such rather than indexed into.
	if len(fields) == 0 {
		return fields, false, errors.New("a standing with no operation")
	}
	return fields, uncertain, nil
}

// runVerifyLog reads a cold copy of one replica's durable state and checks that
// its committed log is a faithful record of a known workload: no phantom ids, no
// missing acked ids, and a replay whose live set equals the workload's live
// oracle, with idempotent duplicates absorbed exactly as apply absorbs them. It
// is a read-only audit of a copy (Subphase 4.2, DEFER-013): it opens the dir
// through the same OpenNode a restart uses and reads the committed commands
// through the existing read-only accessor, proposing nothing and serving no
// client. The dir must be a COPY: OpenNode opens the segments O_RDWR and truncates
// a torn tail, so it must never be pointed at an original a later step still
// needs. Corruption before the final segment surfaces as an open error, which is
// itself a not-faithful verdict.
func runVerifyLog(args []string) {
	fs := flag.NewFlagSet("verify-log", flag.ExitOnError)
	var id uint
	var peers, dir, manifestPath string
	var dim int
	fs.UintVar(&id, "id", 0, "this replica's id (required)")
	fs.StringVar(&peers, "peers", "", "other group members as id=addr,id=addr (addresses are ignored; only the ids shape the config)")
	fs.StringVar(&dir, "dir", "", "data directory to audit, a cold copy (required, opened read-write so never the original)")
	fs.StringVar(&manifestPath, "manifest", "", "the workload manifest of acked client operations (required)")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylampd verify-log -id N -dir DIR -manifest FILE [-peers id=addr,...] [-dim D]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "audits a cold copy of a replica's committed log against the workload manifest; exit 0 faithful, 1 not, 2 usage")
	}
	_ = fs.Parse(args)

	if id == 0 || dir == "" || manifestPath == "" {
		fmt.Fprintln(os.Stderr, "verify-log: -id, -dir, and -manifest are required")
		fs.Usage()
		os.Exit(verifyExitUsage)
	}

	man, err := readManifest(manifestPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "verify-log: read manifest: %v\n", err)
		os.Exit(verifyExitUsage)
	}

	nid := cluster.NodeID(id)
	cfg, err := configFromFlags(nid, peers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "verify-log: bad -peers: %v\n", err)
		os.Exit(verifyExitUsage)
	}

	faithful, reasons := verifyLog(dir, nid, cfg, dim, man)
	for _, r := range reasons {
		fmt.Println(r)
	}
	if faithful {
		os.Exit(verifyExitFaithful)
	}
	os.Exit(verifyExitNotFaithful)
}

// verifyLog performs the audit and returns whether the copy is faithful plus the
// evidence lines to print. It never exits: the caller maps the verdict to a
// status code, which keeps this core reusable and testable.
func verifyLog(dir string, id cluster.NodeID, cfg cluster.Config, dim int, man manifest) (bool, []string) {
	// Compaction must be off for the audit to be sound. A durable snapshot means
	// the committed prefix was folded away, so the phantom and gap checks would
	// see only the post-snapshot suffix and could call a truncated log faithful.
	// Refuse loudly rather than audit a partial view. The deployment default
	// (NodeOptions{}, CompactEvery 0) never writes one, so its presence is a
	// misconfiguration, not a normal state.
	if _, err := os.Stat(filepath.Join(dir, snapshotFileName)); err == nil {
		return false, []string{fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d reason=snapshot-present; the committed log was compacted, so the audit would scope only to the post-snapshot suffix and cannot attest the whole record. Re-run with compaction disabled (the deployment default).", dir, id)}
	}

	rng := rand.New(rand.NewPCG(uint64(id), 1)) //nolint:gosec // a fixed seed for a read-only audit; the index seed is constant and no election is driven here
	node, err := naylamp.OpenNode(dir, id, cfg, dim, rng, naylamp.NodeOptions{})
	if err != nil {
		// Damage before the final segment, an unreadable hard state, or an
		// unreadable snapshot all surface here. That the durable log cannot be
		// opened is itself a not-faithful verdict, so the check reports it red
		// rather than aborting.
		if errors.Is(err, raft.ErrCorruptLog) || errors.Is(err, raft.ErrCorruptHardState) || errors.Is(err, raft.ErrCorruptSnapshot) {
			return false, []string{fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d reason=corrupt-open: %v; the durable log did not open cleanly, which the check counts as a corruption red.", dir, id, err)}
		}
		return false, []string{fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d reason=open: %v", dir, id, err)}
	}
	defer func() { _ = node.Close() }()

	cmds, err := node.CommittedCommands()
	if err != nil {
		// A committed entry that does not decode is corruption or version skew,
		// the same red as a failed open.
		return false, []string{fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d reason=decode: %v; a committed entry did not decode, which the check counts as a corruption red.", dir, id, err)}
	}

	// Replay the committed commands exactly as apply would: a put sets the id's
	// vector, a delete removes it, and a duplicate is absorbed because replaying
	// the same put leaves the same value. seen accumulates every id, so a phantom
	// that was never in the workload still appears here to be caught.
	committedSeen := make(map[uint64]bool, len(cmds))
	committedLive := make(map[uint64][]float32, len(cmds))
	for _, c := range cmds {
		committedSeen[c.ID] = true
		if len(c.Vec) > 0 { // an upsert carries a vector; a delete carries none
			committedLive[c.ID] = c.Vec
		} else {
			delete(committedLive, c.ID)
		}
	}

	var reasons []string
	// No phantoms: every committed id was emitted by the workload under one
	// standing or the other. seen carries both, so an unanswered operation that
	// did commit is not mistaken for an id nobody ever wrote.
	for _, phantom := range sortedDiff(committedSeen, man.seen) {
		reasons = append(reasons, fmt.Sprintf("verify: phantom id=%d is committed but was never emitted by the workload", phantom))
	}
	// No lost acknowledged writes: every id the client was ANSWERED about is
	// present. An unanswered one is not required, because its absence is a
	// legitimate outcome of the failure the gate injected.
	for _, missing := range sortedDiff(man.confirmedIDs(), committedSeen) {
		reasons = append(reasons, fmt.Sprintf("verify: acknowledged id=%d is in the workload but missing from the committed record", missing))
	}
	// Replay equals the oracle, for the ids whose value the oracle can predict.
	// An id an unanswered operation touched has no predictable final value, so
	// it is counted below instead of judged here.
	for _, id := range sortedKeys(man.live) {
		if man.isAmbiguous(id) {
			continue
		}
		got, ok := committedLive[id]
		if !ok {
			reasons = append(reasons, fmt.Sprintf("verify: id=%d is live in the workload but not in the committed replay", id))
			continue
		}
		if !vecEqual(got, man.live[id]) {
			reasons = append(reasons, fmt.Sprintf("verify: id=%d replays to %v but the workload wrote %v", id, got, man.live[id]))
		}
	}
	for _, id := range sortedKeys(committedLive) {
		if man.isAmbiguous(id) {
			continue
		}
		if _, ok := man.live[id]; !ok {
			reasons = append(reasons, fmt.Sprintf("verify: id=%d is live in the committed replay but not in the workload", id))
		}
	}

	// The ids an unanswered operation touched are reported, never judged. The
	// counters are per ID and not per operation, which matters when reading
	// them: three unanswered writes to one id count once, and an id that also
	// carries an answered write counts as present because that entry is there,
	// whatever became of the unanswered one. What the pair measures is how many
	// of the uncertain ids ended up in the log at all, which is a fact about the
	// run the gate wants recorded even though it decides nothing: a partition
	// that left every uncertain write committed tells a different story from one
	// that lost them all, and neither is a failure of this replica.
	uncertainPresent, uncertainAbsent := 0, 0
	for _, id := range sortedIDs(man.ambiguous) {
		if committedSeen[id] {
			uncertainPresent++
		} else {
			uncertainAbsent++
		}
	}
	standing := fmt.Sprintf("uncertain_ids_present=%d uncertain_ids_absent=%d", uncertainPresent, uncertainAbsent)

	if len(reasons) == 0 {
		return true, []string{fmt.Sprintf("verify: FAITHFUL dir=%s replica=%d committed_commands=%d seen=%d live=%d %s; no phantoms, no lost acknowledged writes, replay equals the workload live oracle (idempotent duplicates absorbed, unanswered operations counted not judged)", dir, id, len(cmds), len(committedSeen), len(committedLive), standing)}
	}
	reasons = append(reasons, fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d committed_commands=%d %s; %d discrepancy(ies) above", dir, id, len(cmds), standing, len(reasons)))
	return false, reasons
}

// sortedIDs returns the keys of an id set in ascending order, so evidence lines
// and counts come out in a stable order across runs.
func sortedIDs(m map[uint64]bool) []uint64 {
	out := make([]uint64, 0, len(m))
	for id := range m {
		out = append(out, id)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// configFromFlags builds the group config from this id and the peer list, exactly
// as the node subcommand does: the ids ascend and the addresses stay empty
// because the audit dials no one. Only the membership matters, so the core can be
// constructed to read the restored committed log.
func configFromFlags(self cluster.NodeID, peers string) (cluster.Config, error) {
	peerList, err := parseNodeList(peers)
	if err != nil {
		return cluster.Config{}, err
	}
	ids := []cluster.NodeID{self}
	for _, p := range peerList {
		ids = append(ids, p.id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	members := make([]cluster.NodeAddr, len(ids))
	for i, mid := range ids {
		members[i] = cluster.NodeAddr{ID: mid}
	}
	return cluster.Config{Nodes: members}, nil
}

// standingConfirmed and standingUncertain are the words a manifest line may end
// with to declare whether the client was answered. The marker is optional and
// its absence means confirmed, so a manifest written before the standings
// existed parses to exactly the same oracle it always did.
const (
	standingConfirmed = "confirmed"
	standingUncertain = "uncertain"
)

// readManifest parses the workload manifest: one operation per line, either
// "put <id> <f,f,f>" or "del <id>", optionally followed by "confirmed" or
// "uncertain", processed in order so the live map reflects the final state. A
// line with no marker is confirmed. Blank lines and lines beginning with '#'
// are ignored, so the gate can annotate the file.
func readManifest(path string) (manifest, error) {
	f, err := os.Open(path) //nolint:gosec // path is an operator-provided manifest for a read-only audit, not untrusted input
	if err != nil {
		return manifest{}, err
	}
	defer func() { _ = f.Close() }()

	man := manifest{
		seen:      map[uint64]bool{},
		live:      map[uint64][]float32{},
		confirmed: map[uint64]bool{},
		ambiguous: map[uint64]bool{},
	}
	sc := bufio.NewScanner(f)
	line := 0
	for sc.Scan() {
		line++
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		fields := strings.Fields(text)
		fields, uncertain, serr := splitStanding(fields)
		if serr != nil {
			return manifest{}, fmt.Errorf("line %d: %w", line, serr)
		}
		switch fields[0] {
		case "put":
			if len(fields) != 3 {
				return manifest{}, fmt.Errorf("line %d: put needs an id and a vector", line)
			}
			id, err := strconv.ParseUint(fields[1], 10, 64)
			if err != nil {
				return manifest{}, fmt.Errorf("line %d: bad id %q: %w", line, fields[1], err)
			}
			vec, err := parseManifestVec(fields[2])
			if err != nil {
				return manifest{}, fmt.Errorf("line %d: %w", line, err)
			}
			man.note(id, uncertain)
			man.live[id] = vec
		case "del":
			if len(fields) != 2 {
				return manifest{}, fmt.Errorf("line %d: del needs exactly an id", line)
			}
			id, err := strconv.ParseUint(fields[1], 10, 64)
			if err != nil {
				return manifest{}, fmt.Errorf("line %d: bad id %q: %w", line, fields[1], err)
			}
			man.note(id, uncertain)
			delete(man.live, id)
		default:
			return manifest{}, fmt.Errorf("line %d: unknown operation %q (want put or del)", line, fields[0])
		}
	}
	if err := sc.Err(); err != nil {
		return manifest{}, err
	}
	return man, nil
}

// parseManifestVec parses a comma-separated float32 vector, the same lexical form
// the client takes for -vec, so the manifest value and the committed value are
// compared on identical bits.
func parseManifestVec(s string) ([]float32, error) {
	parts := strings.Split(s, ",")
	vec := make([]float32, 0, len(parts))
	for _, p := range parts {
		v, err := strconv.ParseFloat(strings.TrimSpace(p), 32)
		if err != nil {
			return nil, fmt.Errorf("bad vector component %q: %w", p, err)
		}
		vec = append(vec, float32(v))
	}
	if len(vec) == 0 {
		return nil, errors.New("empty vector")
	}
	return vec, nil
}

// vecEqual compares two float32 vectors on exact bits. The command codec preserves
// float bits, and the manifest is parsed as float32, so a faithful value matches
// bit for bit; anything else is a real divergence, not a rounding artifact.
func vecEqual(a, b []float32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if math.Float32bits(a[i]) != math.Float32bits(b[i]) {
			return false
		}
	}
	return true
}

// sortedDiff returns the keys present in a but not in b, ascending, so the
// evidence lines are deterministic regardless of map order.
func sortedDiff(a, b map[uint64]bool) []uint64 {
	var out []uint64
	for k := range a {
		if !b[k] {
			out = append(out, k)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

// sortedKeys returns a live map's ids ascending, for deterministic iteration.
func sortedKeys(m map[uint64][]float32) []uint64 {
	out := make([]uint64, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
