package naylamp

import (
	"errors"
	"fmt"
	"sync"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
	"naylamp/engine/vector"
)

// Host is the passive runtime that marries one sans-io Node to one
// cluster.Transport. It owns no goroutines, no timers and no clock: the caller
// drives it, a deterministic test loop today and a TCP runner in a later
// piece. Every operation frames the outbound messages the Node produced and
// sends them through the transport by destination, and every inbound frame the
// transport delivers is stepped into the Node.
//
// The mutex serializes every entry point. Under SimNet a single goroutine
// drives the whole cluster, so it is never contended and determinism is
// untouched; it is there so the same Host is correct under the TCP transport's
// reader goroutines without a rewrite.
//
// Network sends happen strictly OUTSIDE the mutex. The lock is held to step
// the Node and to route the frames it produced; it is released before any
// byte touches the transport. Under TCP a Send toward a partitioned peer can
// block for the full socket timeout, and this mutex gates every delivery,
// tick and client call, so a send inside the critical section would let one
// dead peer wedge the whole node.
//
// The failure policy is what a consensus protocol expects of a network.
// Network loss is NORMAL: Raft tolerates dropped messages by design and
// retransmission is the protocol's business, so errors from tr.Send are
// ignored on purpose. A Node error is not normal: HandleMessage, Tick and the
// operations fail only on corruption, broken storage or divergence, so the
// first such error is stored as a sticky poison, the Host is dead, and every
// later call returns it without touching the Node. Two kinds of answer are
// exceptions and propagate unchanged: the consensus control replies
// raft.ErrNotLeader and raft.ErrNotReady, and caller mistakes rejected as
// ErrInvalidArgument before any proposal. Both are expected, neither is
// damage.
type Host struct {
	node *Node
	tr   cluster.Transport

	mu       sync.Mutex
	err      error  // first fatal error; once set the Host is poisoned
	rejected uint64 // frames refused because the declared sender was not the authenticated one
}

// errHostClosed poisons a closed Host so a late inbound frame is dropped
// without touching the released Node.
var errHostClosed = errors.New("naylamp: host is closed")

// NewHost wraps a Node and binds a transport to it. bind receives the Host's
// inbound handler and returns the transport built with it, which closes the
// window where a frame could arrive before the wiring exists: the Host is
// never observable without its transport. A nil node, a nil bind, or a nil
// transport from bind is an error.
func NewHost(node *Node, bind func(cluster.Handler) cluster.Transport) (*Host, error) {
	if node == nil {
		return nil, errors.New("naylamp: host needs a node")
	}
	if bind == nil {
		return nil, errors.New("naylamp: host needs a bind function")
	}
	h := &Host{node: node}
	// The lock is held across bind so a transport whose reader goroutines
	// start delivering immediately blocks in deliver until the wiring
	// below completes, instead of racing a nil send path. bind must not
	// invoke the handler on the calling goroutine.
	h.mu.Lock()
	h.tr = bind(h.deliver)
	tr := h.tr
	h.mu.Unlock()
	if tr == nil {
		return nil, errors.New("naylamp: bind returned a nil transport")
	}
	return h, nil
}

// deliver is the inbound handler the transport calls, and the place where the
// identity the transport AUTHENTICATED is bound to the one the frame DECLARES.
// Under TCP the authenticated id is the common name of the peer's verified
// certificate, which readLoop derives with nodeIDFromCN; under SimNet it is the
// endpoint the fabric recorded as the sender, which the sender cannot choose
// because Send carries no from at all. The declared id is the envelope's own
// From, a field that rides inside data and is therefore written by whoever
// framed it, and it is the one every layer below acts on: Node.HandleEnvelope
// hands the envelope to raft.DecodeMsgEnvelope, which builds Message{From:
// env.From}, so the consensus core's sender is that declaration. A frame whose
// two ids disagree is refused here, the only point on a frame's way into the
// Node where both values are in scope at once. RouterHost.deliver runs the same
// check on the client path.
//
// The refusal is a DROP and never a poison, and the difference is the whole
// point: any principal the cluster CA signed can reach this handler, so
// latching a fatal error on a mismatch would hand every one of them a remote
// kill switch for any node, which is the shape of attack this check exists to
// remove. It only fires on a frame that decodes: an unreadable one never
// reaches the comparison, because deliver decodes first and latches the same
// error DecodeMessage used to hand back through HandleMessage, so the existing
// poison route is byte for byte the one that was there. It also sits after the
// poison check
// above, so a frame arriving on an already-poisoned or closed Host still drops
// without replacing the error that got there first.
//
// What this does NOT do is check membership. The authenticated id may be any
// principal the cluster CA signed, member or not, and the client is exactly
// such a non-member by design, so a rule here could only ever ask whether a
// sender is honest about who it is. Whether that sender is entitled to be
// heard as a peer is asked in raft.Step, which holds the config this one does
// not.
func (h *Host) deliver(from cluster.NodeID, data []byte) {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return
	}
	env, derr := cluster.DecodeMessage(data)
	if derr != nil {
		// Unchanged: a frame that will not decode poisons, exactly as it did
		// when the Node was the one decoding it and handing the error back.
		// That policy is a separate question from this one and is not settled
		// here.
		h.err = derr
		h.mu.Unlock()
		return
	}
	if env.From != from {
		h.rejected++
		h.mu.Unlock()
		return
	}
	out, err := h.node.HandleEnvelope(env)
	if err != nil {
		h.err = err
		h.mu.Unlock()
		return
	}
	routed := h.routeLocked(out)
	h.mu.Unlock()
	sendRouted(h.tr, routed)
}

