package cluster

import (
	"container/heap"
	"errors"
	"math/rand/v2"
	"sync"
)

// SimNet is the deterministic simulated network the whole cluster develops
// against before touching TCP. Its scheduler is a priority queue of delivery
// events ordered by (tick, sequence); every latency draw, drop, and duplicate
// comes from a single seeded generator, so one seed reproduces one exact
// delivery history. Faults are configuration, not code paths: reordering
// emerges from variable latency, partitions are directed edge blocks checked
// at delivery time, and a detached endpoint models a crashed node. Determinism
// is guaranteed when a single goroutine drives the simulation (the DST
// harness); the mutex only protects invariants if misused concurrently.
type SimNet struct {
	mu       sync.Mutex
	cfg      SimConfig
	rng      *rand.Rand
	clock    *ManualClock
	queue    eventHeap
	seq      uint64
	handlers map[NodeID]Handler
	blocked  map[[2]NodeID]bool
	stats    SimStats
	closed   bool
}

// SimConfig controls the fabric. Latencies are in ticks; probabilities are
// per message. MinLatency is clamped to at least 1 so a handler replying
// during delivery always schedules for a future tick and the simulation can
// never loop within a single tick.
type SimConfig struct {
	MinLatency Tick
	MaxLatency Tick
	DropProb   float64
	DupProb    float64
}

// DefaultSimConfig is a mildly jittery, fault-free network: latency 1 to 5
// ticks, no drops, no duplicates. Fault schedules belong to the DST harness.
func DefaultSimConfig() SimConfig {
	return SimConfig{MinLatency: 1, MaxLatency: 5}
}

// SimStats counts what the fabric actually did. The DST gate consumes these
// as coverage metrics: a fault schedule that never dropped, duplicated or
// blocked anything proves nothing (the illusory-coverage trap).
type SimStats struct {
	Sent               uint64
	Delivered          uint64
	DroppedByFault     uint64
	DroppedByPartition uint64
	DroppedNoReceiver  uint64
	Duplicated         uint64
}

type simEvent struct {
	deliverAt Tick
	seq       uint64
	from, to  NodeID
	data      []byte
}

// eventHeap orders events by delivery tick, tie-broken by sequence number so
// same-tick deliveries keep insertion order. Never iterate a map for this.
type eventHeap []*simEvent

func (h eventHeap) Len() int { return len(h) }
func (h eventHeap) Less(i, j int) bool {
	if h[i].deliverAt != h[j].deliverAt {
		return h[i].deliverAt < h[j].deliverAt
	}
	return h[i].seq < h[j].seq
}
func (h eventHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }
func (h *eventHeap) Push(x any)   { *h = append(*h, x.(*simEvent)) }
func (h *eventHeap) Pop() any {
	old := *h
	n := len(old)
	ev := old[n-1]
	old[n-1] = nil
	*h = old[:n-1]
	return ev
}

var (
	errSimNetClosed   = errors.New("cluster: simnet is closed")
	errEndpointClosed = errors.New("cluster: endpoint is closed")
)

// NewSimNet builds the fabric with its own manual clock at tick zero.
func NewSimNet(seed uint64, cfg SimConfig) *SimNet {
	if cfg.MinLatency < 1 {
		cfg.MinLatency = 1
	}
	if cfg.MaxLatency < cfg.MinLatency {
		cfg.MaxLatency = cfg.MinLatency
	}
	return &SimNet{
		cfg:      cfg,
		rng:      rand.New(rand.NewPCG(seed, 0)), //nolint:gosec // deterministic simulation requires a seeded generator, not crypto randomness
		clock:    &ManualClock{},
		handlers: make(map[NodeID]Handler),
		blocked:  make(map[[2]NodeID]bool),
	}
}

// Clock exposes the fabric's logical clock so nodes and the fabric share one
// notion of time.
func (s *SimNet) Clock() Clock { return s.clock }

// Endpoint attaches a node to the fabric with the handler that receives its
// inbound messages. Attaching an id that already exists replaces its handler,
// which is exactly the restart semantics the DST harness needs.
func (s *SimNet) Endpoint(id NodeID, h Handler) (Transport, error) {
	if id == None {
		return nil, errors.New("cluster: endpoint id 0 is reserved")
	}
	if h == nil {
		return nil, errors.New("cluster: endpoint handler is nil")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, errSimNetClosed
	}
	s.handlers[id] = h
	return &simEndpoint{net: s, id: id}, nil
}

