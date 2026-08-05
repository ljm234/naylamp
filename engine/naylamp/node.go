package naylamp

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"sort"

	"naylamp/engine/cluster"
	"naylamp/engine/faultio"
	"naylamp/engine/hnsw"
	"naylamp/engine/persist"
	"naylamp/engine/raft"
	"naylamp/engine/vector"
)

// indexSeed is the fixed HNSW construction seed every replica uses. Replica
// agreement on committed data (see Node.StateHash) does not depend on it, since
// that hash covers the store and not the graph. A constant seed still keeps a
// node's own graph reproducible across a from-empty replay, the cheapest form
// of recovery.
const indexSeed uint64 = 1

// imageVersion tags the state machine image layout so a later change is
// detected rather than misread.
const imageVersion byte = 1

// ErrMalformedImage reports a state machine image that does not parse cleanly.
// Fail loud on purpose, exactly like a malformed command: a bad image can only
// mean corruption or version skew, and reading past it would seed a replica
// with silently wrong state.
var ErrMalformedImage = errors.New("naylamp: malformed state machine image")

// ErrInvalidArgument reports input rejected before any proposal: the state
// machine was never touched and nothing entered the log. Callers fix their
// input and retry. A host treats this like the control errors, never as
// node failure, because a caller mistake must not poison a healthy replica.
var ErrInvalidArgument = errors.New("naylamp: invalid argument")

// NodeOptions tunes a node. CompactEvery bounds how far the applied index may
// run ahead of the last snapshot before the node folds its log into a fresh
// one; 0 disables compaction entirely.
type NodeOptions struct {
	CompactEvery uint64
	// ServiceHealth turns on the self-declared client-reach signal in the core:
	// this node stamps a bit on its MsgAppResp when it framed a client answer this
	// window, and as a leader it steps down when a peer is reaching clients while
	// it is not. Its zero value is off, byte-for-byte the historical behavior. It
	// is only sound paired with the client router's timeout rotation (see the
	// router's RotateOnTimeout), so the two are enabled together or not at all.
	ServiceHealth bool
	// ServiceHealthWindows overrides the reach signal's hysteresis window count
	// for tuning under simulation; its zero value uses the core default.
	ServiceHealthWindows int
	// Opener is where this node's durable files come from. Its zero value is
	// nil, which means the ordinary one, so leaving it alone is byte-for-byte
	// the historical behavior.
	//
	// It exists for one job: putting a replica's durable state on a simulated
	// disk that can lose power, so a test can cut the power to a whole quorum at
	// a chosen instant and watch what comes back. That is the deterministic
	// stand-in for a sysrq-b on real hardware, which cannot be deterministic
	// because the outcome there is decided by the operating system's writeback
	// and the drive's cache, both outside this process.
	Opener faultio.Opener
}

// Node is a single replica of a vector collection: a sans-io state machine
// driven by a Raft core. It owns no goroutines, no timers and no clock. Every
// operation returns the outbound messages it produced as framed [][]byte and
// the caller decides how to move them, which is what lets a deterministic
// simulation run real nodes over a simulated network under one seed.
//
// The distance metric and the construction seed are fixed for the whole
// replica set, so a from-empty replay of the same committed log reproduces the
// same store on every node.
type Node struct {
	id  cluster.NodeID
	cfg cluster.Config
	dir string

	storage *raft.Storage
	core    *raft.Raft

	store *vector.Store
	index *hnsw.Index
	dim   int

	appliedIndex uint64
	appliedTerm  uint64
	// lastSnapIndex is the log index of the most recent snapshot, the point
	// CompactEvery measures the applied index against.
	lastSnapIndex uint64
	// reads maps a confirmed linearizable read's context to the log index
	// it must wait for; a context is removed the moment it is served.
	reads map[uint64]uint64

	// lastReadCtx and lastReadIndex retain the most recently confirmed
	// linearizable read, its context and its read index, for observation only.
	// They are kept apart from reads because reads is consumed the instant a
	// search is served (see ReadServable), so the served context is gone from it
	// before anything outside the node could look. A read confirms only after a
	// majority answered its round, and the context only ever rises, so a reader
	// that acts on a rising context sees each majority round exactly once.
	lastReadCtx   uint64
	lastReadIndex uint64

	// pendingWrites parks a client write, keyed by the log index its command
	// was proposed at, until that index commits (see processReady). term is the
	// term the entry was proposed in, so a commit at that index in another term
	// is a supersession, not this write.
	pendingWrites map[uint64]pendingWrite
	// pendingSearches parks a client search, keyed by its linearizable read
	// context, until the read round confirms and the applied state reaches the
	// read's index. searchQueue holds those contexts in arrival order so the
	// resolution scan iterates a slice, never a map: a map range would make the
	// order of emitted responses non-deterministic and break the DST.
	pendingSearches map[uint64]pendingSearch
	searchQueue     []uint64

	// droppedKind counts envelopes of a family this node does not serve. Zero
	// in a healthy cluster: a nonzero value is either a peer running a version
	// that frames something this one does not know, or somebody probing.
	droppedKind uint64

	opts NodeOptions
}

