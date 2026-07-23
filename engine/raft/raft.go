// Package raft implements the Raft consensus core as a deterministic state
// machine: time enters through Tick, messages through Step, and everything a
// node must act on leaves through a Ready bundle. It owns leader election, log
// replication, snapshot transfer and the four safety properties, with no
// goroutines, wall clock or global randomness of its own.
package raft

import (
	"errors"
	"fmt"
	"math/rand/v2"
	"sort"

	"naylamp/engine/cluster"
)

// Role is the consensus role of a node.
type Role uint8

// The roles a node moves between: every node starts a follower, a follower
// whose election timer fires becomes a candidate, and a candidate that wins a
// majority becomes the leader for its term.
const (
	RoleFollower Role = iota
	RoleCandidate
	RoleLeader
)

// String makes test failures readable.
func (r Role) String() string {
	switch r {
	case RoleFollower:
		return "follower"
	case RoleCandidate:
		return "candidate"
	case RoleLeader:
		return "leader"
	}
	return "unknown"
}

// Options are the timing knobs of the core, measured in logical ticks so the
// simulation owns time completely. The election timeout is randomized per
// reset in [ElectionTicks, 2*ElectionTicks), the paper's mechanism for
// breaking split votes.
type Options struct {
	ElectionTicks  int
	HeartbeatTicks int
	// CheckQuorum makes a leader step down once it has gone a full election
	// timeout without hearing from a majority, so an isolated leader releases
	// the term instead of holding it mute forever. Its zero value is off, which
	// is exactly the behavior before this option existed.
	CheckQuorum bool
	// ServiceHealth makes a leader step down when a peer reports having reached a
	// client this window while the leader itself reached none, sustained for the
	// hysteresis window count: the case where a leader still holds quorum with its
	// peers but has gone mute toward clients, which CheckQuorum cannot see. Its
	// zero value is off, byte-for-byte the behavior before this option existed:
	// no bit is stamped, no set is kept, and no leader ever steps down for it. It
	// is only sound paired with the client router's timeout rotation, which is
	// what stops a redirect hint from bouncing a stuck client straight back to the
	// mute leader; enabling the signal without that rotation lets the recovery
	// deadlock, so the two are one feature and must be turned on together. It also
	// stamps a flag bit a build from before it rejects, so enabling it across a
	// fleet of mixed builds is unsupported (see flagReached).
	ServiceHealth bool
	// ServiceHealthWindows overrides the ServiceHealth hysteresis window count for
	// tuning under simulation; its zero value falls back to the default.
	ServiceHealthWindows int
}

// DefaultOptions keeps heartbeats well below the election timeout. CheckQuorum
// is left off so the zero-value default matches the historical behavior; a
// runtime that wants the liveness guard opts in explicitly.
func DefaultOptions() Options { return Options{ElectionTicks: 10, HeartbeatTicks: 2} }

// defaultCheckQuorumWindows is how many consecutive missed windows a leader
// tolerates before stepping down. Two windows of hysteresis absorb a single
// transient stall (a latency spike that starves one window of acks), which a
// one-window check would misread as a lost quorum, while still catching a
// genuine isolation within a bounded number of windows.
const defaultCheckQuorumWindows = 2

// defaultServiceHealthWindows is how many consecutive windows a leader must see
// a peer reaching a client while it reaches none before it steps down. Two
// windows of hysteresis absorb the healthy first-contact case, a client's first
// request landing on a follower that frames a redirect (turning its bit on) one
// window before the leader has served that client, which a one-window check
// would misread as the leader having gone mute.
const defaultServiceHealthWindows = 2

// snapChunkSize bounds one snapshot chunk on the wire, well below the
// envelope payload cap so framing overhead never pushes a chunk over it.
const snapChunkSize = 64 << 10

// Ready bundles everything the runtime must act on after one call into the
// core, in the order it must act: Entries are the log records not yet
// durable and must be persisted first; Snapshot, when present, is a fully
// received image that must be saved durably next; then a dirty HardState;
// only then may Msgs be handed to the transport, and Committed applied to
// the state machine. A vote or an ack that leaves the node before its state
// is durable is how a crashed node votes twice. Entries and Snapshot are
// each handed exactly once. ReadStates are reads whose leadership round
// completed; each is servable once applied reaches its index.
type Ready struct {
	Msgs       []Message
	Entries    []Entry
	Snapshot   *Snapshot
	Committed  []Entry
	ReadStates []ReadState
	HardState  HardState
	Dirty      bool
}

// ErrNotLeader rejects proposals on non-leaders; the caller redirects.
var ErrNotLeader = errors.New("raft: not the leader")

// ErrNotReady rejects a linearizable read on a leader that has not yet
// committed an entry of its own term; the caller retries shortly.
var ErrNotReady = errors.New("raft: leader has no commit in its term yet")

// ReadState is one confirmed linearizable read: a majority answered a
// message sent after the read was registered, so no newer leadership can
// have committed writes this node has not seen up to Index. The caller
// serves the read from its state machine once applied reaches Index.
type ReadState struct {
	Ctx   uint64
	Index uint64
}

// pendingRead tracks one read round awaiting its majority.
type pendingRead struct {
	index uint64
	acks  map[cluster.NodeID]bool
}

