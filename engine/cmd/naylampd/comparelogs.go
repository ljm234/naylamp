package main

import (
	"errors"
	"flag"
	"fmt"
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

// compareLogsExitMatch, compareLogsExitMismatch and compareLogsExitUsage are the
// exit codes compare-logs returns, so a gate script reads the verdict from the
// status alone: 0 when every replica agrees over the span they share, 1 when two
// of them disagree inside it or a copy could not be read, and 2 on a usage error.
const (
	compareLogsExitMatch    = 0
	compareLogsExitMismatch = 1
	compareLogsExitUsage    = 2
)

// replicaDir is one replica to read, its id paired with the cold copy of its
// data directory.
type replicaDir struct {
	id  cluster.NodeID
	dir string
}

// replicaDirFlag accumulates repeated -replica values, one id=dir each.
type replicaDirFlag []string

func (r *replicaDirFlag) String() string { return strings.Join(*r, ",") }

func (r *replicaDirFlag) Set(v string) error {
	*r = append(*r, v)
	return nil
}

// runCompareLogs reads the committed commands of two or more cold copies and
// checks that they agree over the span they share.
//
// WHAT IS COMPARED, EXACTLY. The unit is the client COMMAND STREAM, not the raft
// log. The read-only accessor hands back decoded client commands and drops the
// consensus no-ops, and it carries neither the term nor the index of the entry
// each came from. So this check falsifies a disagreement in what the replicas
// will apply, which is the consequence an operator cares about, and it CANNOT
// falsify Log Matching in the paper's sense: two replicas whose entry at one
// index differs only in its term, or where one holds a no-op the other does not,
// look identical here. Positions are reported as ordinals in the command stream
// for the same reason, and they will not line up with raft indices whenever a
// leader wrote a no-op. Naming that plainly costs nothing; discovering it while
// reading a green gate log costs a great deal.
//
// THE COMPARISON IS BOUNDED TO THE SPAN THE REPLICAS SHARE, and that bound is
// the whole design. Raft guarantees that two replicas holding an entry at the
// same index hold the SAME entry; it guarantees nothing about them holding the
// same NUMBER of entries at any given moment. A follower that was behind when
// the cluster was stopped has a shorter committed log and is perfectly correct.
// Comparing the logs whole would red on exactly that follower, so the check
// compares only up to the shortest log and reports every length beside the
// bound. A short shared span is not a failure, but it is information the gate
// should see: it says the replicas were far apart when they were captured, and a
// green verdict over three entries attests much less than one over three
// thousand.
func runCompareLogs(args []string) {
	fs := flag.NewFlagSet("compare-logs", flag.ExitOnError)
	var replicas replicaDirFlag
	var peers string
	var dim int
	fs.Var(&replicas, "replica", "one replica as id=dir, a cold copy (repeatable, at least two required)")
	fs.StringVar(&peers, "peers", "", "group members as id=addr,id=addr (addresses are ignored; only the ids shape the config)")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylampd compare-logs -replica id=dir -replica id=dir [-peers id=addr,...] [-dim D]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "compares committed logs over the span every replica shares; a shorter log is not a failure, a disagreement inside the shared span is")
	}
	_ = fs.Parse(args)

	if len(replicas) < 2 {
		fmt.Fprintln(os.Stderr, "compare-logs: at least two -replica flags are required; comparing one log against nothing decides nothing")
		fs.Usage()
		os.Exit(compareLogsExitUsage)
	}

	parsed, err := parseReplicaDirs(replicas)
	if err != nil {
		fmt.Fprintf(os.Stderr, "compare-logs: %v\n", err)
		os.Exit(compareLogsExitUsage)
	}

	ids := make([]cluster.NodeID, 0, len(parsed))
	for _, r := range parsed {
		ids = append(ids, r.id)
	}
	cfg, err := configForReplicas(ids, peers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "compare-logs: bad -peers: %v\n", err)
		os.Exit(compareLogsExitUsage)
	}

	match, lines := compareLogs(parsed, cfg, dim)
	for _, l := range lines {
		fmt.Println(l)
	}
	if match {
		os.Exit(compareLogsExitMatch)
	}
	os.Exit(compareLogsExitMismatch)
}

