package raft

import "naylamp/engine/cluster"

// Entry is one record of the replicated log. The (Index, Term) pair
// identifies it uniquely across the whole cluster: the log matching property
// says two logs agreeing on that pair are identical up to it, and every
// safety argument in the paper leans on that. Data is opaque to consensus;
// the state machine above owns its meaning.
type Entry struct {
	Index uint64
	Term  uint64
	Data  []byte
}

// HardState is the part of a node's consensus state that must survive a
// crash. Term and Vote protect the one-vote-per-term rule: a node that
// forgets its vote can hand out a second one and help elect two leaders.
// Commit is persisted as an optimization so a restarted node does not need
// a leader round trip to relearn what was already committed.
type HardState struct {
	Term   uint64
	Vote   cluster.NodeID
	Commit uint64
}

// MsgKind enumerates the message families of core Raft.
type MsgKind uint16

const (
	// MsgVote is a RequestVote request from a candidate.
	MsgVote MsgKind = 1
	// MsgVoteResp answers a MsgVote.
	MsgVoteResp MsgKind = 2
	// MsgApp is AppendEntries: replication when Entries is non-empty, a
	// heartbeat when it is empty.
	MsgApp MsgKind = 3
	// MsgAppResp answers a MsgApp.
	MsgAppResp MsgKind = 4
	// MsgSnap carries one chunk of a snapshot being installed on a follower
	// that fell behind the leader's compacted log.
	MsgSnap MsgKind = 5
	// MsgSnapResp acknowledges a snapshot chunk with the next byte offset
	// the follower expects, which doubles as a resync hint on loss or
	// reordering.
	MsgSnapResp MsgKind = 6
	// MsgPreVote asks whether a vote WOULD be granted for the prospective
	// term it carries, without anyone changing state. A node whose election
	// timer fires first confirms it could win before incrementing its term,
	// so an isolated replica cannot inflate terms and disrupt a stable
	// leader on rejoin.
	MsgPreVote MsgKind = 7
	// MsgPreVoteResp answers a MsgPreVote. A grant echoes the prospective
	// term it is for; a rejection carries the responder's real current term
	// so a stale pre-candidate learns it.
	MsgPreVoteResp MsgKind = 8
)

// Message is the single unit exchanged between Raft nodes: one flat struct
// for all kinds, with the fields a kind does not use left zero. A flat
// message keeps the pure core's Step signature trivial and the wire codec
// free of per-kind cases, and it mirrors how the protocol reads: every
// message carries the sender's term first, the rest is qualification.
//
// Field usage by kind:
//
//	MsgVote:     Term, From, To, LogIndex/LogTerm = candidate's last entry
//	MsgVoteResp: Term, From, To, Granted
//	MsgApp:      Term, From, To, LogIndex/LogTerm = entry preceding Entries
//	             (prevLogIndex/prevLogTerm), Entries, Commit = leader commit
//	MsgAppResp:  Term, From, To, Granted, LastIndex = last replicated index
//	             when Granted, the follower's last log index as a catch-up
//	             hint when rejected
//	MsgSnap:     Term, From, To, LogIndex/LogTerm = snapshot position,
//	             Offset = byte offset of Chunk, Chunk, Done = final chunk,
//	             Commit = leader commit
//	MsgSnapResp: Term, From, To, LogIndex = snapshot position in transfer,
//	             Granted = chunk landed at the expected offset, Offset =
//	             next byte offset the follower expects
//	MsgPreVote:  Term = prospective term (current+1), From, To,
//	             LogIndex/LogTerm = candidate's last entry
//	MsgPreVoteResp: Term (prospective echoed on grant, responder's real
//	             term on rejection), From, To, Granted
type Message struct {
	Kind      MsgKind
	From      cluster.NodeID
	To        cluster.NodeID
	Term      uint64
	LogIndex  uint64
	LogTerm   uint64
	Entries   []Entry
	Commit    uint64
	Granted   bool
	LastIndex uint64
	Offset    uint64
	Chunk     []byte
	Done      bool
}
