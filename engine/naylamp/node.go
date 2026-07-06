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

	opts NodeOptions
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
	storage, hs, snap, entries, err := raft.OpenStorage(dir, 0)
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

	core, err := raft.New(id, cfg, rng, raft.DefaultOptions())
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

// HandleMessage decodes one framed inbound message, steps the core with it, and
// returns the outbound messages the step produced.
func (n *Node) HandleMessage(data []byte) ([][]byte, error) {
	m, err := raft.DecodeMsg(data)
	if err != nil {
		return nil, err
	}
	return n.processReady(n.core.Step(m))
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

// Leader returns the node this replica believes leads the current term.
func (n *Node) Leader() cluster.NodeID { return n.core.Leader() }

// Role returns this replica's current consensus role.
func (n *Node) Role() raft.Role { return n.core.Role() }

// LastIndex returns the last log index the core holds.
func (n *Node) LastIndex() uint64 { return n.core.LastIndex() }

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
	}

	for _, rs := range rd.ReadStates {
		if n.reads == nil {
			n.reads = make(map[uint64]uint64)
		}
		n.reads[rs.Ctx] = rs.Index
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
