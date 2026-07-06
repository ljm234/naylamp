package raft

import (
	"bytes"
	"fmt"
	"testing"

	"naylamp/engine/cluster"
)

// makeSnapLeader builds a leader of a three node cluster by feeding it the
// votes directly, proposes and commits entries through acked responses from
// node 2, then compacts through the given index. It returns the leader
// holding a snapshot whose image is a recognizable byte pattern.
func makeSnapLeader(t *testing.T, seed uint64, entries int, compactTo uint64, imageSize int) *Raft {
	t.Helper()
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(seed), DefaultOptions())
	if err != nil {
		t.Fatalf("new leader: %v", err)
	}
	for i := 0; i < 40 && r.Role() != RoleCandidate; i++ {
		r.Tick()
	}
	if r.Role() != RoleCandidate {
		t.Fatalf("never campaigned")
	}
	r.Step(Message{Kind: MsgVoteResp, From: 2, To: 1, Term: r.Term(), Granted: true})
	if r.Role() != RoleLeader {
		t.Fatalf("vote grant did not elect")
	}
	for i := 0; i < entries; i++ {
		if _, _, perr := r.Propose([]byte(fmt.Sprintf("e%d", i+1))); perr != nil {
			t.Fatalf("propose %d: %v", i, perr)
		}
	}
	// Node 2 acks everything: majority of two commits the whole log.
	r.Step(Message{Kind: MsgAppResp, From: 2, To: 1, Term: r.Term(), Granted: true, LastIndex: r.LastIndex()})
	if r.hs.Commit != r.LastIndex() {
		t.Fatalf("commit did not advance: %d vs %d", r.hs.Commit, r.LastIndex())
	}
	image := bytes.Repeat([]byte{0xA5}, imageSize)
	term, ok := r.log.Term(compactTo)
	if !ok {
		t.Fatalf("no term at compaction point %d", compactTo)
	}
	if cerr := r.Compact(compactTo, term, image); cerr != nil {
		t.Fatalf("compact: %v", cerr)
	}
	return r
}

// pump moves messages between the leader and one follower until quiet,
// dropping node 3 traffic on the floor. The filter may swallow or duplicate
// specific deliveries to exercise loss and reordering; it receives each
// message and returns how many times to deliver it.
func pump(t *testing.T, leader, follower *Raft, budget int, filter func(Message) int) []*Snapshot {
	t.Helper()
	var installed []*Snapshot
	queue := []Message{}
	drain := func(rd Ready) {
		if rd.Snapshot != nil {
			installed = append(installed, rd.Snapshot)
		}
		queue = append(queue, rd.Msgs...)
	}
	drain(leader.Tick())
	for i := 0; i < budget; i++ {
		if len(queue) == 0 {
			drain(leader.Tick())
			if len(queue) == 0 {
				break
			}
		}
		m := queue[0]
		queue = queue[1:]
		times := 1
		if filter != nil {
			times = filter(m)
		}
		for c := 0; c < times; c++ {
			switch m.To {
			case follower.ID():
				drain(follower.Step(m))
			case leader.ID():
				drain(leader.Step(m))
			}
		}
	}
	return installed
}

// TestSnap_BehindFollowerInstallsAndResumes is the happy path: a fresh
// follower whose needed entries were compacted receives the image in
// multiple chunks, installs it exactly once through Ready, and then resumes
// normal replication past the snapshot.
func TestSnap_BehindFollowerInstallsAndResumes(t *testing.T) {
	leader := makeSnapLeader(t, 21, 6, 5, 3*snapChunkSize/2) // forces two chunks
	cfg := leader.cfg
	follower, err := New(2, cfg, testRNG(22), DefaultOptions())
	if err != nil {
		t.Fatalf("new follower: %v", err)
	}
	installed := pump(t, leader, follower, 200, nil)
	if len(installed) != 1 {
		t.Fatalf("snapshot handed %d times, want exactly 1", len(installed))
	}
	if installed[0].Index != 5 || len(installed[0].Data) != 3*snapChunkSize/2 {
		t.Fatalf("wrong image installed: index=%d size=%d", installed[0].Index, len(installed[0].Data))
	}
	if follower.LastIndex() != leader.LastIndex() {
		t.Fatalf("follower did not catch up: %d vs %d", follower.LastIndex(), leader.LastIndex())
	}
	if follower.hs.Commit < 5 {
		t.Fatalf("commit floor below snapshot: %d", follower.hs.Commit)
	}
	// Replication continues normally past the snapshot.
	if _, _, perr := leader.Propose([]byte("after")); perr != nil {
		t.Fatalf("propose after: %v", perr)
	}
	pump(t, leader, follower, 100, nil)
	if e, ok := follower.log.Entry(follower.LastIndex()); !ok || string(e.Data) != "after" {
		t.Fatalf("post-snapshot replication broken: %+v ok=%v", e, ok)
	}

	// Direct-evidence bookkeeping: after convergence the leader must aim
	// right past its tail for this follower, and a duplicate ack must not
	// trigger an identical resend (that silent livelock is exactly what a
	// stale high matchIndex used to cause).
	if got := leader.nextIndex[follower.ID()]; got != leader.LastIndex()+1 {
		t.Fatalf("nextIndex not tracking evidence: %d, want %d", got, leader.LastIndex()+1)
	}
	rd := leader.Step(Message{Kind: MsgAppResp, From: follower.ID(), To: leader.ID(),
		Term: leader.Term(), Granted: true, LastIndex: follower.LastIndex()})
	if len(rd.Msgs) != 0 {
		t.Fatalf("duplicate ack triggered a resend: %+v", rd.Msgs)
	}
}

