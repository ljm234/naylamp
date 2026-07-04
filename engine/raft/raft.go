// Package raft implements the Raft consensus core as a deterministic state
// machine: time enters through Tick, messages through Step, and everything a
// node must act on leaves through a Ready bundle. It owns leader election, log
// replication and the four safety properties, with no goroutines, wall clock
// or global randomness of its own.
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
}

// DefaultOptions keeps heartbeats well below the election timeout.
func DefaultOptions() Options { return Options{ElectionTicks: 10, HeartbeatTicks: 2} }

// Ready bundles everything the runtime must act on after one call into the
// core: messages to hand to the transport, committed entries to apply in
// order, and the current HardState with a Dirty flag. The 3.3 runtime must
// persist a dirty HardState BEFORE sending the messages: a vote or an ack
// that leaves the node before it is durable is how a crashed node votes
// twice. In 3.2 the harness only asserts on it.
type Ready struct {
	Msgs      []Message
	Committed []Entry
	HardState HardState
	Dirty     bool
}

// ErrNotLeader rejects proposals on non-leaders; the caller redirects.
var ErrNotLeader = errors.New("raft: not the leader")

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

	electionElapsed   int
	heartbeatElapsed  int
	randomizedTimeout int

	votes      map[cluster.NodeID]bool
	nextIndex  map[cluster.NodeID]uint64
	matchIndex map[cluster.NodeID]uint64

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
	r := &Raft{id: id, cfg: cfg, opts: opts, rng: rng, log: NewLog()}
	r.becomeFollower(0, cluster.None)
	return r, nil
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

// Tick advances logical time by one unit. Followers and candidates count
// toward an election timeout; leaders count toward the heartbeat cadence.
func (r *Raft) Tick() Ready {
	var msgs []Message
	if r.role == RoleLeader {
		r.heartbeatElapsed++
		if r.heartbeatElapsed >= r.opts.HeartbeatTicks {
			r.heartbeatElapsed = 0
			msgs = r.bcastAppend()
		}
	} else {
		r.electionElapsed++
		if r.electionElapsed >= r.randomizedTimeout {
			msgs = r.campaign()
		}
	}
	return r.ready(msgs)
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
	var msgs []Message
	switch {
	case m.Term > r.hs.Term:
		lead := cluster.None
		if m.Kind == MsgApp {
			lead = m.From
		}
		r.becomeFollower(m.Term, lead)
	case m.Term < r.hs.Term:
		switch m.Kind {
		case MsgVote:
			msgs = append(msgs, Message{Kind: MsgVoteResp, From: r.id, To: m.From, Term: r.hs.Term})
		case MsgApp:
			msgs = append(msgs, Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, LastIndex: r.log.LastIndex()})
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
	}
	return r.ready(msgs)
}

// becomeFollower converts the node. The vote clears only when the term
// advances: within one term a node never forgets who it voted for, that is
// the one-vote-per-term rule.
func (r *Raft) becomeFollower(term uint64, leader cluster.NodeID) {
	if term > r.hs.Term {
		r.hs.Term = term
		r.hs.Vote = cluster.None
		r.dirty = true
	}
	r.role = RoleFollower
	r.leader = leader
	r.votes = nil
	r.resetElectionTimer()
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
	r.nextIndex = make(map[cluster.NodeID]uint64, len(r.cfg.Nodes))
	r.matchIndex = make(map[cluster.NodeID]uint64, len(r.cfg.Nodes))
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
	switch r.role {
	case RoleCandidate:
		r.becomeFollower(m.Term, m.From) // a leader exists for this term
	case RoleFollower:
		r.leader = m.From
		r.resetElectionTimer()
	}
	// A leader receiving MsgApp at its own term would mean two leaders in
	// one term; absent that safety violation it cannot happen, and the
	// harness invariant checker is the alarm if it ever does.

	lastNew := m.LogIndex + uint64(len(m.Entries))
	if _, ok := r.log.TryAppend(m.LogIndex, m.LogTerm, m.Entries); !ok {
		return Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, LastIndex: r.log.LastIndex()}
	}
	if m.Commit > r.hs.Commit {
		r.hs.Commit = min(m.Commit, lastNew)
		r.dirty = true
	}
	return Message{Kind: MsgAppResp, From: r.id, To: m.From, Term: r.hs.Term, Granted: true, LastIndex: lastNew}
}

// handleAppResp advances or repairs replication to one follower. On success
// the match moves forward and the commit rule runs; on rejection nextIndex
// backs off, guided by the follower's own last index, and the probe resends
// immediately instead of waiting a heartbeat.
func (r *Raft) handleAppResp(m Message) []Message {
	if r.role != RoleLeader {
		return nil
	}
	if m.Granted {
		if m.LastIndex > r.matchIndex[m.From] {
			r.matchIndex[m.From] = m.LastIndex
			r.nextIndex[m.From] = m.LastIndex + 1
			r.maybeCommit()
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

// maybeCommit advances the commit index to the highest position replicated
// on a majority, restricted to entries of the current term (5.4.2): counting
// an old-term majority is the paper's figure 8 data-loss scenario.
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

// bcastAppend sends every follower its next batch, or a heartbeat when it is
// already caught up. Peers are visited in config order: determinism again.
func (r *Raft) bcastAppend() []Message {
	msgs := make([]Message, 0, len(r.cfg.Nodes)-1)
	for _, peer := range r.cfg.Peers(r.id) {
		msgs = append(msgs, r.buildAppend(peer))
	}
	return msgs
}

// buildAppend assembles the MsgApp for one follower from its nextIndex.
func (r *Raft) buildAppend(to cluster.NodeID) Message {
	if r.nextIndex[to] > r.log.LastIndex()+1 {
		// The follower hinted a longer stale log than ours; clamp to our tail.
		r.nextIndex[to] = r.log.LastIndex() + 1
	}
	if r.nextIndex[to] < 1 {
		r.nextIndex[to] = 1
	}
	prev := r.nextIndex[to] - 1
	prevTerm, ok := r.log.Term(prev)
	if !ok {
		// Below the compaction base: 3.3 answers this with InstallSnapshot.
		// The 3.2 log never compacts, so reaching here is a programming error.
		panic(fmt.Sprintf("raft: no term for prev index %d", prev))
	}
	return Message{
		Kind: MsgApp, From: r.id, To: to, Term: r.hs.Term,
		LogIndex: prev, LogTerm: prevTerm,
		Entries: r.log.Slice(r.nextIndex[to]),
		Commit:  r.hs.Commit,
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

// ready packages one call's outcome.
func (r *Raft) ready(msgs []Message) Ready {
	rd := Ready{Msgs: msgs, Committed: r.takeCommitted(), HardState: r.hs, Dirty: r.dirty}
	r.dirty = false
	return rd
}