// pendingWrite is a client write awaiting the commit of its proposed entry. A
// commit at its index in a matching term is the durability promise fulfilled;
// a differing term means another leader superseded it.
type pendingWrite struct {
	reqID uint64
	from  cluster.NodeID
	term  uint64
}

// pendingSearch is a client search awaiting a linearizable read. The query and
// k are held so the search can run against the applied state the instant its
// read index is reached, on this same node.
type pendingSearch struct {
	reqID uint64
	from  cluster.NodeID
	query []float32
	k     int
}

// lookup reads a vector's components from the current store for the index. It
// reads n.store at call time, so installing a snapshot (which swaps the store
// and index together) leaves the wiring correct.
func (n *Node) lookup(id uint64) ([]float32, bool) {
	v, err := n.store.Get(id)
	if err != nil {
		return nil, false
	}
	return v.Data, true
}

// OpenNode opens (or initializes) a node's durable state under dir and returns
// a ready replica. A recovered snapshot seeds the state machine directly; the
// hard state and the surviving log seed the core. A single internal Tick then
// drains the first Ready: Restore deliberately leaves the committed prefix
// unapplied, so that first Ready carries it through Committed and re-applies it
// to the state machine before the node serves any read. Draining one Tick here
// is safe and deterministic: beyond that re-application its only effect is a
// single election-timer increment, which cannot change any observable order
// before the caller starts driving the node.
func OpenNode(dir string, id cluster.NodeID, cfg cluster.Config, dim int, rng *rand.Rand, opts NodeOptions) (*Node, error) {
	if dim <= 0 {
		return nil, fmt.Errorf("naylamp: dim must be positive, got %d", dim)
	}
	open := opts.Opener
	if open == nil {
		open = faultio.OSOpener
	}
	storage, hs, snap, entries, err := raft.OpenStorageWith(dir, 0, open)
	if err != nil {
		return nil, err
	}

	n := &Node{id: id, cfg: cfg, dir: dir, storage: storage, dim: dim, opts: opts}
	n.store = vector.NewStore()
	n.index = hnsw.NewIndex(hnsw.DefaultParams(), vector.CosineDistance, n.lookup, indexSeed)

	if snap != nil {
		if err := n.installImage(snap.Data); err != nil {
			_ = storage.Close()
			return nil, err
		}
		n.appliedIndex = snap.Index
		n.appliedTerm = snap.Term
		n.lastSnapIndex = snap.Index
	}

	raftOpts := raft.DefaultOptions()
	raftOpts.CheckQuorum = true // an isolated leader demotes itself rather than hold a mute term forever
	raftOpts.ServiceHealth = opts.ServiceHealth
	raftOpts.ServiceHealthWindows = opts.ServiceHealthWindows
	core, err := raft.New(id, cfg, rng, raftOpts)
	if err != nil {
		_ = storage.Close()
		return nil, err
	}
	if err := core.Restore(hs, snap, entries); err != nil {
		_ = storage.Close()
		return nil, err
	}
	n.core = core

	if _, err := n.Tick(); err != nil {
		_ = storage.Close()
		return nil, err
	}
	return n, nil
}

// HandleMessage decodes one framed inbound message and hands it to
// HandleEnvelope. It is the entry point for a caller that holds bytes; the Host
// holds an envelope by the time it gets here, because it had to decode one to
// check who sent it, and calls HandleEnvelope directly rather than paying for a
// second decode. That second decode is not free at the sizes this transport
// allows: a catch-up append can legally carry megabytes, and DecodeMessage
// copies the payload, so doing it twice would allocate the whole frame again to
// throw it away.
func (n *Node) HandleMessage(data []byte) ([][]byte, error) {
	env, err := cluster.DecodeMessage(data)
	if err != nil {
		return nil, err
	}
	return n.HandleEnvelope(env)
}

