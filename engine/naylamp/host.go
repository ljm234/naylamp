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

	mu  sync.Mutex
	err error // first fatal error; once set the Host is poisoned
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

// deliver is the inbound handler the transport calls. from is ignored: the
// envelope inside data already carries a verified From. A poisoned Host drops
// the frame untouched.
func (h *Host) deliver(_ cluster.NodeID, data []byte) {
	h.mu.Lock()
	if h.err != nil {
		h.mu.Unlock()
		return
	}
	out, err := h.node.HandleMessage(data)
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