// Raft is the pure consensus core: a deterministic state machine with no
// goroutines, no timers, no wall clock and no global randomness. Time enters
// only through Tick, the network only through Step, and everything the node
// must do leaves through Ready. That purity is what lets the DST harness run
// a whole cluster in one goroutine under a single seed.
type Raft struct {
	id   cluster.NodeID
	cfg  cluster.Config
	opts Options
	rng  *rand.Rand

	role   Role
	hs     HardState
	log    *Log
	leader cluster.NodeID

	// applied trails hs.Commit; the gap is what Ready.Committed drains.
	applied uint64

	// stableTo is the highest log index already handed out (or restored) as
	// durable. Ready.Entries covers everything above it.
	stableTo uint64

	// snap is the latest snapshot this node holds, kept so a leader can
	// serve followers whose needed entries were compacted away.
	snap *Snapshot

	// inSnap assembles an incoming snapshot chunk by chunk; the buffered
	// length is the expected offset, so resync is just stating it.
	inSnap *Snapshot

	// pendingSnap is a fully received snapshot awaiting its one-time
	// delivery through Ready.
	pendingSnap *Snapshot

	// snapXfer tracks, per follower, the byte offset of the outstanding
	// chunk of an in-flight snapshot transfer (stop and wait: one chunk in
	// flight, retransmitted on the heartbeat cadence).
	snapXfer map[cluster.NodeID]uint64

	electionElapsed   int
	heartbeatElapsed  int
	randomizedTimeout int

	// CheckQuorum state, all leader-only. recentActive is the set of peers that
	// answered within the current window (the leader is always implicitly
	// active); checkElapsed counts ticks toward the next evaluation; and
	// failedWindows counts consecutive missed windows toward the hysteresis
	// threshold checkQuorumWindows. All are seeded in becomeLeader and cleared
	// in becomeFollower, so none survives a leadership change.
	recentActive       map[cluster.NodeID]bool
	checkElapsed       int
	failedWindows      int
	checkQuorumWindows int

	// ServiceHealth state. clientReached is this node's own bit: it framed an
	// answer to a client within the current window, set through NoteClientReached
	// and window-cleared like recentActive. A follower stamps it on its outbound
	// MsgAppResp; the leader reads its own copy locally. reachedClient is the
	// leader-only set of peers whose MsgAppResp carried that bit this window, the
	// structural parallel to recentActive. reachElapsed counts ticks toward the
	// next window evaluation and reachFailedWindows counts consecutive windows the
	// cede condition held, toward the hysteresis threshold serviceHealthWindows.
	// All are reset in becomeLeader and becomeFollower, so none survives a role
	// change, and all stay nil or zero while the option is off.
	reachedClient        map[cluster.NodeID]bool
	clientReached        bool
	reachElapsed         int
	reachFailedWindows   int
	serviceHealthWindows int

	votes map[cluster.NodeID]bool
	// prevotes counts would-grants of the pending pre-vote round; nil when
	// no round is pending.
	prevotes map[cluster.NodeID]bool
	// noopIndex is the index of the no-op this leader appended on taking
	// office; reads are refused until it commits.
	noopIndex uint64
	// readSeq numbers read rounds; pendingReads holds the ones awaiting a
	// majority and readStates the confirmed ones not yet handed out.
	readSeq      uint64
	pendingReads map[uint64]*pendingRead
	readStates   []ReadState
	nextIndex    map[cluster.NodeID]uint64
	matchIndex   map[cluster.NodeID]uint64

	dirty bool
}

// New builds a follower at term 0. The rng is mandatory: the core owns no
// randomness source, which is the whole point.
func New(id cluster.NodeID, cfg cluster.Config, rng *rand.Rand, opts Options) (*Raft, error) {
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	if !cfg.Contains(id) {
		return nil, fmt.Errorf("raft: node %d is not in the cluster config", id)
	}
	if rng == nil {
		return nil, errors.New("raft: nil rng")
	}
	if opts.ElectionTicks <= 0 || opts.HeartbeatTicks <= 0 {
		return nil, errors.New("raft: timing options must be positive")
	}
	if opts.HeartbeatTicks >= opts.ElectionTicks {
		return nil, errors.New("raft: heartbeat interval must be below the election timeout")
	}
	if opts.CheckQuorum && opts.HeartbeatTicks*2 > opts.ElectionTicks {
		return nil, errors.New("raft: CheckQuorum needs at least two heartbeat intervals per election timeout")
	}
	r := &Raft{id: id, cfg: cfg, opts: opts, rng: rng, log: NewLog(),
		checkQuorumWindows: defaultCheckQuorumWindows, serviceHealthWindows: defaultServiceHealthWindows}
	if opts.ServiceHealthWindows > 0 {
		r.serviceHealthWindows = opts.ServiceHealthWindows
	}
	r.becomeFollower(0, cluster.None)
	return r, nil
}

// Restore seeds a fresh core with the state a node's storage recovered: the
// persisted hard state, the durable snapshot when one exists, and the
// surviving log entries, contiguous from the position right after the
// snapshot (or from index 1 without one). Restored entries and snapshot are
// already durable, so they are never handed out again; the committed prefix
// beyond the snapshot is deliberately NOT marked applied, so the first Ready
// replays it through the normal Committed path. The snapshot itself is the
// applied image and the runtime rebuilds from it directly, so applied starts
// at its index, and the effective commit can never sit below it: a snapshot
// is committed state by construction. Restore is only valid on a core that
// has processed nothing.
func (r *Raft) Restore(hs HardState, snap *Snapshot, entries []Entry) error {
	if r.hs.Term != 0 || r.hs.Vote != cluster.None || r.log.LastIndex() != 0 || r.applied != 0 {
		return errors.New("raft: restore on a core that already has state")
	}
	base := uint64(0)
	if snap != nil {
		if snap.Index == 0 {
			return errors.New("raft: restored snapshot at index zero")
		}
		r.log.ResetToSnapshot(snap.Index, snap.Term)
		r.snap = snap
		r.applied = snap.Index
		base = snap.Index
	}
	for i, e := range entries {
		if e.Index != base+uint64(i)+1 {
			return fmt.Errorf("raft: restored entries have a gap at position %d", i)
		}
	}
	if len(entries) > 0 {
		if err := r.log.Append(entries...); err != nil {
			return fmt.Errorf("raft: restore append: %w", err)
		}
		if r.log.LastTerm() > hs.Term {
			return errors.New("raft: restored log term exceeds hard state term")
		}
	}
	if hs.Commit > r.log.LastIndex() {
		return errors.New("raft: restored commit exceeds restored log")
	}
	r.hs = hs
	if snap != nil && r.hs.Commit < snap.Index {
		r.hs.Commit = snap.Index
		r.dirty = true // persist the corrected floor on the next flush
	}
	r.stableTo = r.log.LastIndex()
	return nil
}

