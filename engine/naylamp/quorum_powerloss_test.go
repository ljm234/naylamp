package naylamp

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/faultio"
	"naylamp/engine/raft"
)

// This file is the deterministic stand-in for cutting the power to a rack.
//
// The hardware arm it replaces is a sysrq-b over a quorum of Azure VMs, and
// that arm is NOT deterministic and cannot be made so. What survives a real
// power cut is decided by the operating system's writeback and by the drive's
// own cache, both outside the process, so the same run can end in the loss it
// was built to show or in a cluster that simply refuses to come up, depending
// on where the writeback happened to be. The layer under this test lives inside
// the process and models the fsync boundary exactly, so the same scenario
// resolves the same way every time. The hardware arm keeps its place as
// corroboration, with an observation rate reported rather than a verdict
// claimed.
//
// One node losing power proves nothing here: replication repairs it. So the
// power goes out on all three replicas, which is the only reading of a
// rack-level failure where the acknowledged write has nowhere to hide.
//
// The red arm does not end where a reader expects. A cluster whose barrier does
// nothing does not come back missing the write. It comes back refusing to start.
// WHICH refusal is the part this header got wrong for a month, and it is
// corrected here rather than left for the body to contradict twenty lines down:
// it said "restored commit exceeds restored log", and measured on 5 September
// 2026 all three replicas refuse with raft.ErrCorruptHardState instead. The
// reasoning behind the wrong name is kept because it explains the shape: the
// hard state is replaced through a temp file that is fsynced and renamed, and a
// rename is followed by identity rather than by name, so what survives is a
// hard state whose bytes never crossed. ~~Both branches are the absence of
// durability, so the red arm accepts either~~ is what this header said until 5
// September 2026, and the body stopped doing it that day: the refusal is checked
// by identity against raft.ErrCorruptHardState, and the other branch fails the
// arm instead of being accepted, because it has no sentinel to check against and
// this scenario does not produce it. That is the same dichotomy the claim audit named
// as the reason the hardware arm is probabilistic, loss or a cluster that will
// not come up, except that here it lands on the same branch every run. ~~Both
// branches are the absence of durability, so the red arm accepts either and
// reports which one it got.~~ Both branches would be the absence of durability,
// but the arm accepts only the one this scenario produces and checks it by
// identity; and it reports counts rather than which branch it got, because the
// branch is fixed and the counts are what the control has to differ from.

// powerLossCluster is one three-replica group whose nodes each sit on their own
// simulated disk.
type powerLossCluster struct {
	ids   []cluster.NodeID
	cfg   cluster.Config
	dirs  map[cluster.NodeID]string
	disks map[cluster.NodeID]*faultio.Disk
	nodes map[cluster.NodeID]*Node
}

// newPowerLossCluster opens three replicas over fresh directories, each behind
// its own simulated disk, wrapped by mkOpener, which is where a red arm inserts
// its sabotage.
func newPowerLossCluster(t *testing.T, seed uint64, mkOpener func(*faultio.Disk) faultio.Opener) *powerLossCluster {
	t.Helper()
	c := &powerLossCluster{
		ids:   []cluster.NodeID{1, 2, 3},
		cfg:   cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}},
		dirs:  map[cluster.NodeID]string{},
		disks: map[cluster.NodeID]*faultio.Disk{},
		nodes: map[cluster.NodeID]*Node{},
	}
	for _, id := range c.ids {
		c.dirs[id] = t.TempDir()
		disk := faultio.NewDisk(faultio.SyncFsync)
		c.disks[id] = disk
		n, err := OpenNode(c.dirs[id], id, c.cfg, 3, testRNG(seed*0x100000001B3+uint64(id)), NodeOptions{Opener: mkOpener(disk)})
		if err != nil {
			t.Fatalf("seed %d: open %d: %v", seed, id, err)
		}
		c.nodes[id] = n
	}
	return c
}

// armFollowers sets every replica except the leader to lose power on its next
// write. Arming the leader as well would end the scenario too early: it dies on
// its own append, the round never reaches anyone else, and the only unsynced
// bytes on the floor are its own. Letting the leader replicate first and killing
// each follower inside its own append is the closer model of a rack going dark,
// where every machine dies at its own point in its own write stream.
func (c *powerLossCluster) armFollowers(t *testing.T, leader cluster.NodeID) {
	t.Helper()
	for _, id := range c.ids {
		if id == leader {
			continue
		}
		if err := c.disks[id].ArmCrashAfter(1, faultio.LoseAllUnsynced()); err != nil {
			t.Fatalf("arm %d: %v", id, err)
		}
	}
}