// TestSnap_LossAndDuplicationResyncViaOffset exercises the transport being
// hostile: the first chunk is dropped once (heartbeat retransmission must
// recover it) and then delivered twice (the duplicate must be refused with
// the expected offset, resyncing the sender without restarting).
func TestSnap_LossAndDuplicationResyncViaOffset(t *testing.T) {
	leader := makeSnapLeader(t, 31, 6, 5, 3*snapChunkSize/2)
	follower, err := New(2, leader.cfg, testRNG(32), DefaultOptions())
	if err != nil {
		t.Fatalf("new follower: %v", err)
	}
	firstSnapSeen := false
	installed := pump(t, leader, follower, 400, func(m Message) int {
		if m.Kind == MsgSnap && m.Offset == 0 && !firstSnapSeen {
			firstSnapSeen = true
			return 0 // dropped: only the tick-driven retransmission recovers
		}
		if m.Kind == MsgSnap && m.Offset == 0 {
			return 2 // duplicated: the second copy must be refused and resync
		}
		return 1
	})
	if len(installed) != 1 || installed[0].Index != 5 {
		t.Fatalf("install under loss and duplication failed: %+v", installed)
	}
	if follower.LastIndex() != leader.LastIndex() {
		t.Fatalf("follower did not converge: %d vs %d", follower.LastIndex(), leader.LastIndex())
	}
}

// TestSnap_StaleChunkAfterInstallIsAckedSemantically: a retransmitted chunk
// arriving after the follower already installed that snapshot is answered
// with a semantic ack instead of restarting the finished transfer.
func TestSnap_StaleChunkAfterInstallIsAckedSemantically(t *testing.T) {
	leader := makeSnapLeader(t, 41, 4, 3, 10)
	follower, err := New(2, leader.cfg, testRNG(42), DefaultOptions())
	if err != nil {
		t.Fatalf("new follower: %v", err)
	}
	pump(t, leader, follower, 200, nil)
	base := follower.log.baseIndex
	if base != 3 {
		t.Fatalf("follower base not at snapshot: %d", base)
	}
	rd := follower.Step(Message{Kind: MsgSnap, From: 1, To: 2, Term: follower.Term(),
		LogIndex: 3, LogTerm: 1, Offset: 0, Chunk: []byte("stale-echo"), Done: false})
	if rd.Snapshot != nil {
		t.Fatalf("stale chunk reinstalled a snapshot")
	}
	if len(rd.Msgs) != 1 || !rd.Msgs[0].Granted || rd.Msgs[0].Offset != 10 {
		t.Fatalf("stale chunk not acked semantically: %+v", rd.Msgs)
	}
	if follower.inSnap != nil {
		t.Fatalf("stale chunk opened a transfer buffer")
	}
}

// TestSnap_RestoreWithSnapshotSeedsCore: a restart with a durable snapshot
// seeds the core at the snapshot position, never rehands the image or the
// restored entries, floors commit at the snapshot index, and replays the
// committed suffix through the normal path.
func TestSnap_RestoreWithSnapshotSeedsCore(t *testing.T) {
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}
	r, err := New(1, cfg, testRNG(51), DefaultOptions())
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	snap := &Snapshot{Index: 4, Term: 2, Data: []byte("image")}
	entries := []Entry{dataEnt(5, 2, "e5"), dataEnt(6, 3, "e6")}
	// The persisted commit lags the snapshot on purpose: a crash between
	// installing and flushing the hard state leaves exactly this shape, and
	// the snapshot being committed state must floor it.
	if err := r.Restore(HardState{Term: 3, Commit: 3}, snap, entries); err != nil {
		t.Fatalf("restore: %v", err)
	}
	if r.LastIndex() != 6 || r.log.baseIndex != 4 {
		t.Fatalf("restored shape wrong: last=%d base=%d", r.LastIndex(), r.log.baseIndex)
	}
	if r.hs.Commit != 4 {
		t.Fatalf("commit not floored at snapshot: %d", r.hs.Commit)
	}
	rd := r.Tick()
	if rd.Snapshot != nil || len(rd.Entries) != 0 {
		t.Fatalf("restored durable state rehanded: %+v %+v", rd.Snapshot, rd.Entries)
	}
	if len(rd.Committed) != 0 {
		t.Fatalf("nothing beyond the floor should replay yet: %+v", rd.Committed)
	}
	// A leader at the current term confirms commit into the suffix; entry 5
	// then replays through the normal committed path.
	rd = r.Step(Message{Kind: MsgApp, From: 2, To: 1, Term: 3, LogIndex: 6, LogTerm: 3, Commit: 5})
	if len(rd.Committed) != 1 || rd.Committed[0].Index != 5 || string(rd.Committed[0].Data) != "e5" {
		t.Fatalf("suffix did not replay through committed: %+v", rd.Committed)
	}
}