// compareLogs reads every copy and compares them over their shared span. It
// never exits, which keeps the core testable.
func compareLogs(replicas []replicaDir, cfg cluster.Config, dim int) (bool, []string) {
	var lines []string
	logs := make([][]naylamp.CommittedCommand, len(replicas))
	for i, r := range replicas {
		cmds, line, ok := readCommittedCopy(r, cfg, dim)
		if !ok {
			return false, append(lines, line, fmt.Sprintf("compare-logs: MISMATCH replicas=%d; a copy could not be read, so no comparison was made", len(replicas)))
		}
		logs[i] = cmds
	}

	// The shared span is the shortest log. Anything past it exists on some
	// replicas and not others, which is lag and not disagreement.
	shared := len(logs[0])
	for _, l := range logs[1:] {
		if len(l) < shared {
			shared = len(l)
		}
	}

	lengths := make([]string, len(replicas))
	for i, r := range replicas {
		lengths[i] = fmt.Sprintf("%d:%d", r.id, len(logs[i]))
	}
	lines = append(lines, fmt.Sprintf("compare-logs: spans replicas=%d shared_prefix=%d command_counts=%s; counts and positions are ordinals in the decoded client command stream, not raft indices, because consensus no-ops are not commands; the comparison covers the shared prefix only, because a shorter log is a replica that was behind when it was captured, not a replica that disagrees",
		len(replicas), shared, strings.Join(lengths, ",")))

	// Every replica is compared against the first, which is enough: agreement
	// with a common reference over the same span is agreement with each other.
	mismatches := 0
	for i := 1; i < len(logs); i++ {
		for k := 0; k < shared; k++ {
			a, b := logs[0][k], logs[i][k]
			if a.Op == b.Op && a.ID == b.ID && vecEqual(a.Vec, b.Vec) {
				continue
			}
			mismatches++
			lines = append(lines, fmt.Sprintf("compare-logs: replicas %d and %d disagree at command %d of the shared prefix: %s versus %s",
				replicas[0].id, replicas[i].id, k+1, describeCommand(a), describeCommand(b)))
			// One report per pair is enough to fail the check and name the
			// index; dumping every later entry buries the first divergence,
			// which is the one that matters.
			break
		}
	}

	if mismatches == 0 {
		if shared == 0 {
			lines = append(lines, fmt.Sprintf("compare-logs: MATCH replicas=%d shared_prefix=0; nothing was compared because at least one replica has an empty committed log, so this verdict attests nothing about agreement", len(replicas)))
			return true, lines
		}
		lines = append(lines, fmt.Sprintf("compare-logs: MATCH replicas=%d shared_prefix=%d; every replica carries the same command at every index of the span they share", len(replicas), shared))
		return true, lines
	}
	lines = append(lines, fmt.Sprintf("compare-logs: MISMATCH replicas=%d shared_prefix=%d; %d pair(s) disagree inside the span they share, which no amount of lag explains", len(replicas), shared, mismatches))
	return false, lines
}