// cutPowerToAll takes down whatever is still running and returns how many bytes
// the cut removed across the group. Nothing is closed first: a power cut does
// not run shutdown code.
func (c *powerLossCluster) cutPowerToAll(t *testing.T) int64 {
	t.Helper()
	var cut int64
	for _, id := range c.ids {
		if !c.disks[id].Crashed() {
			if err := c.disks[id].Crash(faultio.LoseAllUnsynced()); err != nil {
				t.Fatalf("cut power to %d: %v", id, err)
			}
		}
		cut += c.disks[id].BytesCut()
	}
	return cut
}

// reboot opens every replica again from the same directories over ordinary
// files, which is what a machine coming back up does, and returns whatever each
// one did: a node, or the error that stopped it.
func (c *powerLossCluster) reboot(t *testing.T, seed uint64) (map[cluster.NodeID]*Node, map[cluster.NodeID]error) {
	t.Helper()
	back := map[cluster.NodeID]*Node{}
	failed := map[cluster.NodeID]error{}
	for _, id := range c.ids {
		n, err := OpenNode(c.dirs[id], id, c.cfg, 3, testRNG(seed*0x100000001B3+uint64(id)+1), NodeOptions{})
		if err != nil {
			failed[id] = err
			continue
		}
		back[id] = n
	}
	return back, failed
}

// commitOneWrite drives the group to a leader and acknowledges one upsert
// through it. Acknowledgement is the observable one: the leader answers a query
// with the vector, which it can only do once the entry committed and applied.
func commitOneWrite(t *testing.T, c *powerLossCluster, id uint64, vec []float32) {
	t.Helper()
	lead := driveUntilLeader(t, c.nodes, c.ids, 300)
	_, out, err := c.nodes[lead].Upsert(id, vec)
	if err != nil {
		t.Fatalf("upsert on leader %d: %v", lead, err)
	}
	pump(t, c.nodes, out, 4000)
	if !driveUntilConverged(t, c.nodes, c.ids, 300) {
		t.Fatal("the group did not converge before the power cut")
	}
	res, serr := c.nodes[lead].Search(vec, 1)
	if serr != nil {
		t.Fatalf("search on leader %d: %v", lead, serr)
	}
	if len(res) != 1 || res[0].ID != id {
		t.Fatalf("the write was never acknowledged: leader %d answered %+v", lead, res)
	}
}

// pumpDying routes frames through a group that is losing power. A node whose
// machine is gone stops answering instead of failing the test, which is what
// makes this different from pump.
func pumpDying(nodes map[cluster.NodeID]*Node, seed [][]byte, budget int) {
	queue := append([][]byte(nil), seed...)
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			continue
		}
		dst, ok := nodes[env.To]
		if !ok {
			continue
		}
		out, herr := dst.HandleMessage(data)
		if herr != nil {
			continue
		}
		queue = append(queue, out...)
	}
}