// HandleEnvelope dispatches one already decoded envelope by kind: consensus
// traffic steps the core, a client request is served, and any other kind is
// dropped and counted. The kind is the self-describing routing bit the frame
// carries for this purpose.
func (n *Node) HandleEnvelope(env cluster.Envelope) ([][]byte, error) {
	switch env.Kind {
	case raft.EnvelopeKind:
		m, err := raft.DecodeMsgEnvelope(env)
		if err != nil {
			return nil, err
		}
		return n.processReady(n.core.Step(m))
	case ClientKind:
		return n.handleClientRequest(env)
	default:
		// A ClientRespKind frame, or any unknown kind, is dropped and counted.
		// It used to be fatal, on the reasoning that a response or a foreign
		// family here could only be a routing bug or version skew and never a
		// value to act on. The first half of that still holds: there is still
		// nothing to act on. What stopped holding is the "only", which was true
		// of a closed cluster and is not true of this one. Any principal the
		// cluster CA signed can reach this switch, and the deployment signs one
		// that is a member of nothing, so a frame arriving here can equally be
		// someone choosing the kind byte precisely because it is fatal. Since
		// Host.deliver latches the error it gets back, that made one well
		// formed frame a permanent remote kill switch for any node.
		//
		// Dropping is the same answer the malformed-request path below already
		// reaches, in the same words, and for the same reason: poisoning a
		// healthy replica over remote garbage would be a denial of service.
		// This branch simply never caught up with it. A frame the node itself
		// produces and cannot route is a different matter and stays fatal, in
		// routeFrames, because that one really is our own bug.
		n.droppedKind++
		return nil, nil
	}
}

// handleClientRequest serves one decoded client request. A write is proposed
// and its client parked until the entry commits, so the acknowledgement is a
// durability promise and not a proposal receipt. A search registers a
// linearizable read and parks its client until the round confirms and the
// applied state reaches the read's index. Control answers and caller mistakes
// come back to the client as a status; only a core error that is neither is
// fatal. What makes a value merely invalid is settled here, not in the codec:
// the wire stays a transport and validation policy stays in one place.
func (n *Node) handleClientRequest(env cluster.Envelope) ([][]byte, error) {
	req, err := DecodeClientRequest(env)
	if err != nil {
		// The envelope passed CRC, so the sender framed this body on purpose:
		// a malformed request is the caller's bug, not corruption of ours. If a
		// reqID is reachable we answer StatusInvalidArgument so the caller
		// learns; if the body cannot even hold one we drop it silently, because
		// there is no reqID to address a reply to, poisoning a healthy replica
		// over remote garbage would be a denial of service, and the drop is
		// deterministic.
		if len(env.Payload) >= clientReqHeaderSize {
			reqID := binary.LittleEndian.Uint64(env.Payload[1:9])
			return n.respond(env.From, ClientResponse{ReqID: reqID, Status: StatusInvalidArgument})
		}
		return nil, nil
	}

	switch req.Op {
	case ReqUpsert:
		if len(req.Vec) != n.dim {
			return n.respond(env.From, ClientResponse{ReqID: req.ReqID, Status: StatusInvalidArgument})
		}
		if verr := (vector.Vector{ID: req.ID, Data: req.Vec}).Validate(); verr != nil {
			return n.respond(env.From, ClientResponse{ReqID: req.ReqID, Status: StatusInvalidArgument})
		}
		return n.proposeWrite(env.From, req.ReqID, encodeUpsert(req.ID, req.Vec))
	case ReqDelete:
		return n.proposeWrite(env.From, req.ReqID, encodeDelete(req.ID))
	case ReqSearch:
		if req.K == 0 || len(req.Vec) != n.dim {
			return n.respond(env.From, ClientResponse{ReqID: req.ReqID, Status: StatusInvalidArgument})
		}
		return n.beginClientSearch(env.From, req.ReqID, req.Vec, int(req.K))
	default:
		// DecodeClientRequest already rejects an unknown op, so this is
		// unreachable; it keeps the switch total.
		return nil, fmt.Errorf("naylamp: unhandled client op %d", req.Op)
	}
}

// proposeWrite proposes one command and parks its client until the entry
// commits. On a non-leader it answers StatusNotLeader with a hint instead. The
// pending write is registered BEFORE the ready is processed, because a single
// node commits within that same call and the acknowledgement must ride out on
// it.
func (n *Node) proposeWrite(from cluster.NodeID, reqID uint64, cmd []byte) ([][]byte, error) {
	idx, rd, err := n.core.Propose(cmd)
	if err != nil {
		if errors.Is(err, raft.ErrNotLeader) {
			return n.respond(from, ClientResponse{ReqID: reqID, Status: StatusNotLeader, Leader: n.core.Leader()})
		}
		return nil, err
	}
	if n.pendingWrites == nil {
		n.pendingWrites = make(map[uint64]pendingWrite)
	}
	n.pendingWrites[idx] = pendingWrite{reqID: reqID, from: from, term: n.core.Term()}
	return n.processReady(rd)
}