// Detach removes a node from the fabric: messages addressed to it are dropped
// and counted, which is how the harness models a crashed node.
func (s *SimNet) Detach(id NodeID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.handlers, id)
}

// Partition blocks the directed link from -> to. The check happens at
// delivery time, so during a partition nothing crosses, including messages
// that were already in flight when the cable was cut. A symmetric partition
// is two calls, one per direction; the primitive stays asymmetric because
// real partitions are.
func (s *SimNet) Partition(from, to NodeID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blocked[[2]NodeID{from, to}] = true
}

// Heal unblocks the directed link from -> to.
func (s *SimNet) Heal(from, to NodeID) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.blocked, [2]NodeID{from, to})
}

// HealAll removes every partition.
func (s *SimNet) HealAll() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blocked = make(map[[2]NodeID]bool)
}

// Stats returns a copy of the fabric counters.
func (s *SimNet) Stats() SimStats {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stats
}

// Close shuts the fabric: pending events are discarded and later sends fail.
func (s *SimNet) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	s.queue = nil
	s.handlers = make(map[NodeID]Handler)
}

// Tick advances the clock by one and delivers everything due. Deliveries are
// popped in (tick, seq) order under the lock, then handlers run outside the
// lock so a handler may Send without deadlocking; anything it sends lands at
// least one tick in the future by the MinLatency clamp.
func (s *SimNet) Tick() {
	s.mu.Lock()
	s.clock.Advance()
	now := s.clock.Now()

	var due []*simEvent
	for len(s.queue) > 0 && s.queue[0].deliverAt <= now {
		due = append(due, heap.Pop(&s.queue).(*simEvent))
	}

	type delivery struct {
		h    Handler
		from NodeID
		data []byte
	}
	var out []delivery
	for _, ev := range due {
		if s.blocked[[2]NodeID{ev.from, ev.to}] {
			s.stats.DroppedByPartition++
			continue
		}
		h, ok := s.handlers[ev.to]
		if !ok {
			s.stats.DroppedNoReceiver++
			continue
		}
		s.stats.Delivered++
		out = append(out, delivery{h: h, from: ev.from, data: ev.data})
	}
	s.mu.Unlock()

	for _, d := range out {
		d.h(d.from, d.data)
	}
}

// RunTicks advances the simulation n ticks.
func (s *SimNet) RunTicks(n int) {
	for i := 0; i < n; i++ {
		s.Tick()
	}
}

// send applies the fault model in a fixed draw order (drop, then latency,
// then duplication) so the seeded generator's consumption, and therefore the
// whole history, is reproducible.
func (s *SimNet) send(from, to NodeID, data []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return errSimNetClosed
	}
	s.stats.Sent++

	if s.cfg.DropProb > 0 && s.rng.Float64() < s.cfg.DropProb {
		s.stats.DroppedByFault++
		return nil // network loss is silent, exactly like the real thing
	}

	s.enqueue(from, to, data)

	if s.cfg.DupProb > 0 && s.rng.Float64() < s.cfg.DupProb {
		s.stats.Duplicated++
		s.enqueue(from, to, data)
	}
	return nil
}

// enqueue schedules one copy with its own latency draw. The fabric owns its
// copy of the bytes so senders may reuse buffers.
func (s *SimNet) enqueue(from, to NodeID, data []byte) {
	span := uint64(s.cfg.MaxLatency - s.cfg.MinLatency + 1)
	latency := s.cfg.MinLatency + Tick(s.rng.Uint64N(span))
	buf := make([]byte, len(data))
	copy(buf, data)
	s.seq++
	heap.Push(&s.queue, &simEvent{
		deliverAt: s.clock.Now() + latency,
		seq:       s.seq,
		from:      from,
		to:        to,
		data:      buf,
	})
}

// simEndpoint is one node's handle onto the fabric. Once closed it refuses to
// send, honoring the Transport contract: a stopped node must fail loudly, not
// keep feeding the fabric in silence.
type simEndpoint struct {
	net *SimNet
	id  NodeID

	mu     sync.Mutex
	closed bool
}

// Send queues data for the destination through the fabric's fault model.
func (e *simEndpoint) Send(to NodeID, data []byte) error {
	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return errEndpointClosed
	}
	e.mu.Unlock()
	return e.net.send(e.id, to, data)
}

// Close detaches this node from the fabric and refuses further sends.
func (e *simEndpoint) Close() error {
	e.mu.Lock()
	e.closed = true
	e.mu.Unlock()
	e.net.Detach(e.id)
	return nil
}
