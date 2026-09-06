package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/faultio"
)

// This file sweeps the point at which the power goes out and requires that
// every replica still boots. It exists because the durability arms of this tree
// ask their question at one moment, and the orderings inside the write path are
// invisible to a question asked once.
//
// It carries TWO scenarios, and the second one is the reason the file is worth
// its runtime. Both cut the power at every position of the write stream that
// follows the arming point, and both assert the same thing: a replica opens
// again from its own directory, or the sweep stops and names it.
//
// LOCKSTEP is one client write on three healthy replicas. It catches the
// ordering inside Storage.SaveHardState: move the f.Sync() behind the os.Rename
// that publishes the file and a cut in that window destroys the previous valid
// copy while leaving nothing readable in its place. Measured on 4 September
// 2026, all three forms of that mutation are caught. What no other arm sees is
// the form that MOVES the call: under it the four TestDropUnsynced arms of
// engine/raft and both TestQuorumPowerLoss arms stay green. Deleting the call
// outright, or leaving it in a branch that never runs, is also caught by
// TestDropUnsynced_HardStateSurvivesPowerLoss, so on those two forms this file
// is a second opinion rather than the only one.
//
// Those are the arms whose green is worth quoting, and the qualifier is not
// decoration. go list -deps says engine/persist cannot reach engine/raft at
// all, so its green under a mutation of engine/raft/storage.go is guaranteed by
// the dependency graph rather than earned by an assertion, and quoting it would
// pad the claim with a witness that cannot testify. The same test applies one
// floor over: under a mutation of engine/naylamp/node.go neither engine/raft
// nor engine/persist can reach the changed file, so all six TestDropUnsynced
// arms are blind to it by construction and only engine/naylamp and engine/dst
// can see it at all.
//
// CATCHING UP is the one that took a second look to find, and the road there is
// worth keeping because the first version of this file got it wrong. A probe
// over the lockstep scenario reported that no Ready ever carries a hard state
// whose commit reaches an entry that the same Ready is appending, and that was
// read as proof that reordering processReady could not hurt. The probe was
// right about the scenario and the scenario was the wrong one. In lockstep the
// leader cannot commit N until a follower has acknowledged it, so the MsgApp
// carrying N always carries Commit=N-1 and the window never opens. It opens
// when a replica is BEHIND: the leader committed N because the OTHER follower
// acknowledged it, and the catch-up MsgApp carries entries AND a commit that
// already covers them. Raft.handleApp caps the follower's commit at lastNew,
// the last index of the batch it just appended, and Raft.ready packs that hard
// state and those entries into one Ready. So the second scenario leaves one
// replica behind, heals the partition, and cuts the power during the catch-up.
//
// There is a second door into the same window and it needs no follower at all.
// A group of ONE is its own majority, so the Ready that appends an entry
// already carries the commit that covers it, and the window opens on every
// write rather than on a catch-up. A census on 5 September 2026 measured it:
// the window was open in all six of the Readys that carried entries, and under
// the reordering 3 of 6 cut positions leave the node unable to boot, against 0
// of 6 on the healthy tree. It is not an exotic shape either, since -peers
// defaults to the empty string in both binaries, so a group of one is what
// starts for anyone who does not pass the flag. The catching-up scenario below
// catches the mutation anyway, so this is not a coverage hole; what this file
// does NOT sweep is a cut at N=1, because its harness fixes three ids.
//
// Under the promised order that window is safe: the entries are made durable
// before the hard state that commits into them, so a cut anywhere leaves a
// durable commit no higher than the durable log. Move the AppendEntries block
// of processReady below the framing of rd.Msgs and below the rd.Committed loop
// and the two swap, the hard state commits past the durable tail, and
// Raft.Restore refuses the replica with "restored commit exceeds restored log".
//
// The red arms are not shipped. Reversing an order is a one-line edit to
// production code, and a knob that exists only to be broken does not belong in
// the tree. They are fired by hand against a copy and their output archived.
//
// WHAT THIS FILE DOES NOT ASSERT, said here rather than left to be discovered:
// it checks that a replica comes back, not that the data comes back. A defect
// that loses an acknowledged write while still booting passes this file
// untouched, and the arms that do ask for the data are the TestDropUnsynced and
// TestQuorumPowerLoss families.

// powerCutSweepSeed is fixed. What is worth sweeping is where the power goes
// out, and that is the loop; a seed loop would repeat the same interleaving.
const powerCutSweepSeed = 1