// beginClientSearch registers a linearizable read and parks the client search
// on its context until the round confirms. A follower answers StatusNotLeader
// with a hint and a leader without a commit in its own term answers
// StatusNotReady, both retryable. The pending search is registered BEFORE the
// ready is processed, for the same single-node reason as a write.
func (n *Node) beginClientSearch(from cluster.NodeID, reqID uint64, query []float32, k int) ([][]byte, error) {
	ctx, rd, err := n.core.RequestRead()
	if err != nil {
		if errors.Is(err, raft.ErrNotLeader) {
			return n.respond(from, ClientResponse{ReqID: reqID, Status: StatusNotLeader, Leader: n.core.Leader()})
		}
		if errors.Is(err, raft.ErrNotReady) {
			return n.respond(from, ClientResponse{ReqID: reqID, Status: StatusNotReady})
		}
		return nil, err
	}
	if n.pendingSearches == nil {
		n.pendingSearches = make(map[uint64]pendingSearch)
	}
	n.pendingSearches[ctx] = pendingSearch{reqID: reqID, from: from, query: query, k: k}
	n.searchQueue = append(n.searchQueue, ctx)
	return n.processReady(rd)
}

// frameClientResponse frames one response to a client, first noting the framing
// as a service-health reach for the current window. Every client answer funnels
// through here, and every call is a response to a client by construction (the
// destination is always the requester's id), so the reach bit turns on for any
// answer this node hands a client, a redirect included. The core keeps and
// windows the bit, stamps it on this node's outbound MsgAppResp, and on a leader
// reads it locally; the note is a no-op while the option is off.
func (n *Node) frameClientResponse(to cluster.NodeID, resp ClientResponse) ([]byte, error) {
	n.core.NoteClientReached()
	return EncodeClientResponse(n.id, to, resp)
}

// respond frames one client response for the requester as this node's outbound
// set. n.id is the sender; the requester correlates the reply by its reqID.
func (n *Node) respond(to cluster.NodeID, resp ClientResponse) ([][]byte, error) {
	frame, err := n.frameClientResponse(to, resp)
	if err != nil {
		return nil, err
	}
	return [][]byte{frame}, nil
}

// Tick advances the core's logical clock by one unit and returns any messages
// that fell out (a heartbeat, an election, a snapshot retransmission).
func (n *Node) Tick() ([][]byte, error) {
	return n.processReady(n.core.Tick())
}

// Upsert proposes adding or replacing a vector under an id. It validates the
// vector fully before proposing, so no command the state machine would reject
// can ever enter the log. It returns the assigned log index and the outbound
// messages; on a non-leader it returns raft.ErrNotLeader unchanged so the
// caller can redirect.
func (n *Node) Upsert(id uint64, vec []float32) (uint64, [][]byte, error) {
	if len(vec) != n.dim {
		return 0, nil, fmt.Errorf("%w: vector has dim %d, node requires %d", ErrInvalidArgument, len(vec), n.dim)
	}
	if err := (vector.Vector{ID: id, Data: vec}).Validate(); err != nil {
		return 0, nil, fmt.Errorf("%w: %w", ErrInvalidArgument, err)
	}
	idx, rd, err := n.core.Propose(encodeUpsert(id, vec))
	if err != nil {
		return 0, nil, err
	}
	out, err := n.processReady(rd)
	if err != nil {
		return 0, nil, err
	}
	return idx, out, nil
}

// Delete proposes removing an id. A delete of an absent id is a harmless,
// deterministic no-op once applied (see apply), so it is proposed like any
// other command.
func (n *Node) Delete(id uint64) (uint64, [][]byte, error) {
	idx, rd, err := n.core.Propose(encodeDelete(id))
	if err != nil {
		return 0, nil, err
	}
	out, err := n.processReady(rd)
	if err != nil {
		return 0, nil, err
	}
	return idx, out, nil
}

// Search returns the k nearest neighbors to the query from this node's local
// index. This is a LOCAL read: it reflects only what this node has applied,
// which on a follower can lag the leader and is not linearizable on any node.
// For a linearizable read, call BeginRead, drive the returned messages,
// and serve the Search once ReadServable reports true for its context.
func (n *Node) Search(query []float32, k int) ([]vector.Neighbor, error) {
	if len(query) != n.dim {
		return nil, fmt.Errorf("%w: query has dim %d, node requires %d", ErrInvalidArgument, len(query), n.dim)
	}
	if k <= 0 {
		return nil, fmt.Errorf("%w: k must be positive, got %d", ErrInvalidArgument, k)
	}
	return n.index.Search(query, k), nil
}

// BeginRead registers a linearizable read on the leader and returns its
// context plus the outbound messages of the confirmation round. The caller
// drives those messages like any other traffic, then polls ReadServable
// with the context; once it reports true, a Search on this node reflects
// every write committed before BeginRead was called, which is the promise
// a local Search alone cannot make. A follower returns raft.ErrNotLeader
// unchanged so the caller can redirect, and a fresh leader that has not
// yet committed an entry of its own term returns raft.ErrNotReady, which
// is retryable.
func (n *Node) BeginRead() (uint64, [][]byte, error) {
	ctx, rd, err := n.core.RequestRead()
	if err != nil {
		return 0, nil, err
	}
	out, err := n.processReady(rd)
	if err != nil {
		return 0, nil, err
	}
	return ctx, out, nil
}