// Compact folds the applied prefix through index into the given snapshot
// image and keeps the bytes so this node, as a leader, can bring far-behind
// followers up by installation. Only committed history may ever be
// compacted, and the position must exist in the log with that exact term.
func (r *Raft) Compact(index, term uint64, data []byte) error {
	if index > r.hs.Commit {
		return fmt.Errorf("raft: compact to %d beyond commit %d", index, r.hs.Commit)
	}
	if err := r.log.CompactTo(index, term); err != nil {
		return err
	}
	r.snap = &Snapshot{Index: index, Term: term, Data: data}
	return nil
}

// ID returns this node's id.
func (r *Raft) ID() cluster.NodeID { return r.id }

// Role returns the current consensus role.
func (r *Raft) Role() Role { return r.role }

// Term returns the current term.
func (r *Raft) Term() uint64 { return r.hs.Term }

// Leader returns the node this one believes leads the current term, or None.
func (r *Raft) Leader() cluster.NodeID { return r.leader }

// LastIndex exposes the log tail for tests and the harness oracle.
func (r *Raft) LastIndex() uint64 { return r.log.LastIndex() }

// CommittedEntries returns a copy of the committed log entries this node still
// holds, those at or below the commit index and above the compaction base, in
// index order. It is a read-only audit accessor (DEFER-013): it only reads
// r.log and r.hs.Commit, never proposes, applies, emits a message or mutates
// any state, and it appears on no consensus or client path. The returned slice
// is a fresh copy (Log.Slice already copies the entry array), so a caller cannot
// use it to reach the log's live backing array. Entries already folded into a
// snapshot sit below the base and are not returned; an auditor that needs the
// whole committed history runs with compaction disabled.
func (r *Raft) CommittedEntries() []Entry {
	all := r.log.Slice(1)
	n := 0
	for n < len(all) && all[n].Index <= r.hs.Commit {
		n++
	}
	return all[:n]
}

// Tick advances logical time by one unit. Followers and candidates count
// toward an election timeout; leaders count toward the heartbeat cadence,
// which doubles as the retransmission timer for in-flight snapshot chunks.
func (r *Raft) Tick() Ready {
	var msgs []Message
	if r.role == RoleLeader {
		if r.opts.CheckQuorum {
			r.checkElapsed++
			if r.checkElapsed >= r.opts.ElectionTicks {
				r.checkElapsed = 0
				// Evaluate the window before sweeping it: reading then clearing
				// keeps the first tick of the next window from seeing an empty
				// set and misreading a healthy leader as quorumless.
				active := r.quorumActive()
				r.sweepActive()
				if active {
					r.failedWindows = 0
				} else {
					r.failedWindows++
					if r.failedWindows >= r.checkQuorumWindows {
						// A majority has gone silent for checkQuorumWindows
						// windows straight: step down at the SAME term with no
						// known leader, and emit nothing this tick so no late
						// heartbeat re-pins a follower's lease and blocks the
						// election that must now happen.
						r.becomeFollower(r.hs.Term, cluster.None)
						return r.ready(nil)
					}
				}
			}
		}
		if r.opts.ServiceHealth {
			r.reachElapsed++
			if r.reachElapsed >= r.opts.ElectionTicks {
				r.reachElapsed = 0
				// Evaluate before sweeping, the same order CheckQuorum uses above:
				// a peer reached a client this window and this leader reached none.
				ceding := len(r.reachedClient) > 0 && !r.clientReached
				r.sweepReached()
				if ceding {
					r.reachFailedWindows++
					if r.reachFailedWindows >= r.serviceHealthWindows {
						// The leader has been mute toward clients while a peer served
						// them for serviceHealthWindows straight: step down at the
						// SAME term with no known leader and emit nothing, byte for
						// byte the CheckQuorum branch above, so a late heartbeat does
						// not re-pin a follower's lease and block the election that
						// must now happen.
						r.becomeFollower(r.hs.Term, cluster.None)
						return r.ready(nil)
					}
				} else {
					r.reachFailedWindows = 0
				}
			}
		}
		r.heartbeatElapsed++
		if r.heartbeatElapsed >= r.opts.HeartbeatTicks {
			r.heartbeatElapsed = 0
			msgs = r.bcastAppend()
		}
	} else {
		if r.opts.ServiceHealth {
			r.reachElapsed++
			if r.reachElapsed >= r.opts.ElectionTicks {
				r.reachElapsed = 0
				// A non-leader keeps only its own bit, window-cleared so it never
				// stamps a stale reach onto a later MsgAppResp.
				r.clientReached = false
			}
		}
		r.electionElapsed++
		if r.electionElapsed >= r.randomizedTimeout {
			msgs = r.preCampaign()
		}
	}
	return r.ready(msgs)
}