// readCommittedCopy opens one cold copy and returns its committed commands. The
// refusals mirror verify-log exactly, because the two read the same durable
// state under the same constraints.
func readCommittedCopy(r replicaDir, cfg cluster.Config, dim int) ([]naylamp.CommittedCommand, string, bool) {
	// The directory must already exist, because opening a node creates one. A
	// mistyped path would otherwise read as an empty replica, which the shared
	// prefix would then bound to zero and the comparison would call a match.
	if info, err := os.Stat(r.dir); err != nil || !info.IsDir() {
		return nil, fmt.Sprintf("compare-logs: FAILED dir=%s replica=%d reason=no-such-directory; the copy must exist before it is read, or a mistyped path would be compared as an empty log", r.dir, r.id), false
	}
	if _, err := os.Stat(filepath.Join(r.dir, snapshotFileName)); err == nil {
		return nil, fmt.Sprintf("compare-logs: FAILED dir=%s replica=%d reason=snapshot-present; the committed prefix was folded away, so index k on this copy is not index k on an uncompacted peer and the comparison would be meaningless. Re-run with compaction disabled (the deployment default).", r.dir, r.id), false
	}
	rng := rand.New(rand.NewPCG(uint64(r.id), 1)) //nolint:gosec // a fixed seed for a read-only audit; no election is driven here
	node, err := naylamp.OpenNode(r.dir, r.id, cfg, dim, rng, naylamp.NodeOptions{})
	if err != nil {
		if errors.Is(err, raft.ErrCorruptLog) || errors.Is(err, raft.ErrCorruptHardState) || errors.Is(err, raft.ErrCorruptSnapshot) {
			return nil, fmt.Sprintf("compare-logs: FAILED dir=%s replica=%d reason=corrupt-open: %v", r.dir, r.id, err), false
		}
		return nil, fmt.Sprintf("compare-logs: FAILED dir=%s replica=%d reason=open: %v", r.dir, r.id, err), false
	}
	defer func() { _ = node.Close() }()

	cmds, cerr := node.CommittedCommands()
	if cerr != nil {
		return nil, fmt.Sprintf("compare-logs: FAILED dir=%s replica=%d reason=decode: %v", r.dir, r.id, cerr), false
	}
	return cmds, "", true
}

// describeCommand renders one committed command for an evidence line.
func describeCommand(c naylamp.CommittedCommand) string {
	if len(c.Vec) > 0 {
		return fmt.Sprintf("put id=%d vec=%v", c.ID, c.Vec)
	}
	return fmt.Sprintf("del id=%d", c.ID)
}

// parseReplicaDirs turns the repeated id=dir flags into replicas, rejecting both
// a repeated id and a repeated directory, so a typo cannot quietly compare one
// copy against itself. The directory matters as much as the id: two ids pointed
// at the same path agree perfectly and prove nothing, and unlike the empty case
// the shared prefix is nonzero, so the verdict reads as a genuine match.
func parseReplicaDirs(raw []string) ([]replicaDir, error) {
	out := make([]replicaDir, 0, len(raw))
	seenID := map[cluster.NodeID]bool{}
	seenDir := map[string]bool{}
	for _, r := range raw {
		eq := strings.IndexByte(r, '=')
		if eq <= 0 || eq == len(r)-1 {
			return nil, fmt.Errorf("bad -replica %q (want id=dir)", r)
		}
		id, err := strconv.ParseUint(r[:eq], 10, 64)
		if err != nil || id == 0 {
			return nil, fmt.Errorf("bad -replica %q: id must be a positive integer", r)
		}
		nid := cluster.NodeID(id)
		if seenID[nid] {
			return nil, fmt.Errorf("replica id %d given twice; comparing a copy against itself proves nothing", id)
		}
		dir := filepath.Clean(r[eq+1:])
		if seenDir[dir] {
			return nil, fmt.Errorf("directory %s given twice; comparing a copy against itself proves nothing", dir)
		}
		seenID[nid], seenDir[dir] = true, true
		out = append(out, replicaDir{id: nid, dir: dir})
	}
	return out, nil
}

// configForReplicas builds the group config from the replica ids plus any extra
// peers named on the flag, so a copy whose group had members this run does not
// name still opens against the membership it was written under.
func configForReplicas(ids []cluster.NodeID, peers string) (cluster.Config, error) {
	peerList, err := parseNodeList(peers)
	if err != nil {
		return cluster.Config{}, err
	}
	all := map[cluster.NodeID]bool{}
	for _, id := range ids {
		all[id] = true
	}
	for _, p := range peerList {
		all[p.id] = true
	}
	ordered := make([]cluster.NodeID, 0, len(all))
	for id := range all {
		ordered = append(ordered, id)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i] < ordered[j] })
	members := make([]cluster.NodeAddr, len(ordered))
	for i, id := range ordered {
		members[i] = cluster.NodeAddr{ID: id}
	}
	return cluster.Config{Nodes: members}, nil
}