// TestQuorumPowerLoss_AcknowledgedWriteSurvives is the positive arm and the one
// that carries the claim. A first write is acknowledged and fully durable, then
// the power goes out across all three replicas in the middle of a second write,
// so there is genuinely unsynced data on the floor. The acknowledged write has
// to come back. The second one is not asserted on at all: it was never
// acknowledged, so its outcome is undefined and demanding either result would
// be inventing a claim.
func TestQuorumPowerLoss_AcknowledgedWriteSurvives(t *testing.T) {
	const seed = 1
	plain := func(d *faultio.Disk) faultio.Opener { return d.Opener() }
	c := newPowerLossCluster(t, seed, plain)

	const ackedID = uint64(42)
	ackedVec := []float32{1, 0, 0}
	commitOneWrite(t, c, ackedID, ackedVec)

	// The second write is what puts unsynced bytes on the floor: the leader
	// replicates it, and each follower dies inside its own append, before the
	// fsync that would have made it durable.
	lead := leaderOf(c.nodes, c.ids)
	c.armFollowers(t, lead)
	if _, out, err := c.nodes[lead].Upsert(uint64(43), []float32{0, 1, 0}); err == nil {
		pumpDying(c.nodes, out, 4000)
	}

	cut := c.cutPowerToAll(t)
	if cut == 0 {
		t.Fatal("the power cut removed nothing: there was no unsynced data to lose and the green would be empty")
	}
	// Where the fault landed is stated, not inferred from a byte count. It has
	// to be the Raft entry log on at least a quorum, because that is the file
	// an acknowledged client write lives in; unsynced bytes lost anywhere else
	// would leave this arm asserting survival against a fault that never
	// threatened it.
	downWithLogLoss := 0
	for _, id := range c.ids {
		for _, path := range c.disks[id].CutPaths() {
			if name := filepath.Base(path); strings.HasPrefix(name, "raft-") && strings.HasSuffix(name, ".log") {
				downWithLogLoss++
				break
			}
		}
	}
	if downWithLogLoss < 2 {
		t.Fatalf("only %d replicas lost unsynced entry-log bytes, which is not a quorum losing anything", downWithLogLoss)
	}
	t.Logf("power cut removed %d unsynced bytes, from the entry log of %d of the 3 replicas", cut, downWithLogLoss)

	back, failed := c.reboot(t, seed)
	defer func() {
		for _, n := range back {
			_ = n.Close()
		}
	}()
	for id, err := range failed {
		t.Fatalf("replica %d did not come back: %v", id, err)
	}

	// Every replica has to carry it durably, not merely enough of them. A write
	// that came back on one node would leave the cluster one failure away from
	// losing it for good.
	survivors := 0
	for _, id := range c.ids {
		if hasID(t, back[id], ackedID) {
			survivors++
		}
	}
	if survivors != 3 {
		t.Fatalf("the acknowledged write came back on %d of 3 replicas, expected all three", survivors)
	}

	// End to end: the group elects again and answers for the write, which is
	// what a client would observe once the lights come back.
	newLead := driveUntilLeader(t, back, c.ids, 300)
	res, err := back[newLead].Search(ackedVec, 1)
	if err != nil {
		t.Fatalf("search after reboot on leader %d: %v", newLead, err)
	}
	if len(res) != 1 || res[0].ID != ackedID {
		t.Fatalf("the rebooted group lost the acknowledged write: leader %d answered %+v", newLead, res)
	}
}

// runUnderBarrier drives the scenario once under the barrier its opener gives it and
// reports what the machines held afterwards: how many replicas refused to start,
// how many came back without the acknowledged write, how many came back with it,
// and how many bytes the cut removed.
//
// Both sides of the red arm below go through here, so the only thing that
// differs between them is the barrier. A control built out of a gentler scenario
// would not be a control: it would be a different experiment quoted as one.
func runUnderBarrier(t *testing.T, seed uint64, ackedID uint64, vec []float32, mk func(*faultio.Disk) faultio.Opener) (kept, refused, lost int, cut int64, failedIDs []cluster.NodeID, failed map[cluster.NodeID]error) {
	t.Helper()
	c := newPowerLossCluster(t, seed, mk)
	commitOneWrite(t, c, ackedID, vec)

	// The second write is what puts unsynced bytes on the floor under a real
	// barrier: the leader replicates it and each follower dies inside its own
	// append, before the fsync that would have made it durable.
	lead := leaderOf(c.nodes, c.ids)
	c.armFollowers(t, lead)
	if _, out, err := c.nodes[lead].Upsert(uint64(43), []float32{0, 1, 0}); err == nil {
		pumpDying(c.nodes, out, 4000)
	}

	cut = c.cutPowerToAll(t)
	back, failed := c.reboot(t, seed)
	defer func() {
		for _, n := range back {
			_ = n.Close()
		}
	}()
	refused = len(failed)
	// The ids come back in the group's own order and not in a map's. A message
	// that names whichever key Go handed out first says a different replica on
	// different runs, and this house closed that exact class in 9d002a6: an arm
	// whose line moves cannot be cited by its line.
	for _, id := range c.ids {
		if _, bad := failed[id]; bad {
			failedIDs = append(failedIDs, id)
		}
		n, ok := back[id]
		if !ok {
			continue
		}
		if hasID(t, n, ackedID) {
			kept++
		} else {
			lost++
		}
	}
	return kept, refused, lost, cut, failedIDs, failed
}

