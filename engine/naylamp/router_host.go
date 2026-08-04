package naylamp

import (
	"errors"
	"sync"

	"naylamp/engine/cluster"
)

// RouterHost serializes a Router so a concurrent transport can drive it. Under
// TCP the inbound handler runs on a reader goroutine per connection, and the
// Router holds no lock of its own, so every entry point here takes one mutex,
// exactly as Host does for a Node.
//
// The Router stays response-driven and free of protocol timeouts, so a caller
// polls Result under its own deadline and, when it expires, re-issues a FRESH
// operation rather than expecting the host to retry: that is the contract
// RouteResult is built around.
//
// The failure taxonomy mirrors Host. ErrInvalidArgument propagates clean, a
// caller mistake that left the router untouched. Any other error out of the
// router, from HandleMessage or from encoding a frame it produced, can only be
// corruption or a routing bug, so the first such error poisons the host sticky
// and every later call returns it.
type RouterHost struct {
	router *Router
	tr     cluster.Transport

	mu       sync.Mutex
	err      error  // first fatal error; once set the RouterHost is poisoned
	rejected uint64 // frames refused because the declared sender was not the authenticated one
}

// errRouterHostClosed poisons a closed RouterHost so a late inbound frame is
// dropped instead of touching a released transport.
var errRouterHostClosed = errors.New("naylamp: router host is closed")

// NewRouterHost wraps a Router and binds a transport to it. bind receives the
// host's inbound handler and returns the transport built with it, which closes
// the window where a frame could arrive before the wiring exists. A nil router,
// a nil bind, or a nil transport from bind is an error.
func NewRouterHost(router *Router, bind func(cluster.Handler) cluster.Transport) (*RouterHost, error) {
	if router == nil {
		return nil, errors.New("naylamp: router host needs a router")
	}
	if bind == nil {
		return nil, errors.New("naylamp: router host needs a bind function")
	}
	rh := &RouterHost{router: router}
	// The lock is held across bind so a transport whose reader goroutines start
	// delivering immediately blocks in deliver until the wiring below
	// completes, instead of racing a nil send path. bind must not invoke the
	// handler on the calling goroutine.
	rh.mu.Lock()
	rh.tr = bind(rh.deliver)
	tr := rh.tr
	rh.mu.Unlock()
	if tr == nil {
		return nil, errors.New("naylamp: bind returned a nil transport")
	}
	return rh, nil
}

// deliver binds the authenticated identity to the declared one exactly as
// Host.deliver does, and for the same reasons; see that comment for the shape
// and for why the refusal is a drop rather than a poison. What differs is what
// the check is worth on this side, and it is worth more than it looks.
//
// Router.HandleMessage spends the envelope's From on the DEFER-012 rule that a
// response resolves an operation only when it comes from the node the live
// attempt was aimed at. That rule is correlation, not authentication: it drops
// a superseded replica answering late, and until now a peer that simply named
// the current target in its From walked straight through it and resolved an
// operation it never served. Binding the field is what turns that correlation
// into something an outsider cannot forge, because naming the target now
// requires being the target.
func (rh *RouterHost) deliver(from cluster.NodeID, data []byte) {
	rh.mu.Lock()
	if rh.err != nil {
		rh.mu.Unlock()
		return
	}
	env, derr := cluster.DecodeMessage(data)
	if derr != nil {
		rh.err = derr
		rh.mu.Unlock()
		return
	}
	if env.From != from {
		rh.rejected++
		rh.mu.Unlock()
		return
	}
	out, err := rh.router.HandleEnvelope(env)
	if err != nil {
		rh.err = err
		rh.mu.Unlock()
		return
	}
	routed := rh.routeLocked(out)
	rh.mu.Unlock()
	sendRouted(rh.tr, routed)
}

// routeLocked routes the frames the Router produced, poisoning the host on an
// undecodable one, which is our own bug. The caller must hold the mutex and
// send the returned frames with sendRouted AFTER releasing it: exactly as on
// Host, network sends never run inside the critical section, or one dead peer
// wedges the whole gateway behind its socket. A Send error is ignored: losing
// a frame is normal and the caller's deadline is the recovery.
func (rh *RouterHost) routeLocked(frames [][]byte) []outFrame {
	routed, err := routeFrames(frames, "router host")
	if err != nil {
		rh.err = err
	}
	return routed
}