// TestPowerCutSweep_EveryReplicaStillBoots runs both scenarios.
func TestPowerCutSweep_EveryReplicaStillBoots(t *testing.T) {
	t.Run("lockstep", func(t *testing.T) { sweepPowerCut(t, lockstepScenario) })
	t.Run("catching-up", func(t *testing.T) { sweepPowerCut(t, catchUpScenario) })
}

// scenario drives a cluster from the arming point onward. It is called twice
// per sweep position: once with arm nil to count the write stream, and once
// with arm installed to cut the power inside it.
type scenario func(t *testing.T, c *powerLossCluster, lead cluster.NodeID, arm func())

// sweepPowerCut walks the cut point across the whole stream the scenario issues
// AFTER the arming point and requires every replica to boot at each position.
//
// The axis is measured from the arming point and not from the start of the run,
// and that distinction is the whole correctness of the sweep: ArmCrashAfter
// counts writes from the moment it is armed, so an axis taken from a full run
// would spend most of its positions past the end of the armed stream, arming
// nobody and asserting nothing. The first version of this file made exactly
// that mistake and nine of its fifteen positions were empty.
func sweepPowerCut(t *testing.T, run scenario) {
	t.Helper()
	writes := countWritesAfterArming(t, run)
	if writes < 2 {
		t.Fatalf("the scenario issued %d writes after the arming point, too few to sweep a cut point through", writes)
	}

	armed, tookBytes := 0, 0
	for k := 1; k <= writes; k++ {
		fired, removed, refused, who, err := runPowerCutAt(t, run, k)
		if fired > 0 {
			armed++
		}
		if removed > 0 {
			tookBytes++
		}
		if refused {
			// THE RUN STOPS HERE, and the count of positions that already
			// passed goes in the message so the position of the window is
			// known without walking the rest. The property is binary and one
			// counterexample settles it; continuing would spend minutes on a
			// tree already known to violate. Stopping at the first also makes
			// the arm print the same line every time, which is what lets a red
			// arm be cited by its line.
			t.Fatalf("cut point %d of %d: replica %d did not come back from a power cut: %v (positions that passed before it: %d, bytes this cut removed: %d)",
				k, writes, who, err, k-1, removed)
		}
	}

	// TWO guards, and each one retires a different way of being green for
	// nothing. Both were added after a review measured that the first version
	// was wide open in exactly the way its own message claimed to cover. The
	// floor under both is the check at the top of this function: an axis of
	// fewer than two positions stops before the loop, so neither equality
	// below can be satisfied by a sweep that walked nothing.
	//
	// The first requires the crash to have FIRED at every position, so a sweep
	// whose axis runs past the end of the armed stream fails instead of
	// reporting a wide green over runs where nobody was armed.
	if armed != writes {
		t.Fatalf("the crash fired at only %d of the %d positions swept: the axis does not match the stream it walks", armed, writes)
	}
	// The second requires the crash to have REMOVED BYTES at every position.
	// Firing is not enough: a cut policy that lands at the end of the file
	// fires and takes nothing, and measured against a policy degraded that way
	// the sweep passed green and wide under the SaveHardState reordering, so
	// the whole red arm of the lockstep scenario disappeared without a word.
	// A guard that counts firings while its message speaks of bytes is the
	// banner that names what it does not check.
	if tookBytes != writes {
		t.Fatalf("the cut removed bytes at only %d of the %d positions swept: the injector fired without taking anything and the green is empty", tookBytes, writes)
	}
	t.Logf("power cut at each of %d positions after the arming point, all of them fired and all of them removed bytes, and every replica booted every time", writes)
}

// countWritesAfterArming measures the axis: how many writes the busiest replica
// issues from the arming point to the end of the scenario.
func countWritesAfterArming(t *testing.T, run scenario) int {
	t.Helper()
	c := newPowerLossCluster(t, powerCutSweepSeed, func(d *faultio.Disk) faultio.Opener { return d.Opener() })
	lead := driveUntilLeader(t, c.nodes, c.ids, 300)

	at := map[cluster.NodeID]int{}
	run(t, c, lead, func() {
		for _, id := range c.ids {
			at[id] = c.disks[id].Writes()
		}
	})

	most := 0
	for _, id := range c.ids {
		if n := c.disks[id].Writes() - at[id]; n > most {
			most = n
		}
	}
	for _, id := range c.ids {
		if n, ok := c.nodes[id]; ok {
			if err := n.Close(); err != nil {
				t.Fatalf("close %d after the counting pass: %v", id, err)
			}
		}
	}
	return most
}

