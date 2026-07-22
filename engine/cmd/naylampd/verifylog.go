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

// manifest is the oracle of what the client actually acked, reconstructed by the
// gate from the exit-0 client invocations, never from the log under audit. seen
// is every id the workload ever wrote (a put or a del), and live is the id to
// vector map that remains after the workload replays in order, so a put then a
// del of one id leaves it seen but not live. The faithful committed log must
// carry exactly this: no id outside seen (no phantoms), and a replay whose live
// set equals live (no gaps, and every value correct).
type manifest struct {
	seen map[uint64]bool
	live map[uint64][]float32
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
	// No phantoms: every committed id was written by the workload.
	for _, phantom := range sortedDiff(committedSeen, man.seen) {
		reasons = append(reasons, fmt.Sprintf("verify: phantom id=%d is committed but was never written by the workload", phantom))
	}
	// No gaps: every id the workload wrote is present in the committed record.
	for _, missing := range sortedDiff(man.seen, committedSeen) {
		reasons = append(reasons, fmt.Sprintf("verify: acked id=%d is in the workload but missing from the committed record", missing))
	}
	// Replay equals the oracle: the live set and every live value match.
	for _, id := range sortedKeys(man.live) {
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
		if _, ok := man.live[id]; !ok {
			reasons = append(reasons, fmt.Sprintf("verify: id=%d is live in the committed replay but not in the workload", id))
		}
	}

	if len(reasons) == 0 {
		return true, []string{fmt.Sprintf("verify: FAITHFUL dir=%s replica=%d committed_commands=%d seen=%d live=%d; no phantoms, no gaps, replay equals the workload live oracle (idempotent duplicates absorbed)", dir, id, len(cmds), len(committedSeen), len(committedLive))}
	}
	reasons = append(reasons, fmt.Sprintf("verify: NOT FAITHFUL dir=%s replica=%d committed_commands=%d; %d discrepancy(ies) above", dir, id, len(cmds), len(reasons)))
	return false, reasons
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

// readManifest parses the workload manifest: one operation per line, either
// "put <id> <f,f,f>" or "del <id>", processed in order so the live map reflects
// the final state. Blank lines and lines beginning with '#' are ignored, so the
// gate can annotate the file.
func readManifest(path string) (manifest, error) {
	f, err := os.Open(path) //nolint:gosec // path is an operator-provided manifest for a read-only audit, not untrusted input
	if err != nil {
		return manifest{}, err
	}
	defer func() { _ = f.Close() }()

	man := manifest{seen: map[uint64]bool{}, live: map[uint64][]float32{}}
	sc := bufio.NewScanner(f)
	line := 0
	for sc.Scan() {
		line++
		text := strings.TrimSpace(sc.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		fields := strings.Fields(text)
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
			man.seen[id] = true
			man.live[id] = vec
		case "del":
			if len(fields) != 2 {
				return manifest{}, fmt.Errorf("line %d: del needs exactly an id", line)
			}
			id, err := strconv.ParseUint(fields[1], 10, 64)
			if err != nil {
				return manifest{}, fmt.Errorf("line %d: bad id %q: %w", line, fields[1], err)
			}
			man.seen[id] = true
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