// outFrame is one routed outbound frame: the destination read from the
// frame's own envelope while the lock was held, so the send itself can happen
// after the lock is released.
type outFrame struct {
	to    cluster.NodeID
	frame []byte
}

// routeFrames decodes every produced frame into a routed send, taking the
// destination from the frame's own envelope. A frame that does not decode is
// our own bug: routing stops there and the error is returned for the caller
// to poison with, while the frames routed before it still go out, exactly the
// prefix the old under-lock path would have sent.
func routeFrames(frames [][]byte, who string) ([]outFrame, error) {
	routed := make([]outFrame, 0, len(frames))
	for _, frame := range frames {
		env, err := cluster.DecodeMessage(frame)
		if err != nil {
			return routed, fmt.Errorf("naylamp: %s produced an undecodable frame: %w", who, err)
		}
		routed = append(routed, outFrame{to: env.To, frame: frame})
	}
	return routed, nil
}

// sendRouted hands routed frames to the transport, in order. It must run
// OUTSIDE the owner's mutex: under TCP a Send toward a dead or partitioned
// peer can block for the full socket timeout, and a node whose mutex gates
// every delivery, tick and client call must never be wedged behind one peer's
// socket. A Send error is ignored: losing a message is normal and
// retransmission is the protocol's business. The transport handle is set once
// at construction and never mutated, so reading it without the lock is safe.
func sendRouted(tr cluster.Transport, routed []outFrame) {
	for _, f := range routed {
		_ = tr.Send(f.to, f.frame)
	}
}

// routeLocked routes the frames the Node produced, poisoning the Host on an
// undecodable one. The caller must hold the mutex and send the returned
// frames with sendRouted AFTER releasing it.
func (h *Host) routeLocked(frames [][]byte) []outFrame {
	routed, err := routeFrames(frames, "host")
	if err != nil {
		h.err = err
	}
	return routed
}

// Tick advances the Node's logical clock and dispatches whatever falls out.
func (h *Host) Tick() error {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return h.err
	}
	out, err := h.node.Tick()
	if err != nil {
		h.err = err
		h.mu.Unlock()
		return err
	}
	routed := h.routeLocked(out)
	err = h.err // the poison routing may have set, read before the unlock
	h.mu.Unlock()
	sendRouted(h.tr, routed)
	return err
}

// Upsert proposes a write on the leader and dispatches the replication round.
// raft.ErrNotLeader propagates unchanged so the caller can redirect.
func (h *Host) Upsert(id uint64, vec []float32) (uint64, error) {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return 0, h.err
	}
	idx, out, err := h.node.Upsert(id, vec)
	if err != nil {
		if !isControl(err) {
			h.err = err
		}
		h.mu.Unlock()
		return 0, err
	}
	routed := h.routeLocked(out)
	perr := h.err
	h.mu.Unlock()
	sendRouted(h.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return idx, nil
}

// Delete proposes a delete on the leader and dispatches the replication round.
func (h *Host) Delete(id uint64) (uint64, error) {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return 0, h.err
	}
	idx, out, err := h.node.Delete(id)
	if err != nil {
		if !isControl(err) {
			h.err = err
		}
		h.mu.Unlock()
		return 0, err
	}
	routed := h.routeLocked(out)
	perr := h.err
	h.mu.Unlock()
	sendRouted(h.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return idx, nil
}

// Search answers a nearest-neighbor query from the local index. As on the
// Node this is a local read, not linearizable on its own; pair it with
// BeginRead and ReadServable for a linearizable one.
func (h *Host) Search(query []float32, k int) ([]vector.Neighbor, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return nil, h.err
	}
	res, err := h.node.Search(query, k)
	if err != nil {
		if isControl(err) {
			return nil, err
		}
		h.err = err
		return nil, err
	}
	return res, nil
}