// quorumActive reports whether a majority, the leader included, has answered
// within the current CheckQuorum window. The leader always counts itself, the
// same self-inclusion maybeCommit uses when it seeds the match set with its own
// last index; comparing only peers against Quorum would demand every follower
// be live and defeat the point of a majority.
func (r *Raft) quorumActive() bool {
	active := 1
	for _, peer := range r.cfg.Peers(r.id) {
		if r.recentActive[peer] {
			active++
		}
	}
	return active >= r.cfg.Quorum()
}

// markActive records that a peer answered this leader at the current term. The
// response handlers call it on every answer, granted or not: the answer itself
// proves the peer still reaches this leadership, exactly the reasoning
// confirmRead already applies to a read round. It is a no-op off the leader or
// when CheckQuorum is disabled, where recentActive is nil.
func (r *Raft) markActive(from cluster.NodeID) {
	if r.recentActive != nil {
		r.recentActive[from] = true
	}
}

// sweepActive clears the activity set so each window measures only itself and
// never the accumulated history: an answer three windows ago must not keep a
// since-isolated leader in office today.
func (r *Raft) sweepActive() {
	r.recentActive = make(map[cluster.NodeID]bool, len(r.cfg.Nodes)-1)
}

// NoteClientReached records that this node framed an answer to a client within
// the current window. A follower stamps the resulting bit on its next MsgAppResp
// so a leader learns the peer is reaching clients; the leader reads its own copy
// locally when it evaluates whether to cede. It is a no-op while the
// service-health option is off, so the runtime may call it on every client
// answer without a branch of its own.
func (r *Raft) NoteClientReached() {
	if r.opts.ServiceHealth {
		r.clientReached = true
	}
}

// markReached folds a peer's reached bit into the leader's window set, the
// structural parallel to markActive. It is a no-op off the leader or while the
// option is off, where reachedClient is nil.
func (r *Raft) markReached(from cluster.NodeID) {
	if r.reachedClient != nil {
		r.reachedClient[from] = true
	}
}

// sweepReached clears the leader's reach set and its own bit at a window
// boundary, the parallel to sweepActive, so each window measures only itself: a
// peer that reached a client three windows ago must not cede a leader today.
func (r *Raft) sweepReached() {
	r.reachedClient = make(map[cluster.NodeID]bool, len(r.cfg.Nodes)-1)
	r.clientReached = false
}

// Propose appends data to the leader's log and starts replicating it,
// returning the assigned index. Followers reject; the layer above redirects.
func (r *Raft) Propose(data []byte) (uint64, Ready, error) {
	if r.role != RoleLeader {
		return 0, r.ready(nil), ErrNotLeader
	}
	idx := r.log.LastIndex() + 1
	if err := r.log.Append(Entry{Index: idx, Term: r.hs.Term, Data: data}); err != nil {
		return 0, r.ready(nil), err
	}
	r.maybeCommit() // a single-node majority commits on the spot
	msgs := r.bcastAppend()
	r.heartbeatElapsed = 0
	return idx, r.ready(msgs), nil
}

// Step processes one inbound message. Term handling comes first and is
// uniform, exactly as the paper specifies: a higher term always converts the
// receiver to follower before the message is considered; a lower term is
// answered (so a stale leader or candidate learns and steps down) or, for
// stale responses, dropped.
func (r *Raft) Step(m Message) Ready {
	if m.To != r.id {
		return r.ready(nil) // misrouted: the transport attributes, we verify
	}

	// Pre-vote traffic is handled before the uniform term rules on purpose:
	// a MsgPreVote carries a PROSPECTIVE term that must never bump the
	// receiver, and a MsgPreVoteResp either echoes that prospective term or
	// carries a real one, which its handler inspects itself.
	switch m.Kind {
	case MsgPreVote:
		return r.ready([]Message{r.handlePreVote(m)})
	case MsgPreVoteResp:
		return r.ready(r.handlePreVoteResp(m))
	}

	var msgs []Message
	switch {
	case m.Term > r.hs.Term:
		lead := cluster.None
		if m.Kind == MsgApp || m.Kind == MsgSnap {
			lead = m.From
		}
		r.becomeFollower(m.Term, lead)
	case m.Term < r.hs.Term:
		switch m.Kind {
		case MsgVote:
			msgs = append(msgs, Message{Kind: MsgVoteResp, From: r.id, To: m.From, Term: r.hs.Term})
		case MsgApp:
			msgs = append(msgs, Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, LastIndex: r.log.LastIndex()})
		case MsgSnap:
			msgs = append(msgs, Message{Kind: MsgSnapResp, From: r.id, To: m.From, Term: r.hs.Term, LogIndex: m.LogIndex})
		}
		return r.ready(msgs)
	}

	switch m.Kind {
	case MsgVote:
		msgs = append(msgs, r.handleVote(m))
	case MsgVoteResp:
		msgs = append(msgs, r.handleVoteResp(m)...)
	case MsgApp:
		msgs = append(msgs, r.handleApp(m))
	case MsgAppResp:
		msgs = append(msgs, r.handleAppResp(m)...)
	case MsgSnap:
		msgs = append(msgs, r.handleSnap(m))
	case MsgSnapResp:
		msgs = append(msgs, r.handleSnapResp(m)...)
	}
	return r.ready(msgs)
}

// becomeFollower converts the node. The vote clears only when the term
// advances: within one term a node never forgets who it voted for, that is
// the one-vote-per-term rule. Outbound transfer state belongs to leadership
// and is dropped with it.
func (r *Raft) becomeFollower(term uint64, leader cluster.NodeID) {
	if term > r.hs.Term {
		r.hs.Term = term
		r.hs.Vote = cluster.None
		r.dirty = true
	}
	r.role = RoleFollower
	r.leader = leader
	r.votes = nil
	r.prevotes = nil
	r.pendingReads = nil
	r.snapXfer = nil
	r.recentActive = nil
	r.checkElapsed = 0
	r.failedWindows = 0
	r.reachedClient = nil
	r.clientReached = false
	r.reachElapsed = 0
	r.reachFailedWindows = 0
	r.resetElectionTimer()
}

