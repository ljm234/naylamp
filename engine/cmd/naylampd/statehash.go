package main

import (
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"

	"naylamp/engine/cluster"
	"naylamp/engine/naylamp"
	"naylamp/engine/raft"
)

// stateHashExitOK, stateHashExitFailed and stateHashExitUsage are the process
// exit codes state-hash returns, so a gate script reads the outcome from the
// status alone: 0 when a digest was produced, 1 when the copy could not be read,
// and 2 on a usage error. There is no red verdict here, because a digest on its
// own decides nothing; comparing digests across replicas is the caller's job.
const (
	stateHashExitOK     = 0
	stateHashExitFailed = 1
	stateHashExitUsage  = 2
)

// runStateHash opens a cold copy of one replica's durable state and prints the
// digest of the committed data it holds, so a gate can capture the same value on
// every replica and compare them.
//
// WHAT A MATCH PROVES, AND WHAT IT DOES NOT. Equal digests across replicas CATCH
// a divergence that survived to the end of the run. They do not PROVE State
// Machine Safety, and the difference is not a technicality. The digest covers
// the committed data and nothing else, so a replica that applied a divergent
// value at some index whose id a later committed upsert overwrote converges to a
// bit-identical digest; the divergence happened and left no trace here. State
// Machine Safety is a property of the whole EXECUTION, of every state the
// replicas passed through, and a digest read at the end sees only the last one.
// This is a monitor, not a demonstration.
//
// A second limit follows from where the digest is read. Under the deployment
// default there is no snapshot, so opening a data directory REBUILDS the state
// by replaying the durable log. A digest taken from a cold copy therefore
// attests that the durable logs replay to equal state, not what each replica
// actually applied while it was running. The seeded simulation remains the judge
// of that, and this command does not pretend otherwise.
//
// The directory must be a COPY, for the same reason verify-log demands one: the
// open path takes the segments read-write and truncates a torn tail, so it must
// never be pointed at an original a later step still needs.
func runStateHash(args []string) {
	fs := flag.NewFlagSet("state-hash", flag.ExitOnError)
	var id uint
	var peers, dir string
	var dim int
	fs.UintVar(&id, "id", 0, "this replica's id (required)")
	fs.StringVar(&peers, "peers", "", "other group members as id=addr,id=addr (addresses are ignored; only the ids shape the config)")
	fs.StringVar(&dir, "dir", "", "data directory to digest, a cold copy (required, opened read-write so never the original)")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylampd state-hash -id N -dir DIR [-peers id=addr,...] [-dim D]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "prints the committed-data digest of a cold copy; equal digests across replicas catch a surviving divergence, they do not prove state machine safety")
	}
	_ = fs.Parse(args)

	if id == 0 || dir == "" {
		fmt.Fprintln(os.Stderr, "state-hash: -id and -dir are required")
		fs.Usage()
		os.Exit(stateHashExitUsage)
	}

	nid := cluster.NodeID(id)
	cfg, err := configFromFlags(nid, peers)
	if err != nil {
		fmt.Fprintf(os.Stderr, "state-hash: bad -peers: %v\n", err)
		os.Exit(stateHashExitUsage)
	}

	line, ok := stateHashOf(dir, nid, cfg, dim)
	fmt.Println(line)
	if ok {
		os.Exit(stateHashExitOK)
	}
	os.Exit(stateHashExitFailed)
}

// stateHashOf opens the copy and returns the evidence line plus whether a digest
// was produced. It never exits, which keeps the core testable, and it prints the
// scope of the claim on the line itself so an operator reading the gate log is
// told what a match is worth without having to find this comment.
func stateHashOf(dir string, id cluster.NodeID, cfg cluster.Config, dim int) (string, bool) {
	// The directory must already exist. Opening a node CREATES one, so a typo in
	// a path would otherwise produce a fresh empty replica and report the digest
	// of nothing; two typos would report the SAME digest and read as agreement.
	// A digest whose whole purpose is cross-replica comparison must never
	// manufacture the thing it is comparing.
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		return fmt.Sprintf("state-hash: FAILED dir=%s replica=%d reason=no-such-directory; the copy must exist before it is read, or a mistyped path would be digested as an empty replica", dir, id), false
	}

	// A snapshot means the committed prefix was folded away, so two replicas
	// that compacted at different indices would hold the same data and could
	// still be read differently. verify-log refuses the same state for the same
	// reason, and refusing loudly beats reporting a digest whose scope is
	// unstated.
	if _, err := os.Stat(filepath.Join(dir, snapshotFileName)); err == nil {
		return fmt.Sprintf("state-hash: FAILED dir=%s replica=%d reason=snapshot-present; the log was compacted, so the digest would cover a different span than an uncompacted peer's. Re-run with compaction disabled (the deployment default).", dir, id), false
	}

	rng := rand.New(rand.NewPCG(uint64(id), 1)) //nolint:gosec // a fixed seed for a read-only audit; no election is driven here
	node, err := naylamp.OpenNode(dir, id, cfg, dim, rng, naylamp.NodeOptions{})
	if err != nil {
		if errors.Is(err, raft.ErrCorruptLog) || errors.Is(err, raft.ErrCorruptHardState) || errors.Is(err, raft.ErrCorruptSnapshot) {
			return fmt.Sprintf("state-hash: FAILED dir=%s replica=%d reason=corrupt-open: %v", dir, id, err), false
		}
		return fmt.Sprintf("state-hash: FAILED dir=%s replica=%d reason=open: %v", dir, id, err), false
	}
	defer func() { _ = node.Close() }()

	cmds, cerr := node.CommittedCommands()
	if cerr != nil {
		return fmt.Sprintf("state-hash: FAILED dir=%s replica=%d reason=decode: %v", dir, id, cerr), false
	}

	sum := node.StateHash()
	return fmt.Sprintf("state-hash: OK dir=%s replica=%d digest=%s committed_commands=%d; equal digests across replicas CATCH a divergence that survived to the final state, they do NOT prove state machine safety, and a digest read from a cold copy attests that the durable logs replay to equal state, not what a replica applied while running",
		dir, id, hex.EncodeToString(sum[:]), len(cmds)), true
}