// BeginRead registers a linearizable read on the leader and dispatches the
// confirmation round. raft.ErrNotLeader and raft.ErrNotReady propagate
// unchanged; both are retryable answers, not damage.
func (h *Host) BeginRead() (uint64, error) {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return 0, h.err
	}
	ctx, out, err := h.node.BeginRead()
	if err != nil {
		if !isControl(err) {
			h.err = err
		}
		h.mu.Unlock()
		return 0, err
	}
	routed := h.routeLocked(out)
	perr := h.err
	h.mu.Unlock()
	sendRouted(h.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return ctx, nil
}

// ReadServable reports whether the read under ctx can be served now. A
// poisoned Host reports false.
func (h *Host) ReadServable(ctx uint64) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return false
	}
	return h.node.ReadServable(ctx)
}

// Leader returns the node this replica believes leads the current term, or
// None on a poisoned Host.
func (h *Host) Leader() cluster.NodeID {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return cluster.None
	}
	return h.node.Leader()
}

// Role returns this replica's consensus role, or RoleFollower on a poisoned
// Host.
func (h *Host) Role() raft.Role {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return raft.RoleFollower
	}
	return h.node.Role()
}

// Consensus returns the node's role, leader and term under a SINGLE acquisition
// of the mutex, so the three always describe the same instant. Calling Role and
// Leader one after the other does not: each takes and releases the mutex, and a
// delivery can run between them and move this replica to a different term, so
// the pair printed would be one that never held at once. A caller reporting a
// term alongside a role must use this, not two or three separate reads.
// A poisoned Host reports a follower of nobody at term zero, matching what the
// separate accessors report.
func (h *Host) Consensus() ConsensusState {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return ConsensusState{Role: raft.RoleFollower, Leader: cluster.None}
	}
	return h.node.Consensus()
}

// LastIndex returns the node's last log index, or 0 on a poisoned Host.
func (h *Host) LastIndex() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return 0
	}
	return h.node.LastIndex()
}

// LastConfirmedRead returns the context and read index of the node's most
// recently confirmed linearizable read, or zeros on a poisoned Host. It takes
// the same lock every entry point does, so a caller reading it never races the
// deliver path that advances it.
func (h *Host) LastConfirmedRead() (ctx, index uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return 0, 0
	}
	return h.node.LastConfirmedRead()
}

// StateHash returns the committed-data digest, or the zero hash on a poisoned
// Host.
func (h *Host) StateHash() [32]byte {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return [32]byte{}
	}
	return h.node.StateHash()
}

// Err returns the sticky poison error, or nil if the Host is healthy.
func (h *Host) Err() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.err
}

// RejectedFrames counts the frames deliver refused because the sender declared
// an id other than the one it authenticated as. It exists because the refusal
// is otherwise invisible: a dropped frame leaves no trace, so a test could only
// assert that nothing happened, and a check that wrongly refused everything
// would satisfy that assertion just as well as a correct one. A counter turns
// the drop into something a test can require to have happened exactly once. In
// a healthy cluster it stays at zero, so a nonzero value in the field means
// either a node whose id disagrees with its certificate or a peer putting
// someone else's name on its frames.
func (h *Host) RejectedFrames() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.rejected
}

// DroppedKindFrames reports the Node's count of envelopes turned away for a kind
// it does not serve. It goes through the same lock every other entry point
// takes, because the field is written on the transport's goroutine and reading
// it from the runtime's ticker without the lock would be a race.
func (h *Host) DroppedKindFrames() uint64 {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.node.DroppedKindFrames()
}

// Close releases the Node under the lock, marks the Host closed so late
// frames drop, then closes the transport outside the lock. It runs
// regardless of poison so resources are always freed, and returns the
// Node's close error.
func (h *Host) Close() error {
	h.mu.Lock()
	nerr := h.node.Close()
	if h.err == nil {
		h.err = errHostClosed
	}
	tr := h.tr
	h.mu.Unlock()
	// Outside the lock on purpose: a TCP reader blocked in deliver waiting
	// for this mutex must be able to finish, or a close that joins its
	// readers would deadlock against it.
	_ = tr.Close()
	return nerr
}

// isControl reports whether err is one the caller resolves rather than a fatal
// fault that must poison the host.
func isControl(err error) bool {
	// Three error classes cross this boundary: control flow (not leader,
	// not ready) and caller mistakes (invalid argument) propagate clean,
	// because the node rejected them with its state untouched; anything
	// else can only mean corruption, broken storage or divergence, and
	// poisons the host.
	return errors.Is(err, raft.ErrNotLeader) ||
		errors.Is(err, raft.ErrNotReady) ||
		errors.Is(err, ErrInvalidArgument)
}