// preCampaign runs the pre-vote round: before incrementing its term, a node
// asks whether a majority WOULD grant it a vote for the next one. Nothing
// durable changes during the round, so an isolated replica whose timer
// fires forever cannot inflate terms and force a re-election when it
// rejoins. Only a majority of would-grants starts the real campaign.
func (r *Raft) preCampaign() []Message {
	r.resetElectionTimer()
	r.prevotes = map[cluster.NodeID]bool{r.id: true}
	if len(r.prevotes) >= r.cfg.Quorum() {
		r.prevotes = nil
		return r.campaign() // single-node cluster: nothing to ask
	}
	msgs := make([]Message, 0, len(r.cfg.Nodes)-1)
	for _, peer := range r.cfg.Peers(r.id) {
		msgs = append(msgs, Message{
			Kind: MsgPreVote, From: r.id, To: peer, Term: r.hs.Term + 1,
			LogIndex: r.log.LastIndex(), LogTerm: r.log.LastTerm(),
		})
	}
	return msgs
}

// handlePreVote answers whether this node WOULD vote for the prospective
// term, changing no state at all. It refuses while it believes in a fresh
// leader, one heard from within a full election timeout, or while it is the
// leader itself: pre-vote exists to protect a healthy leader from a
// disruptive rejoiner, and log completeness alone cannot tell those apart.
// The one-vote-per-term rule does not apply, since nothing is granted yet,
// only predicted.
func (r *Raft) handlePreVote(m Message) Message {
	leaderFresh := r.role == RoleLeader ||
		(r.leader != cluster.None && r.electionElapsed < r.opts.ElectionTicks && r.prevotes == nil)
	grant := !leaderFresh &&
		m.Term > r.hs.Term &&
		r.log.IsUpToDate(m.LogIndex, m.LogTerm)
	resp := Message{Kind: MsgPreVoteResp, From: r.id, To: m.From, Granted: grant}
	if grant {
		resp.Term = m.Term // echo the prospective term the grant is for
	} else {
		resp.Term = r.hs.Term // a stale pre-candidate learns the real term
	}
	return resp
}

// handlePreVoteResp counts would-grants for the pending round and starts
// the real campaign on a majority. A rejection carrying a term above ours
// converts to follower at it: a real term exists this node has not seen.
func (r *Raft) handlePreVoteResp(m Message) []Message {
	if !m.Granted {
		if m.Term > r.hs.Term {
			r.becomeFollower(m.Term, cluster.None)
		}
		return nil
	}
	if r.prevotes == nil || m.Term != r.hs.Term+1 || r.role == RoleLeader {
		return nil // stale response from an abandoned or finished round
	}
	r.prevotes[m.From] = true
	if len(r.prevotes) >= r.cfg.Quorum() {
		r.prevotes = nil
		return r.campaign()
	}
	return nil
}

// campaign starts (or restarts, on a split vote) an election.
func (r *Raft) campaign() []Message {
	r.role = RoleCandidate
	r.leader = cluster.None
	r.hs.Term++
	r.hs.Vote = r.id
	r.dirty = true
	r.votes = map[cluster.NodeID]bool{r.id: true}
	r.resetElectionTimer()
	if len(r.votes) >= r.cfg.Quorum() {
		return r.becomeLeader() // single-node cluster: elected on the spot
	}
	msgs := make([]Message, 0, len(r.cfg.Nodes)-1)
	for _, peer := range r.cfg.Peers(r.id) {
		msgs = append(msgs, Message{
			Kind: MsgVote, From: r.id, To: peer, Term: r.hs.Term,
			LogIndex: r.log.LastIndex(), LogTerm: r.log.LastTerm(),
		})
	}
	return msgs
}

// becomeLeader takes office and appends a no-op entry of the new term. The
// commit rule 5.4.2 only counts majorities of the leader's own term, so
// without this entry anything left over from previous terms would stay
// uncommitted until the first client proposal; the no-op commits it now.
func (r *Raft) becomeLeader() []Message {
	r.role = RoleLeader
	r.leader = r.id
	r.heartbeatElapsed = 0
	r.prevotes = nil
	// CheckQuorum starts a fresh window seeded from the majority that just
	// elected this leader: those peers answered a heartbeat's-breadth ago, so
	// the first window can never demote a leader whose real heartbeat round has
	// not yet come back. The counters restart with the new term.
	r.checkElapsed = 0
	r.failedWindows = 0
	r.recentActive = nil
	if r.opts.CheckQuorum {
		r.recentActive = make(map[cluster.NodeID]bool, len(r.cfg.Nodes)-1)
		for voter := range r.votes {
			if voter != r.id {
				r.recentActive[voter] = true
			}
		}
	}
	r.reachElapsed = 0
	r.reachFailedWindows = 0
	r.reachedClient = nil
	r.clientReached = false
	if r.opts.ServiceHealth {
		// A fresh leader starts with an empty reach set. Unlike CheckQuorum there is
		// nothing to seed: even if a peer's bit lands during the first window and the
		// cede condition holds, the hysteresis means one window only raises the
		// counter and never steps the leader down, so the healthy first-contact case
		// is carried by serviceHealthWindows rather than by a seed.
		r.reachedClient = make(map[cluster.NodeID]bool, len(r.cfg.Nodes)-1)
	}
	r.nextIndex = make(map[cluster.NodeID]uint64, len(r.cfg.Nodes))
	r.matchIndex = make(map[cluster.NodeID]uint64, len(r.cfg.Nodes))
	r.snapXfer = make(map[cluster.NodeID]uint64)
	for _, peer := range r.cfg.Peers(r.id) {
		r.nextIndex[peer] = r.log.LastIndex() + 1
		r.matchIndex[peer] = 0
	}
	noop := Entry{Index: r.log.LastIndex() + 1, Term: r.hs.Term}
	if err := r.log.Append(noop); err != nil {
		// Appending a fresh entry at the tail cannot fail; treat it as the
		// programming error it would be.
		panic(err)
	}
	r.noopIndex = noop.Index
	r.pendingReads = make(map[uint64]*pendingRead)
	r.maybeCommit()
	return r.bcastAppend()
}