// ReadServable reports whether the read registered under ctx can be served
// now: its leadership round has confirmed and the applied state has reached
// the read's index. It returns true exactly once and then forgets the
// context, so served reads do not accumulate. An unknown context stays
// false: either its round has not confirmed yet, or its leadership was
// deposed and it never will, in which case the caller begins a fresh read.
func (n *Node) ReadServable(ctx uint64) bool {
	idx, ok := n.reads[ctx]
	if !ok {
		return false
	}
	if n.appliedIndex < idx {
		return false
	}
	delete(n.reads, ctx)
	return true
}

// ReadIndex returns the read index captured for a confirmed linearizable read
// under ctx, or false when no confirmed read is registered there. Unlike
// ReadServable it is READ-ONLY and does NOT consume the ctx: it only reads
// n.reads, leaving ReadServable as the one path that resolves and forgets the
// read. It exists to make a read's linearizability literal for the audit
// (DEFER-014): a caller can observe the read index R and assert R is at least
// the commit index of a write that landed before the read, while ReadServable
// still reports when the served state has applied >= R. It touches neither the
// wire nor consensus: it proposes nothing, applies nothing, emits no frame and
// mutates no state, and it leaves the search-without-index wire guard untouched.
func (n *Node) ReadIndex(ctx uint64) (uint64, bool) {
	idx, ok := n.reads[ctx]
	return idx, ok
}

// Leader returns the node this replica believes leads the current term.
func (n *Node) Leader() cluster.NodeID { return n.core.Leader() }

// Role returns this replica's current consensus role.
func (n *Node) Role() raft.Role { return n.core.Role() }

// DroppedKindFrames counts the envelopes HandleEnvelope turned away because they
// belonged to a family this node does not serve. It is what makes that drop
// assertable: the frame leaves no other trace, and "the node is still alive"
// alone would not distinguish a drop from a frame that was never delivered.
func (n *Node) DroppedKindFrames() uint64 { return n.droppedKind }

// ConsensusState is one replica's standing in consensus: the role it plays, the
// node it believes leads, and the term all three belong to. The three travel as
// one value because reading them one at a time can straddle a transition and
// report a combination that never existed, for example the role sampled while
// this node still led and the term sampled after a higher one deposed it.
type ConsensusState struct {
	Role   raft.Role
	Leader cluster.NodeID
	Term   uint64
}

// Consensus returns this replica's role, leader and term as one value. The core
// is single threaded and its caller holds the owner's mutex, so the three reads
// here cannot interleave with a transition.
func (n *Node) Consensus() ConsensusState {
	return ConsensusState{Role: n.core.Role(), Leader: n.core.Leader(), Term: n.core.Term()}
}

// LastIndex returns the last log index the core holds.
func (n *Node) LastIndex() uint64 { return n.core.LastIndex() }

// LastConfirmedRead returns the context and read index of the most recently
// confirmed linearizable read, or zeros if none has confirmed yet. A read
// confirms only after a majority answered its round, so a rising context is the
// trace that a majority read-index round completed on this node. Unlike
// ReadServable it does not consume the context: it only reads the retained pair,
// never proposing, applying, emitting a frame or mutating state.
func (n *Node) LastConfirmedRead() (ctx, index uint64) { return n.lastReadCtx, n.lastReadIndex }

// StateHash returns a digest of the committed data this replica holds: the
// store contents (every id and its vector) and nothing else. This is State
// Machine Safety made checkable, since two correct replicas that applied the
// same committed log hold the same data and return the same hash. It
// deliberately excludes the HNSW graph. The graph is a derived index whose
// exact shape varies legitimately with the order of rng draws during
// construction, and that history does not travel in a snapshot, so after one
// replica installs a snapshot two correct replicas can hold different graph
// shapes over identical data. Hashing the graph would flag that legitimate
// difference as divergence.
func (n *Node) StateHash() [32]byte {
	return sha256.Sum256(storeImage(n.index.Export()))
}

// CommittedCommand is one decoded committed command, exposed read-only for the
// log-fidelity audit (DEFER-013). Op is the raw command opcode, ID the record
// id, and Vec the vector of an upsert (nil on a delete).
type CommittedCommand struct {
	Op  byte
	ID  uint64
	Vec []float32
}

// CommittedCommands decodes this replica's committed log into the client
// commands it carries, in index order, skipping the consensus no-ops exactly as
// apply does. It is a read-only audit accessor (DEFER-013): it reads the core's
// committed entries through Raft.CommittedEntries and decodes each with the same
// decoder apply uses, without proposing, applying, emitting a frame or mutating
// any state, and it is wired into no consensus or client path. Duplicate entries
// for one id, which a re-issue or a retransmission produces legitimately, are
// returned as they appear: the caller replays them in order and idempotency
// absorbs the repeats, so a duplicate is expected, never a fault.
func (n *Node) CommittedCommands() ([]CommittedCommand, error) {
	entries := n.core.CommittedEntries()
	out := make([]CommittedCommand, 0, len(entries))
	for _, e := range entries {
		if len(e.Data) == 0 {
			continue // a consensus no-op carries no command, exactly as apply skips it
		}
		cmd, err := decodeCommand(e.Data)
		if err != nil {
			return nil, fmt.Errorf("naylamp: audit decode of committed entry %d: %w", e.Index, err)
		}
		out = append(out, CommittedCommand(cmd))
	}
	return out, nil
}