// runPowerCutAt drives one scenario with the power armed to go out at the k-th
// write after the arming point, then reopens every replica. It reports how many
// disks the crash fired on, how many bytes it removed, and the first replica
// that did not come back.
func runPowerCutAt(t *testing.T, run scenario, k int) (fired int, removed int64, refused bool, who cluster.NodeID, err error) {
	t.Helper()
	c := newPowerLossCluster(t, powerCutSweepSeed, func(d *faultio.Disk) faultio.Opener { return d.Opener() })
	lead := driveUntilLeader(t, c.nodes, c.ids, 300)

	run(t, c, lead, func() {
		for _, id := range c.ids {
			if aerr := c.disks[id].ArmCrashAfter(k, faultio.LoseAllUnsynced()); aerr != nil {
				t.Fatalf("cut point %d: arm %d: %v", k, id, aerr)
			}
		}
	})

	for _, id := range c.ids {
		if c.disks[id].Crashed() {
			fired++
		}
	}
	removed = c.cutPowerToAll(t)

	back, failed := c.reboot(t, powerCutSweepSeed)
	for _, id := range c.ids {
		if ferr, bad := failed[id]; bad {
			return fired, removed, true, id, ferr
		}
	}
	for _, n := range back {
		if cerr := n.Close(); cerr != nil {
			t.Fatalf("cut point %d: close a rebooted replica: %v", k, cerr)
		}
	}
	return fired, removed, false, 0, nil
}

// lockstepScenario arms and then drives one client write through a healthy
// group. An Upsert that fails is not asserted on: the power went out inside it,
// which is the point. What is asserted is what the machines hold afterwards.
func lockstepScenario(t *testing.T, c *powerLossCluster, lead cluster.NodeID, arm func()) {
	t.Helper()
	arm()
	if _, out, uerr := c.nodes[lead].Upsert(77, []float32{0, 1, 0}); uerr == nil {
		pumpDying(c.nodes, out, 4000)
	}
}

// catchUpScenario leaves one replica behind, then arms and heals. The writes
// commit on the other two, which are a majority of three, so the leader's
// commit index runs ahead of the isolated replica's log. Healing sends that
// replica a batch of entries together with a commit that already covers them,
// which is the shape that makes the order inside processReady load-bearing.
func catchUpScenario(t *testing.T, c *powerLossCluster, lead cluster.NodeID, arm func()) {
	t.Helper()

	behind := cluster.None
	for _, id := range c.ids {
		if id != lead {
			behind = id
			break
		}
	}
	if behind == cluster.None {
		t.Fatal("no follower to leave behind")
	}

	// The group minus the replica being starved. Frames addressed to it are
	// dropped because it is not in the map, which is how this harness models a
	// partition.
	rest := map[cluster.NodeID]*Node{}
	restIDs := make([]cluster.NodeID, 0, len(c.ids)-1)
	for _, id := range c.ids {
		if id == behind {
			continue
		}
		rest[id] = c.nodes[id]
		restIDs = append(restIDs, id)
	}

	for i := 0; i < 3; i++ {
		_, out, uerr := c.nodes[lead].Upsert(uint64(100+i), []float32{float32(i), 1, 0})
		if uerr != nil {
			t.Fatalf("upsert %d on the leader while %d is starved: %v", i, behind, uerr)
		}
		pump(t, rest, out, 4000)
		driveUntilConverged(t, rest, restIDs, 300)
	}

	// The starved replica must really be behind, or the healing carries nothing
	// and the sweep would walk an empty stream.
	if c.nodes[behind].LastIndex() >= c.nodes[lead].LastIndex() {
		t.Fatalf("replica %d is not behind: its log ends at %d and the leader's at %d",
			behind, c.nodes[behind].LastIndex(), c.nodes[lead].LastIndex())
	}

	arm()

	// Heal. The catch-up append is what carries entries and a commit that
	// covers them into the same Ready on the replica that was left behind.
	for r := 0; r < 300; r++ {
		pumpDying(c.nodes, tickAllDying(c.nodes, c.ids), 4000)
		if c.disks[behind].Crashed() {
			break
		}
	}
}

// tickAllDying ticks whatever is still alive and collects what it produced. It
// is the counterpart of pumpDying for the tick side: a node whose machine is
// gone stops answering instead of failing the test.
func tickAllDying(nodes map[cluster.NodeID]*Node, ids []cluster.NodeID) [][]byte {
	var msgs [][]byte
	for _, id := range ids {
		n, ok := nodes[id]
		if !ok {
			continue
		}
		out, err := n.Tick()
		if err != nil {
			continue
		}
		msgs = append(msgs, out...)
	}
	return msgs
}