// resetElectionTimer draws a fresh randomized timeout. Randomizing per reset
// is what breaks repeated split votes (5.2).
func (r *Raft) resetElectionTimer() {
	r.electionElapsed = 0
	r.randomizedTimeout = r.opts.ElectionTicks + r.rng.IntN(r.opts.ElectionTicks)
}

// handleVote applies the voting rules: one vote per term, and only for a
// candidate whose log is at least as up to date as ours (5.4.1). Granting
// resets the election timer; a mere request does not.
func (r *Raft) handleVote(m Message) Message {
	grant := (r.hs.Vote == cluster.None || r.hs.Vote == m.From) &&
		r.log.IsUpToDate(m.LogIndex, m.LogTerm)
	if grant {
		if r.hs.Vote == cluster.None {
			r.hs.Vote = m.From
			r.dirty = true
		}
		r.resetElectionTimer()
	}
	return Message{Kind: MsgVoteResp, From: r.id, To: m.From, Term: r.hs.Term, Granted: grant}
}

// handleVoteResp counts grants for the current candidacy.
func (r *Raft) handleVoteResp(m Message) []Message {
	if r.role != RoleCandidate || !m.Granted {
		return nil
	}
	r.votes[m.From] = true
	if len(r.votes) >= r.cfg.Quorum() {
		return r.becomeLeader()
	}
	return nil
}

// handleApp is the follower side of AppendEntries at the current term:
// recognize the leader, delegate matching and conflict resolution to the
// log, and advance the commit index capped at the last position this batch
// actually confirmed (a longer stale tail must not ride along).
func (r *Raft) handleApp(m Message) Message {
	r.recognizeLeader(m.From)
	// reached carries this node's own window bit back to the leader on the same
	// MsgAppResp, granted or not; it stays false unless the option is enabled.
	reached := r.opts.ServiceHealth && r.clientReached
	lastNew := m.LogIndex + uint64(len(m.Entries))
	if _, ok := r.log.TryAppend(m.LogIndex, m.LogTerm, m.Entries); !ok {
		return Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, LastIndex: r.log.LastIndex(), ReadCtx: m.ReadCtx, Reached: reached}
	}
	if len(m.Entries) > 0 && m.LogIndex < r.stableTo {
		// The batch may have overwritten indices already handed out as
		// durable: hand the affected suffix again. Conservative on purpose;
		// storage supersession makes replaying an identical suffix
		// idempotent, and precision here is an optimization to measure once
		// the runtime exists, not a correctness requirement.
		r.stableTo = m.LogIndex
	}
	if m.Commit > r.hs.Commit {
		r.hs.Commit = min(m.Commit, lastNew)
		r.dirty = true
	}
	return Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, Granted: true, LastIndex: lastNew, ReadCtx: m.ReadCtx, Reached: reached}
}

// recognizeLeader is the shared reaction to leader traffic at the current
// term: a candidate learns a leader exists and steps down, a follower notes
// it and resets its election timer. A leader receiving leader traffic at its
// own term would mean two leaders in one term; absent that safety violation
// it cannot happen, and the harness invariant checker is the alarm if it
// ever does.
func (r *Raft) recognizeLeader(from cluster.NodeID) {
	switch r.role {
	case RoleCandidate:
		r.becomeFollower(r.hs.Term, from)
	case RoleFollower:
		r.leader = from
		r.prevotes = nil
		r.resetElectionTimer()
	}
}

// handleSnap is the follower side of chunked snapshot installation. The
// buffered length is the expected offset: a chunk landing exactly there is
// appended and acknowledged, anything else is answered with the expected
// offset so the sender resyncs, which covers loss, duplication and
// reordering on an at-most-once transport. A chunk for a snapshot at or
// below the log's base is history this node already holds, so it is
// acknowledged semantically instead of restarting a finished transfer. The
// final chunk installs: the log resets per section 7, applied jumps to the
// snapshot position because the image IS the applied state, commit takes it
// as a floor, and the image is handed to the runtime exactly once through
// Ready for durable saving before any message leaves.
func (r *Raft) handleSnap(m Message) Message {
	r.recognizeLeader(m.From)
	resp := Message{Kind: MsgSnapResp, From: r.id, To: m.From, Term: r.hs.Term, LogIndex: m.LogIndex}

	if m.LogIndex <= r.log.baseIndex {
		resp.Granted = true
		resp.Offset = m.Offset + uint64(len(m.Chunk))
		return resp
	}
	if r.inSnap == nil || r.inSnap.Index != m.LogIndex || r.inSnap.Term != m.LogTerm {
		r.inSnap = &Snapshot{Index: m.LogIndex, Term: m.LogTerm}
	}
	expected := uint64(len(r.inSnap.Data))
	if m.Offset != expected {
		resp.Offset = expected
		return resp
	}
	r.inSnap.Data = append(r.inSnap.Data, m.Chunk...)
	resp.Granted = true
	resp.Offset = uint64(len(r.inSnap.Data))
	if !m.Done {
		return resp
	}

	snap := r.inSnap
	r.inSnap = nil
	r.log.ResetToSnapshot(snap.Index, snap.Term)
	r.snap = snap
	if snap.Index > r.applied {
		r.applied = snap.Index
	}
	if snap.Index > r.hs.Commit {
		r.hs.Commit = snap.Index
		r.dirty = true
	}
	if m.Commit > r.hs.Commit {
		r.hs.Commit = min(m.Commit, r.log.LastIndex())
		r.dirty = true
	}
	if r.stableTo < snap.Index {
		r.stableTo = snap.Index
	}
	if r.stableTo > r.log.LastIndex() {
		r.stableTo = r.log.LastIndex()
	}
	r.pendingSnap = snap
	return resp
}

