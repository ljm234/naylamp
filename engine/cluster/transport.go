package cluster

// Tick is the unit of logical time in the cluster. Nothing in the consensus
// core reads the wall clock: time advances only when ticks are fed in, which
// is what makes a whole simulated cluster reproducible under a single seed.
type Tick uint64

// Clock exposes the current logical tick. The simulator advances a ManualClock
// explicitly; the real runtime (3.3) adapts wall time into ticks at its edge,
// keeping the core pure.
type Clock interface {
	Now() Tick
}

// ManualClock is a Clock advanced by hand, for the simulator and tests.
type ManualClock struct {
	tick Tick
}

// Now returns the current tick.
func (c *ManualClock) Now() Tick { return c.tick }

// Advance moves the clock forward by one tick.
func (c *ManualClock) Advance() { c.tick++ }

// AdvanceBy moves the clock forward by n ticks.
func (c *ManualClock) AdvanceBy(n Tick) { c.tick += n }

// Handler receives one inbound message. The simulated fabric calls it
// synchronously on its scheduling loop; the TCP transport may call it from
// reader goroutines, so receivers needing serialization must provide their
// own. The data slice belongs to the receiver once the call returns.
type Handler func(from NodeID, data []byte)

// Transport is one node's handle onto the network: it knows its own identity,
// so Send only names the destination. Each node constructs its endpoint with
// the Handler that will receive its inbound messages. The delivery contract
// is deliberately weak, matching what a real network gives a consensus
// protocol: at-most-once, unordered, and under fault injection messages may
// be dropped, delayed, duplicated or reordered. Anything stronger must be
// built above this interface, never assumed of it.
type Transport interface {
	// Send queues data for delivery to the given node. A nil error means the
	// message was accepted for sending, not that it arrived. Implementations
	// copy data, so the caller may reuse its buffer after Send returns.
	Send(to NodeID, data []byte) error

	// Close releases this endpoint. Sends after Close return an error.
	Close() error
}