// Close releases the durable storage.
func (n *Node) Close() error { return n.storage.Close() }

// processReady applies one Ready in the exact order the persist-before-send
// contract requires, failing early on any storage error: unstable entries are
// made durable first, then a received snapshot, then a dirty hard state, only
// then are the outbound messages framed, and finally the committed entries are
// applied to the state machine. An auto-compaction may run last.
func (n *Node) processReady(rd raft.Ready) ([][]byte, error) {
	if len(rd.Entries) > 0 {
		if err := n.storage.AppendEntries(rd.Entries); err != nil {
			return nil, err
		}
	}

	if rd.Snapshot != nil {
		if err := n.storage.SaveSnapshot(*rd.Snapshot); err != nil {
			return nil, err
		}
		if err := n.installImage(rd.Snapshot.Data); err != nil {
			return nil, err
		}
		if err := n.storage.CompactThrough(rd.Snapshot.Index); err != nil {
			return nil, err
		}
		n.appliedIndex = rd.Snapshot.Index
		n.appliedTerm = rd.Snapshot.Term
		n.lastSnapIndex = rd.Snapshot.Index
	}

	if rd.Dirty {
		if err := n.storage.SaveHardState(rd.HardState); err != nil {
			return nil, err
		}
	}

	out := make([][]byte, 0, len(rd.Msgs))
	for i := range rd.Msgs {
		data, err := raft.EncodeMsg(rd.Msgs[i])
		if err != nil {
			return nil, err
		}
		out = append(out, data)
	}

	for _, e := range rd.Committed {
		if err := n.apply(e); err != nil {
			return nil, err
		}
		n.appliedIndex = e.Index
		n.appliedTerm = e.Term
		// Resolve any client write parked on this exact index. It runs for
		// every committed entry, no-op included, and always clears the parked
		// write. If the entry kept the term it was proposed in, the write
		// survived to commit: answer StatusOK with its index, the durability
		// promise. If the term differs, another leader superseded the entry:
		// answer StatusNotLeader with a hint so the caller retries, which is
		// safe because upsert and delete are idempotent.
		pw, waiting := n.pendingWrites[e.Index]
		if !waiting {
			continue
		}
		delete(n.pendingWrites, e.Index)
		resp := ClientResponse{ReqID: pw.reqID, Status: StatusOK, Index: e.Index}
		if e.Term != pw.term {
			resp = ClientResponse{ReqID: pw.reqID, Status: StatusNotLeader, Leader: n.core.Leader()}
		}
		frame, err := n.frameClientResponse(pw.from, resp)
		if err != nil {
			return nil, err
		}
		out = append(out, frame)
	}

	for _, rs := range rd.ReadStates {
		if n.reads == nil {
			n.reads = make(map[uint64]uint64)
		}
		n.reads[rs.Ctx] = rs.Index
		if rs.Ctx > n.lastReadCtx {
			n.lastReadCtx, n.lastReadIndex = rs.Ctx, rs.Index
		}
	}

	// Serve every parked search whose read round has confirmed and whose read
	// index the applied state has reached. A later round can confirm before an
	// earlier one, so the whole queue is scanned rather than stopping at the
	// first unservable context. The walk is over searchQueue in arrival order,
	// never a map range, so the order of emitted responses is deterministic.
	kept := n.searchQueue[:0]
	for _, ctx := range n.searchQueue {
		ps, waiting := n.pendingSearches[ctx]
		if !waiting {
			continue
		}
		if !n.ReadServable(ctx) {
			kept = append(kept, ctx)
			continue
		}
		frame, err := n.frameClientResponse(ps.from, ClientResponse{
			ReqID:     ps.reqID,
			Status:    StatusOK,
			Neighbors: n.index.Search(ps.query, ps.k),
		})
		if err != nil {
			return nil, err
		}
		out = append(out, frame)
		delete(n.pendingSearches, ctx)
	}
	n.searchQueue = kept

	// A search whose leadership was lost before its round confirmed can never
	// be served: its read index was captured under a leadership that no longer
	// holds. Flush every such context with StatusNotLeader so the caller
	// retries against the new leader. A context still confirmed in n.reads is
	// spared: its round completed while leadership was valid, so it remains a
	// sound linearization point and is served once applied reaches its index.
	if n.core.Role() != raft.RoleLeader && len(n.pendingSearches) > 0 {
		stillPending := n.searchQueue[:0]
		for _, ctx := range n.searchQueue {
			ps, waiting := n.pendingSearches[ctx]
			if !waiting {
				continue
			}
			if _, confirmed := n.reads[ctx]; confirmed {
				stillPending = append(stillPending, ctx)
				continue
			}
			frame, err := n.frameClientResponse(ps.from, ClientResponse{ReqID: ps.reqID, Status: StatusNotLeader, Leader: n.core.Leader()})
			if err != nil {
				return nil, err
			}
			out = append(out, frame)
			delete(n.pendingSearches, ctx)
		}
		n.searchQueue = stillPending
	}

	if err := n.maybeCompact(); err != nil {
		return nil, err
	}

	return out, nil
}