// TestQuorumPowerLoss_WithoutFsyncTheWriteIsLost is the red arm. The same
// scenario with a barrier that does nothing must not bring the acknowledged
// write back. A replica refusing to start is the absence of durability too, so
// that counts, but only the refusal this scenario produces and checked by
// identity: see the sentinel below. If the write comes back intact, the three
// replicas were never on simulated disks in the first place and the arm above
// measured nothing.
func TestQuorumPowerLoss_WithoutFsyncTheWriteIsLost(t *testing.T) {
	const seed = 1
	const ackedID = uint64(42)
	vec := []float32{1, 0, 0}

	// THE CONTROL RUNS INSIDE THE ARM, and it is what makes the arm assert a
	// DIFFERENCE rather than an outcome. Without it this test says only that a
	// cluster with a deaf barrier ends badly, which a cluster that never
	// acknowledged anything would satisfy too. With it, the same seed and the
	// same scenario run twice and the two ends are required to differ.
	//
	// It was added on 5 September 2026 and the reason is measured. As written
	// before, the arm's only live assertion was a strings.Contains over an error
	// message: all three replicas refuse to start, so the map of those that came
	// back is empty, the loop that looks at data iterates nothing, and the count
	// of survivors comes out zero without examining a single replica. Renaming
	// the error literal alone, with no change of behaviour, turned the arm red.
	// An arm whose only teeth are in a string is what DEFER-077 scores as a
	// failure.
	saneKept, saneRefused, saneLost, saneCut, _, _ := runUnderBarrier(t, seed, ackedID, vec,
		func(d *faultio.Disk) faultio.Opener { return d.Opener() })
	if saneCut == 0 {
		t.Fatal("the control cut removed nothing, so it does not establish what a real barrier survives")
	}
	if saneKept != 3 || saneRefused != 0 || saneLost != 0 {
		t.Fatalf("control: with a real barrier the write came back on %d replicas, %d refused and %d came back without it; the arm below has nothing to differ from",
			saneKept, saneRefused, saneLost)
	}

	// THE ARM. Same seed, same scenario, a barrier that accepts Sync and does
	// nothing.
	kept, refused, lost, cut, failedIDs, failed := runUnderBarrier(t, seed, ackedID, vec,
		func(d *faultio.Disk) faultio.Opener { return faultio.DeafBarrier(d.Opener()) })
	if cut == 0 {
		t.Fatal("the power cut removed nothing from a cluster that never fsynced: the layer is not modeling the barrier")
	}

	// A refusal to start counts as the absence of durability, but only the one
	// this scenario produces, and it is checked BY IDENTITY and not by text.
	// raft.ErrCorruptHardState is a sentinel; the other refusal Raft.Restore can
	// raise, "restored commit exceeds restored log", is an anonymous errors.New
	// with no sentinel to compare against. This scenario does not take that
	// branch: measured on 5 September 2026, all three replicas refuse with the
	// sentinel. So anything else, that branch included, fails here and names
	// what arrived instead of being waved through by a substring. The day this
	// scenario takes the other branch somebody has to look at it, which is the
	// point.
	for _, id := range failedIDs {
		if err := failed[id]; !errors.Is(err, raft.ErrCorruptHardState) {
			t.Fatalf("replica %d refused to start for a reason this arm does not recognize: %v", id, err)
		}
	}

	if kept > 0 {
		t.Fatalf("a cluster whose fsync does nothing brought the acknowledged write back on %d of 3 replicas", kept)
	}
	if refused+lost != 3 {
		t.Fatalf("accounted for %d replicas out of 3", refused+lost)
	}
	t.Logf("same seed and same scenario twice: with a real barrier the write came back on %d of 3 replicas; without one, %d refused to start and %d came back without it",
		saneKept, refused, lost)
}

// hasID reports whether a replica's committed log carries an upsert for id.
func hasID(t *testing.T, n *Node, id uint64) bool {
	t.Helper()
	cmds, err := n.CommittedCommands()
	if err != nil {
		t.Fatalf("committed commands: %v", err)
	}
	for _, c := range cmds {
		if c.ID == id && c.Vec != nil {
			return true
		}
	}
	return false
}