// handleSnapResp drives one follower's transfer forward. The follower's
// stated offset is authoritative: a refusal resyncs to it, an ack advances
// to it, and an ack covering the whole image completes the transfer, which
// counts the snapshot position as replicated and resumes normal appends.
func (r *Raft) handleSnapResp(m Message) []Message {
	if r.role != RoleLeader {
		return nil
	}
	r.markActive(m.From)
	if _, inXfer := r.snapXfer[m.From]; !inXfer || r.snap == nil {
		return nil // stale response from a finished or abandoned transfer
	}
	if m.Granted && m.Offset >= uint64(len(r.snap.Data)) {
		delete(r.snapXfer, m.From)
		// A completed installation is direct evidence: the follower holds
		// exactly the snapshot position, whatever the leader's bookkeeping
		// said. matchIndex only ever rises, preserving the commit
		// arithmetic, but nextIndex must resume right after the snapshot or
		// a stale high match would loop the transfer forever.
		if r.snap.Index > r.matchIndex[m.From] {
			r.matchIndex[m.From] = r.snap.Index
			r.maybeCommit()
		}
		if r.nextIndex[m.From] <= r.snap.Index {
			r.nextIndex[m.From] = r.snap.Index + 1
		}
		if r.nextIndex[m.From] <= r.log.LastIndex() {
			return []Message{r.buildAppend(m.From)}
		}
		return nil
	}
	r.snapXfer[m.From] = m.Offset
	return []Message{r.buildSnapChunk(m.From)}
}

// handleAppResp advances or repairs replication to one follower. On success
// the match moves forward and the commit rule runs; on rejection nextIndex
// backs off, guided by the follower's own last index, and the probe resends
// immediately instead of waiting a heartbeat.
func (r *Raft) handleAppResp(m Message) []Message {
	if r.role != RoleLeader {
		return nil
	}
	r.markActive(m.From)
	if m.Reached {
		r.markReached(m.From)
	}
	if m.ReadCtx != 0 {
		// Any answer at this term counts toward the read round, granted or
		// not: a log mismatch is repair business, while the answer itself
		// proves the sender still recognizes this leadership.
		r.confirmRead(m.ReadCtx, m.From)
	}
	if m.Granted {
		if m.LastIndex > r.matchIndex[m.From] {
			r.matchIndex[m.From] = m.LastIndex
			r.maybeCommit()
		}
		// nextIndex follows the direct evidence of the ack even when
		// matchIndex, which is deliberately monotone, does not move:
		// without this a stale high match turns every ack into an
		// identical resend, a silent livelock.
		if m.LastIndex+1 > r.nextIndex[m.From] {
			r.nextIndex[m.From] = m.LastIndex + 1
		}
		if r.nextIndex[m.From] <= r.log.LastIndex() {
			return []Message{r.buildAppend(m.From)}
		}
		return nil
	}
	next := r.nextIndex[m.From] - 1
	if hint := m.LastIndex + 1; hint < next {
		next = hint
	}
	if next < 1 {
		next = 1
	}
	r.nextIndex[m.From] = next
	return []Message{r.buildAppend(m.From)}
}

// RequestRead registers a linearizable read. It captures the commit index as
// the read's index and confirms leadership with an append round carrying the
// read's context: only answers to messages sent after this registration
// count, and a majority of them proves no newer leader can have committed
// writes this node has not seen. The read arrives through Ready.ReadStates;
// the caller serves it once applied reaches the delivered index. A single
// node cluster is its own majority and confirms on the spot.
func (r *Raft) RequestRead() (uint64, Ready, error) {
	if r.role != RoleLeader {
		return 0, r.ready(nil), ErrNotLeader
	}
	if r.hs.Commit < r.noopIndex {
		return 0, r.ready(nil), ErrNotReady
	}
	r.readSeq++
	seq := r.readSeq
	if r.cfg.Quorum() == 1 {
		r.readStates = append(r.readStates, ReadState{Ctx: seq, Index: r.hs.Commit})
		return seq, r.ready(nil), nil
	}
	r.pendingReads[seq] = &pendingRead{index: r.hs.Commit, acks: map[cluster.NodeID]bool{r.id: true}}
	msgs := r.bcastAppend()
	for i := range msgs {
		if msgs[i].Kind == MsgApp {
			msgs[i].ReadCtx = seq
		}
	}
	r.heartbeatElapsed = 0
	return seq, r.ready(msgs), nil
}

// confirmRead counts one answer toward a pending read round and delivers the
// read when a majority has answered.
func (r *Raft) confirmRead(ctx uint64, from cluster.NodeID) {
	w, ok := r.pendingReads[ctx]
	if !ok {
		return // finished, or dropped by a deposition
	}
	w.acks[from] = true
	if len(w.acks) >= r.cfg.Quorum() {
		delete(r.pendingReads, ctx)
		r.readStates = append(r.readStates, ReadState{Ctx: ctx, Index: w.index})
	}
}