// apply runs one committed entry against the state machine. An empty payload is
// the consensus no-op a leader appends on taking office and is skipped. Any
// other payload is decoded and applied, mirroring the engine exactly: an upsert
// overwrites an existing id, a delete of an absent id is a deterministic no-op
// that leaves the index untouched. A malformed command or a rejected store
// insert is returned as an error and fails the node loud: on a committed entry
// either can only mean corruption or version skew, and silently diverging
// replicas is the one failure a replicated state machine can never tolerate.
func (n *Node) apply(e raft.Entry) error {
	if len(e.Data) == 0 {
		return nil
	}
	cmd, err := decodeCommand(e.Data)
	if err != nil {
		return err
	}
	switch cmd.Op {
	case opUpsert:
		if err := n.store.Insert(vector.Vector{ID: cmd.ID, Data: cmd.Vec}); err != nil {
			return fmt.Errorf("naylamp: apply upsert %d: %w", cmd.ID, err)
		}
		if err := n.index.Insert(cmd.ID); err != nil {
			return fmt.Errorf("naylamp: apply upsert index %d: %w", cmd.ID, err)
		}
		return nil
	case opDelete:
		if err := n.store.Delete(cmd.ID); err != nil {
			if errors.Is(err, vector.ErrNotFound) {
				return nil // deterministic no-op: every replica sees the same absence
			}
			return fmt.Errorf("naylamp: apply delete %d: %w", cmd.ID, err)
		}
		n.index.Delete(cmd.ID)
		return nil
	default:
		return fmt.Errorf("%w: unknown op %d", ErrMalformedCommand, cmd.Op)
	}
}

// maybeCompact folds the applied state into a fresh snapshot when the log has
// grown CompactEvery entries past the last one. It builds the full image (store
// plus graph, for an exact and fast restore), tells the core to compact its log
// at the applied position, persists the snapshot, and truncates the covered
// segments.
func (n *Node) maybeCompact() error {
	if n.opts.CompactEvery == 0 || n.appliedIndex == 0 {
		return nil
	}
	if n.appliedIndex-n.lastSnapIndex < n.opts.CompactEvery {
		return nil
	}
	image, err := n.buildImage()
	if err != nil {
		return err
	}
	if err := n.core.Compact(n.appliedIndex, n.appliedTerm, image); err != nil {
		return err
	}
	if err := n.storage.SaveSnapshot(raft.Snapshot{Index: n.appliedIndex, Term: n.appliedTerm, Data: image}); err != nil {
		return err
	}
	if err := n.storage.CompactThrough(n.appliedIndex); err != nil {
		return err
	}
	n.lastSnapIndex = n.appliedIndex
	return nil
}

// buildImage serializes the full state machine image: the store contents
// followed by the exported HNSW graph. The store portion is what StateHash
// hashes; the graph portion lets a snapshot restore the index exactly and fast,
// without rebuilding it from the vectors. Layout, little-endian:
//
//	store portion (see storeImage): version, count, id-sorted records
//	uint32  graph length
//	graph   persist.EncodeIndexToBytes(index.Export()) bytes
func (n *Node) buildImage() ([]byte, error) {
	snap := n.index.Export()
	graph, err := persist.EncodeIndexToBytes(snap)
	if err != nil {
		return nil, err
	}
	store := storeImage(snap)
	out := make([]byte, 0, len(store)+4+len(graph))
	out = append(out, store...)
	var lenBuf [4]byte
	binary.LittleEndian.PutUint32(lenBuf[:], uint32(len(graph))) //nolint:gosec // the serialized graph size is bounded far below uint32
	out = append(out, lenBuf[:]...)
	out = append(out, graph...)
	return out, nil
}