// Tick advances the Router's logical clock to now and dispatches whatever
// retransmissions fall out. It mirrors Host.Tick: a poisoned host does nothing,
// and a fatal error out of the router poisons the host. The caller feeds the
// fabric's clock here, the same tick that drives the nodes, so a Router that is
// never ticked never times an attempt out.
func (rh *RouterHost) Tick(now cluster.Tick) error {
	rh.mu.Lock()
	if rh.err != nil {
		rh.mu.Unlock()
		return rh.err
	}
	out, err := rh.router.Tick(now)
	if err != nil {
		rh.err = err
		rh.mu.Unlock()
		return err
	}
	routed := rh.routeLocked(out)
	err = rh.err // the poison routing may have set, read before the unlock
	rh.mu.Unlock()
	sendRouted(rh.tr, routed)
	return err
}

// Upsert routes a write through the router and dispatches its first attempt,
// returning the op id to poll Result with. ErrInvalidArgument propagates
// unchanged; any other router error poisons the host.
func (rh *RouterHost) Upsert(id uint64, vec []float32) (uint64, error) {
	rh.mu.Lock()
	if rh.err != nil {
		rh.mu.Unlock()
		return 0, rh.err
	}
	opID, out, err := rh.router.Upsert(id, vec)
	if err != nil {
		if !errors.Is(err, ErrInvalidArgument) {
			rh.err = err
		}
		rh.mu.Unlock()
		return 0, err
	}
	routed := rh.routeLocked(out)
	perr := rh.err
	rh.mu.Unlock()
	sendRouted(rh.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return opID, nil
}

// Delete routes a removal through the router and dispatches its first attempt.
func (rh *RouterHost) Delete(id uint64) (uint64, error) {
	rh.mu.Lock()
	if rh.err != nil {
		rh.mu.Unlock()
		return 0, rh.err
	}
	opID, out, err := rh.router.Delete(id)
	if err != nil {
		if !errors.Is(err, ErrInvalidArgument) {
			rh.err = err
		}
		rh.mu.Unlock()
		return 0, err
	}
	routed := rh.routeLocked(out)
	perr := rh.err
	rh.mu.Unlock()
	sendRouted(rh.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return opID, nil
}

// Search fans a query out through the router and dispatches every leg's first
// attempt. A non-positive or oversized k comes back as ErrInvalidArgument,
// clean; any other router error poisons the host.
func (rh *RouterHost) Search(query []float32, k int) (uint64, error) {
	rh.mu.Lock()
	if rh.err != nil {
		rh.mu.Unlock()
		return 0, rh.err
	}
	opID, out, err := rh.router.Search(query, k)
	if err != nil {
		if !errors.Is(err, ErrInvalidArgument) {
			rh.err = err
		}
		rh.mu.Unlock()
		return 0, err
	}
	routed := rh.routeLocked(out)
	perr := rh.err
	rh.mu.Unlock()
	sendRouted(rh.tr, routed)
	if perr != nil {
		return 0, perr
	}
	return opID, nil
}

// Result reports an operation's outcome once, forgetting it. A poisoned host
// returns the zero result and false; the caller tells the two apart with Err.
func (rh *RouterHost) Result(opID uint64) (RouteResult, bool) {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	if rh.err != nil {
		return RouteResult{}, false
	}
	return rh.router.Result(opID)
}

// Err returns the sticky poison error, or nil if the host is healthy.
func (rh *RouterHost) Err() error {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	return rh.err
}

// RejectedFrames counts the frames deliver refused because the sender declared
// an id other than the one it authenticated as. It is the counterpart of the
// counter on Host and is there for the reason given on that one.
func (rh *RouterHost) RejectedFrames() uint64 {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	return rh.rejected
}

// Close marks the host closed so late frames drop, then closes the transport
// outside the lock. There is no node to release. It runs regardless of poison
// so resources are always freed.
func (rh *RouterHost) Close() error {
	rh.mu.Lock()
	if rh.err == nil {
		rh.err = errRouterHostClosed
	}
	tr := rh.tr
	rh.mu.Unlock()
	// Outside the lock on purpose: a reader blocked in deliver waiting for this
	// mutex must be able to finish, or a close that joins its readers would
	// deadlock against it.
	_ = tr.Close()
	return nil
}
