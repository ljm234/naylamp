package naylamp

import (
	"errors"
	"fmt"
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

	mu  sync.Mutex
	err error // first fatal error; once set the RouterHost is poisoned
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

// deliver is the inbound handler the transport calls. from is ignored: the
// envelope inside data already carries a verified From. A poisoned host drops
// the frame untouched.
func (rh *RouterHost) deliver(_ cluster.NodeID, data []byte) {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	if rh.err != nil {
		return
	}
	out, err := rh.router.HandleMessage(data)
	if err != nil {
		rh.err = err
		return
	}
	rh.sendAll(out)
}

// sendAll routes and sends every frame the Router produced, taking the
// destination from the frame's own envelope. A Send error is ignored: losing a
// frame is normal and the caller's deadline is the recovery. A frame the Router
// produced that does not decode is our own bug, so it poisons the host. The
// caller must hold the mutex.
func (rh *RouterHost) sendAll(frames [][]byte) {
	for _, frame := range frames {
		env, err := cluster.DecodeMessage(frame)
		if err != nil {
			rh.err = fmt.Errorf("naylamp: router host produced an undecodable frame: %w", err)
			return
		}
		_ = rh.tr.Send(env.To, frame)
	}
}

// Upsert routes a write through the router and dispatches its first attempt,
// returning the op id to poll Result with. ErrInvalidArgument propagates
// unchanged; any other router error poisons the host.
func (rh *RouterHost) Upsert(id uint64, vec []float32) (uint64, error) {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	if rh.err != nil {
		return 0, rh.err
	}
	opID, out, err := rh.router.Upsert(id, vec)
	if err != nil {
		if errors.Is(err, ErrInvalidArgument) {
			return 0, err
		}
		rh.err = err
		return 0, err
	}
	rh.sendAll(out)
	if rh.err != nil {
		return 0, rh.err
	}
	return opID, nil
}

// Delete routes a removal through the router and dispatches its first attempt.
func (rh *RouterHost) Delete(id uint64) (uint64, error) {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	if rh.err != nil {
		return 0, rh.err
	}
	opID, out, err := rh.router.Delete(id)
	if err != nil {
		if errors.Is(err, ErrInvalidArgument) {
			return 0, err
		}
		rh.err = err
		return 0, err
	}
	rh.sendAll(out)
	if rh.err != nil {
		return 0, rh.err
	}
	return opID, nil
}

// Search fans a query out through the router and dispatches every leg's first
// attempt. A non-positive or oversized k comes back as ErrInvalidArgument,
// clean; any other router error poisons the host.
func (rh *RouterHost) Search(query []float32, k int) (uint64, error) {
	rh.mu.Lock()
	defer rh.mu.Unlock()
	if rh.err != nil {
		return 0, rh.err
	}
	opID, out, err := rh.router.Search(query, k)
	if err != nil {
		if errors.Is(err, ErrInvalidArgument) {
			return 0, err
		}
		rh.err = err
		return 0, err
	}
	rh.sendAll(out)
	if rh.err != nil {
		return 0, rh.err
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