// storeImage encodes the committed data as a version byte, a uint64 count, then
// one record per vector in ascending id order: id uint64, dim uint32, then dim
// float32 bits. The records come from the index export, which holds exactly one
// node per stored vector (every store mutation is paired with an index one).
// The ascending id order is imposed here with an explicit sort rather than
// inherited from another package's emission order, so the hash stays canonical
// no matter how Export chooses to enumerate.
func storeImage(snap hnsw.IndexSnapshot) []byte {
	nodes := make([]hnsw.NodeSnapshot, len(snap.Nodes))
	copy(nodes, snap.Nodes)
	sort.Slice(nodes, func(i, j int) bool { return nodes[i].ID < nodes[j].ID })

	out := make([]byte, 0, 1+8+len(nodes)*(8+4))
	out = append(out, imageVersion)
	var num [8]byte
	binary.LittleEndian.PutUint64(num[:], uint64(len(nodes)))
	out = append(out, num[:]...)
	var word [4]byte
	for i := range nodes {
		nd := nodes[i]
		binary.LittleEndian.PutUint64(num[:], nd.ID)
		out = append(out, num[:]...)
		binary.LittleEndian.PutUint32(word[:], uint32(len(nd.Data))) //nolint:gosec // dim is a vector length the node validated on upsert, far below uint32
		out = append(out, word[:]...)
		for _, f := range nd.Data {
			binary.LittleEndian.PutUint32(word[:], math.Float32bits(f))
			out = append(out, word[:]...)
		}
	}
	return out
}

// installImage replaces the state machine with the one encoded in data: a fresh
// store rebuilt from the records and an index restored from the exported graph.
// The store is swapped in before the index is restored so the index's lookup
// reads the new store.
func (n *Node) installImage(data []byte) error {
	store, snap, err := decodeImage(data, n.dim)
	if err != nil {
		return err
	}
	n.store = store
	n.index = hnsw.RestoreIndex(snap, vector.CosineDistance, n.lookup, indexSeed)
	return nil
}

// decodeImage parses a state machine image, validating every length before it
// allocates so a lying count cannot drive a huge allocation and trailing bytes
// fail loud. It returns a fresh store holding the decoded vectors and the index
// snapshot to restore. It fails loud on any framing error for the same reason a
// malformed command does: a bad image can only mean corruption or version skew.
func decodeImage(b []byte, expectDim int) (*vector.Store, hnsw.IndexSnapshot, error) {
	var empty hnsw.IndexSnapshot
	if len(b) < 1+8 {
		return nil, empty, fmt.Errorf("%w: %d bytes", ErrMalformedImage, len(b))
	}
	if b[0] != imageVersion {
		return nil, empty, fmt.Errorf("%w: version %d", ErrMalformedImage, b[0])
	}
	off := 1
	count := binary.LittleEndian.Uint64(b[off : off+8])
	off += 8

	store := vector.NewStore()
	for i := uint64(0); i < count; i++ {
		if len(b)-off < 8+4 {
			return nil, empty, fmt.Errorf("%w: truncated record header", ErrMalformedImage)
		}
		id := binary.LittleEndian.Uint64(b[off : off+8])
		off += 8
		dim := binary.LittleEndian.Uint32(b[off : off+4])
		off += 4
		if int(dim) != expectDim {
			// A record of a foreign dimension would make Search compute
			// distances over mismatched vectors, which is undefined math.
			// Failing hard at the boundary is cheaper than debugging corrupt
			// distances later.
			return nil, empty, fmt.Errorf("%w: record dim %d, node requires %d", ErrMalformedImage, dim, expectDim)
		}
		rest := len(b) - off
		if uint64(dim)*4 > uint64(rest) { //nolint:gosec // rest >= 0 by the checks above, so the conversion cannot wrap
			return nil, empty, fmt.Errorf("%w: dim %d exceeds %d remaining bytes", ErrMalformedImage, dim, rest)
		}
		vec := make([]float32, dim)
		for j := range vec {
			vec[j] = math.Float32frombits(binary.LittleEndian.Uint32(b[off : off+4]))
			off += 4
		}
		if err := store.Insert(vector.Vector{ID: id, Data: vec}); err != nil {
			return nil, empty, fmt.Errorf("%w: store insert %d: %v", ErrMalformedImage, id, err)
		}
	}

	if len(b)-off < 4 {
		return nil, empty, fmt.Errorf("%w: missing graph length", ErrMalformedImage)
	}
	graphLen := binary.LittleEndian.Uint32(b[off : off+4])
	off += 4
	if uint64(graphLen) > uint64(len(b)-off) { //nolint:gosec // len(b)-off >= 0 by the check above, so the conversion cannot wrap
		return nil, empty, fmt.Errorf("%w: graph length %d exceeds %d remaining bytes", ErrMalformedImage, graphLen, len(b)-off)
	}
	graph := b[off : off+int(graphLen)]
	off += int(graphLen)
	if off != len(b) {
		return nil, empty, fmt.Errorf("%w: %d trailing bytes", ErrMalformedImage, len(b)-off)
	}
	snap, err := persist.DecodeIndexFromBytes(graph)
	if err != nil {
		return nil, empty, fmt.Errorf("%w: %v", ErrMalformedImage, err)
	}
	return store, snap, nil
}