// maybeCommit advances the commit index to the highest position replicated
// on a majority, restricted to entries of the current term (5.4.2): counting
// an old-term majority is the paper's figure 8 data-loss scenario. A
// position at the compaction base is exempt from the term restriction only
// in the sense that it is already committed by construction, so the check
// below can never move commit backwards through it.
func (r *Raft) maybeCommit() {
	matches := make([]uint64, 0, len(r.cfg.Nodes))
	matches = append(matches, r.log.LastIndex())
	for _, peer := range r.cfg.Peers(r.id) {
		matches = append(matches, r.matchIndex[peer])
	}
	sort.Slice(matches, func(i, j int) bool { return matches[i] > matches[j] })
	n := matches[r.cfg.Quorum()-1]
	if n <= r.hs.Commit {
		return
	}
	if term, ok := r.log.Term(n); !ok || term != r.hs.Term {
		return
	}
	r.hs.Commit = n
	r.dirty = true
}

// bcastAppend sends every follower its next batch, a heartbeat when it is
// caught up, or the outstanding snapshot chunk when a transfer is in flight,
// which makes the heartbeat cadence the retransmission timer. Peers are
// visited in config order: determinism again.
func (r *Raft) bcastAppend() []Message {
	msgs := make([]Message, 0, len(r.cfg.Nodes)-1)
	for _, peer := range r.cfg.Peers(r.id) {
		if _, inXfer := r.snapXfer[peer]; inXfer {
			msgs = append(msgs, r.buildSnapChunk(peer))
			continue
		}
		msgs = append(msgs, r.buildAppend(peer))
	}
	return msgs
}

// buildAppend assembles the MsgApp for one follower from its nextIndex,
// falling back to snapshot installation when the entries the follower needs
// were compacted away.
func (r *Raft) buildAppend(to cluster.NodeID) Message {
	if r.nextIndex[to] > r.log.LastIndex()+1 {
		// The follower hinted a longer stale log than ours; clamp to our tail.
		r.nextIndex[to] = r.log.LastIndex() + 1
	}
	if r.nextIndex[to] < 1 {
		r.nextIndex[to] = 1
	}
	if r.nextIndex[to] <= r.log.baseIndex {
		// The follower needs history at or below the compaction base, which
		// only the snapshot holds now. The base only advances through
		// Compact or Restore, both of which set the image, so its absence
		// here is a programming error.
		if r.snap == nil {
			panic(fmt.Sprintf("raft: follower %d needs compacted history but no snapshot is held", to))
		}
		if _, inXfer := r.snapXfer[to]; !inXfer {
			r.snapXfer[to] = 0
		}
		return r.buildSnapChunk(to)
	}
	prev := r.nextIndex[to] - 1
	prevTerm, ok := r.log.Term(prev)
	if !ok {
		panic(fmt.Sprintf("raft: no term for prev index %d", prev))
	}
	return Message{
		Kind: MsgApp, From: r.id, To: to, Term: r.hs.Term,
		LogIndex: prev, LogTerm: prevTerm,
		Entries: r.log.Slice(r.nextIndex[to]),
		Commit:  r.hs.Commit,
	}
}

// buildSnapChunk assembles the outstanding chunk for one follower's
// transfer: stop and wait, one chunk in flight, the done flag riding on the
// final one. An empty image still sends one empty final chunk so the
// receiver has a definite end.
func (r *Raft) buildSnapChunk(to cluster.NodeID) Message {
	off := r.snapXfer[to]
	data := r.snap.Data
	if off > uint64(len(data)) {
		off = uint64(len(data))
		r.snapXfer[to] = off
	}
	end := off + snapChunkSize
	if end > uint64(len(data)) {
		end = uint64(len(data))
	}
	return Message{
		Kind: MsgSnap, From: r.id, To: to, Term: r.hs.Term,
		LogIndex: r.snap.Index, LogTerm: r.snap.Term,
		Offset: off, Chunk: data[off:end], Done: end == uint64(len(data)),
		Commit: r.hs.Commit,
	}
}

// takeCommitted drains the entries between applied and the commit index.
func (r *Raft) takeCommitted() []Entry {
	if r.applied >= r.hs.Commit {
		return nil
	}
	out := make([]Entry, 0, r.hs.Commit-r.applied)
	for i := r.applied + 1; i <= r.hs.Commit; i++ {
		e, ok := r.log.Entry(i)
		if !ok {
			break
		}
		out = append(out, e)
	}
	r.applied = r.hs.Commit
	return out
}

// takeUnstable hands out the log suffix not yet durable, exactly once.
func (r *Raft) takeUnstable() []Entry {
	if r.log.LastIndex() <= r.stableTo {
		return nil
	}
	out := r.log.Slice(r.stableTo + 1)
	r.stableTo = r.log.LastIndex()
	return out
}

// takeSnapshot hands out a fully received snapshot, exactly once.
func (r *Raft) takeSnapshot() *Snapshot {
	s := r.pendingSnap
	r.pendingSnap = nil
	return s
}

// ready packages one call's outcome. Order matters and mirrors the runtime
// contract: unstable entries first, then the received snapshot, then hard
// state, then messages.
func (r *Raft) ready(msgs []Message) Ready {
	rd := Ready{
		Msgs:       msgs,
		Entries:    r.takeUnstable(),
		Snapshot:   r.takeSnapshot(),
		Committed:  r.takeCommitted(),
		ReadStates: r.readStates,
		HardState:  r.hs,
		Dirty:      r.dirty,
	}
	r.dirty = false
	r.readStates = nil
	return rd
}
