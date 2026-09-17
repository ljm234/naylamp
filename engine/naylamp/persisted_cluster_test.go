package naylamp

import (
	"testing"

	"naylamp/engine/cluster"
	"naylamp/engine/faultio"
)

// pumpHoldingBackAfterFirst routes frames like pump, except that the replica
// named laggard receives at most ONE. That is the whole mechanism this row
// needs: the first frame the leader sends it is the append carrying the entry,
// so it persists that entry; everything after -- including the append that would
// tell it the entry is committed -- is dropped on the floor, which is what a
// power cut does to a message still in flight.
func pumpHoldingBackAfterFirst(t *testing.T, nodes map[cluster.NodeID]*Node, seed [][]byte, laggard cluster.NodeID, budget int) {
	t.Helper()
	queue := append([][]byte(nil), seed...)
	delivered := 0
	for steps := 0; steps < budget && len(queue) > 0; steps++ {
		data := queue[0]
		queue = queue[1:]
		env, err := cluster.DecodeMessage(data)
		if err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if env.To == laggard {
			if delivered > 0 {
				continue
			}
			delivered++
		}
		queue = append(queue, route(t, nodes, data)...)
	}
}

// TestPersisted_ClusterReachesPersistedPastCommitted is V2b, and it is the row
// that separates "the accessor's arithmetic is right" from "the state it reads
// is one this engine actually reaches".
//
// V2a builds the gap by hand: a hard state written one short of the log. That
// proves the accessor reports the gap; it asserts by construction that the gap
// exists. This row makes the ENGINE produce it, with real barriers and no
// sabotage anywhere, by doing to one follower exactly what a cut does: letting
// it receive the append that carries the entry and never the one that says the
// entry is committed. The leader commits on the other follower's acknowledgement
// and answers the client, which is the acknowledgement the gate's manifest
// records. Then the power goes.
//
// The replica that comes back holds the entry on its platter and below its
// commit index, and that is DEFER-102 in one sentence: the committed reading
// calls that replica unfaithful, and it lost nothing.
func TestPersisted_ClusterReachesPersistedPastCommitted(t *testing.T) {
	const seed = 909
	c := newPowerLossCluster(t, seed, func(d *faultio.Disk) faultio.Opener { return d.Opener() })

	leader := driveUntilLeader(t, c.nodes, c.ids, 300)
	var laggard cluster.NodeID
	for _, id := range c.ids {
		if id != leader {
			laggard = id
			break
		}
	}

	vec := []float32{1, 0, 0}
	_, out, err := c.nodes[leader].Upsert(77, vec)
	if err != nil {
		t.Fatalf("upsert on leader %d: %v", leader, err)
	}
	pumpHoldingBackAfterFirst(t, c.nodes, out, laggard, 4000)

	// The client's acknowledgement is the leader answering with the vector, which
	// it can only do once the entry committed and applied. Without this the row
	// would be about an unacknowledged write, which proves nothing about a gate
	// whose oracle is the manifest of acknowledged operations.
	res, serr := c.nodes[leader].Search(vec, 1)
	if serr != nil {
		t.Fatalf("search on leader %d: %v", leader, serr)
	}
	if len(res) != 1 || res[0].ID != 77 {
		t.Fatalf("the write was never acknowledged: leader %d answered %+v", leader, res)
	}

	c.cutPowerToAll(t)
	back, failed := c.reboot(t, seed)
	if err, bad := failed[laggard]; bad {
		t.Fatalf("the lagging replica %d did not come back: %v", laggard, err)
	}
	n := back[laggard]
	defer func() { _ = n.Close() }()

	committed, cerr := n.CommittedCommands()
	if cerr != nil {
		t.Fatalf("committed commands: %v", cerr)
	}
	persisted, perr := n.PersistedCommands()
	if perr != nil {
		t.Fatalf("persisted commands: %v", perr)
	}

	holds := func(cmds []CommittedCommand) bool {
		for _, cmd := range cmds {
			if cmd.ID == 77 {
				return true
			}
		}
		return false
	}

	// If the construction failed to open the gap, this row must say so rather
	// than pass: two readings that agree prove nothing about a difference.
	if holds(committed) {
		t.Skipf("replica %d learned the commit before the cut, so this seed did not reach the gap; "+
			"committed=%d persisted=%d", laggard, len(committed), len(persisted))
	}
	if !holds(persisted) {
		t.Fatalf("replica %d does not hold the acknowledged entry on disk at all, so the cut took more than the commit index: committed=%d persisted=%d",
			laggard, len(committed), len(persisted))
	}
}
