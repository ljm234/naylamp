package naylamp

import (
	"errors"
	"fmt"
	"math"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

// Router is the sans-io write coordinator: it turns a client Upsert or Delete
// into consensus traffic aimed at the right shard's leader, follows redirect
// hints, retries a bounded number of times across an election, and holds each
// operation's outcome for a one-shot Result. It owns no goroutines, no timers
// and no clock; the caller moves every frame. Timeouts arrive in a later piece
// with the fabric's clock, so today every operation terminates by a response or
// by exhausting its retry budget, never by time.
//
// Determinism rule: no path that emits a frame ranges a map. A target is chosen
// by slice index and a redirect hint by linear scan, and each HandleMessage
// processes exactly one response and emits at most one frame, so a seeded
// simulation replays a router's traffic identically.
type Router struct {
	id     cluster.NodeID
	shards cluster.ShardMap

	reqSeq uint64
	opSeq  uint64

	pending   map[uint64]pendingRef  // request id of a live attempt -> the op and leg it belongs to
	ops       map[uint64]*routeOp    // op id -> the write operation in flight
	searchOps map[uint64]*searchOp   // op id -> the search operation in flight
	results   map[uint64]RouteResult // op id -> its terminal (or exhausted) result
}

// pendingRef correlates a response to the attempt that provoked it. The
// correlation is by attempt AND by leg, because a search lives as independent
// legs and a response must find exactly its own; leg -1 marks a write.
type pendingRef struct {
	opID uint64
	leg  int
}

// routeOp is one write operation in flight: which command, which shard, which
// target within the shard's group, how many attempts remain, and the last
// retryable status seen so an exhausted op can report why it gave up.
type routeOp struct {
	op            ClientOp
	vecID         uint64
	vec           []float32
	shard         int
	targetIdx     int
	attemptsLeft  int
	lastRetryable ClientStatus
}

// searchLeg is one shard's fan-out of a search: which shard, which target in
// its group, how many attempts remain, the last retryable status it saw, the
// neighbors it returned, and whether it has answered.
type searchLeg struct {
	shard         int
	targetIdx     int
	attemptsLeft  int
	lastRetryable ClientStatus
	result        []vector.Neighbor
	done          bool
}

// searchOp is one scatter-gather search in flight: the query, k, one leg per
// shard, and how many legs are still outstanding.
type searchOp struct {
	query     []float32
	k         int
	legs      []searchLeg
	remaining int
}

// RouteResult is an operation's outcome. Status is terminal, StatusOK or
// StatusInvalidArgument, unless Exhausted is true, in which case Status carries
// the last retryable status seen (StatusNotLeader or StatusNotReady) and the
// caller decides whether to retry the whole operation. A write OK carries the
// commit Index; a search OK carries Neighbors and leaves Index zero.
type RouteResult struct {
	Status    ClientStatus
	Index     uint64
	Neighbors []vector.Neighbor
	Exhausted bool
}

// NewRouter builds a write coordinator over a shard map. The map is validated,
// and the router's own id may be neither the reserved zero nor a member of any
// group: a router that shared an id with a replica would hand that replica's
// consensus traffic to the router and hand a Node the client responses it
// declares fatal.
func NewRouter(id cluster.NodeID, m cluster.ShardMap) (*Router, error) {
	if err := m.Validate(); err != nil {
		return nil, err
	}
	if id == cluster.None {
		return nil, errors.New("naylamp: router id 0 is reserved")
	}
	for shard, g := range m.Groups {
		if g.Contains(id) {
			return nil, fmt.Errorf("naylamp: router id %d also serves shard %d; the router needs an identity of its own", id, shard)
		}
	}
	return &Router{
		id:        id,
		shards:    m,
		pending:   make(map[uint64]pendingRef),
		ops:       make(map[uint64]*routeOp),
		searchOps: make(map[uint64]*searchOp),
		results:   make(map[uint64]RouteResult),
	}, nil
}

// Upsert routes an add-or-replace to its shard and emits the first attempt. It
// returns the op id the caller polls Result with, the frames to send, and any
// error.
func (r *Router) Upsert(id uint64, vec []float32) (uint64, [][]byte, error) {
	return r.begin(ReqUpsert, id, vec)
}

// Delete routes a removal to its shard and emits the first attempt.
func (r *Router) Delete(id uint64) (uint64, [][]byte, error) {
	return r.begin(ReqDelete, id, nil)
}

// Search fans one query out to every shard, one leg each, and gathers the legs
// into a global top k once all have answered. It returns the op id to poll
// Result with, the first attempt of every leg, and any error. k must be
// positive, the same local API check Node.Search makes; the query's dimension
// is deliberately not checked here, because the router does not know it, so a
// replica answers a bad dimension with StatusInvalidArgument, which retires the
// operation.
func (r *Router) Search(query []float32, k int) (uint64, [][]byte, error) {
	if k <= 0 {
		return 0, nil, fmt.Errorf("%w: k must be positive, got %d", ErrInvalidArgument, k)
	}
	if uint64(k) > math.MaxUint32 {
		// The wire carries k as a uint32. Rejecting here keeps the bound in
		// the API, where validation policy lives, instead of letting the
		// encode narrow a request silently.
		return 0, nil, fmt.Errorf("%w: k %d exceeds the wire bound", ErrInvalidArgument, k)
	}
	r.opSeq++
	opID := r.opSeq
	o := &searchOp{
		query:     query,
		k:         k,
		legs:      make([]searchLeg, r.shards.K()),
		remaining: r.shards.K(),
	}
	for i := range o.legs {
		o.legs[i] = searchLeg{shard: i, targetIdx: 0, attemptsLeft: 3 * len(r.shards.Groups[i].Nodes)}
	}
	r.searchOps[opID] = o
	// The only function that emits more than one frame, and in a fixed order:
	// the first attempt of every leg, shard 0 to K-1, so a seeded run replays
	// the fan-out identically.
	var out [][]byte
	for i := range o.legs {
		frames, err := r.emitLegAttempt(opID, o, i)
		if err != nil {
			return 0, nil, err
		}
		out = append(out, frames...)
	}
	return opID, out, nil
}

// begin registers a write operation and emits its first attempt at target index
// zero, the deterministic starting point. The retry budget is three full passes
// over the shard's group: enough to ride out the churn of one election without
// permitting an infinite loop, and the bound is the promise the roadmap makes.
func (r *Router) begin(op ClientOp, id uint64, vec []float32) (uint64, [][]byte, error) {
	shard := r.shards.ShardFor(id)
	group := r.shards.Groups[shard].Nodes
	r.opSeq++
	opID := r.opSeq
	o := &routeOp{
		op:           op,
		vecID:        id,
		vec:          vec,
		shard:        shard,
		targetIdx:    0,
		attemptsLeft: 3 * len(group),
	}
	r.ops[opID] = o
	frames, err := r.emitAttempt(opID, o)
	if err != nil {
		return 0, nil, err
	}
	return opID, frames, nil
}

// emitAttempt sends the op's current attempt to its current target, or retires
// the op as exhausted when the retry budget is spent. It emits at most one
// frame. A retired op keeps the last retryable status it saw, so the caller
// learns whether the shard had no leader (NotLeader) or a young one (NotReady).
func (r *Router) emitAttempt(opID uint64, o *routeOp) ([][]byte, error) {
	if o.attemptsLeft == 0 {
		r.results[opID] = RouteResult{Status: o.lastRetryable, Exhausted: true}
		delete(r.ops, opID)
		return nil, nil
	}
	group := r.shards.Groups[o.shard].Nodes
	target := group[o.targetIdx].ID
	r.reqSeq++
	reqID := r.reqSeq
	r.pending[reqID] = pendingRef{opID: opID, leg: -1}
	o.attemptsLeft--
	// A write coordinator only carries upsert and delete, so the record id
	// always travels and k stays zero; a delete leaves Vec nil, which the codec
	// requires of it.
	frame, err := EncodeClientRequest(r.id, target, ClientRequest{Op: o.op, ReqID: reqID, ID: o.vecID, Vec: o.vec})
	if err != nil {
		return nil, err
	}
	return [][]byte{frame}, nil
}

// emitLegAttempt sends one leg's current attempt to its current target, or
// retires the WHOLE operation as exhausted when that leg's budget is spent. It
// emits at most one frame. When a leg exhausts, the sibling legs' pending
// entries are deliberately NOT cleaned: their late replies land on the stale
// path (op absent -> nil, nil), which is already deterministic.
func (r *Router) emitLegAttempt(opID uint64, o *searchOp, leg int) ([][]byte, error) {
	lg := &o.legs[leg]
	if lg.attemptsLeft == 0 {
		r.results[opID] = RouteResult{Status: lg.lastRetryable, Exhausted: true}
		delete(r.searchOps, opID)
		return nil, nil
	}
	group := r.shards.Groups[lg.shard].Nodes
	target := group[lg.targetIdx].ID
	r.reqSeq++
	reqID := r.reqSeq
	r.pending[reqID] = pendingRef{opID: opID, leg: leg}
	lg.attemptsLeft--
	k := uint32(o.k) //nolint:gosec // the API bounds k to uint32, so the conversion cannot truncate
	frame, err := EncodeClientRequest(r.id, target, ClientRequest{Op: ReqSearch, ReqID: reqID, K: k, Vec: o.query})
	if err != nil {
		return nil, err
	}
	return [][]byte{frame}, nil
}

// HandleMessage processes one response frame and re-emits or retires the
// operation it belongs to. A frame that is not a client response, or one that
// does not decode, is fatal: responses reach a router only from our own
// replicas, so either can only be a routing bug or version skew inside the
// cluster, never a value to act on.
func (r *Router) HandleMessage(data []byte) ([][]byte, error) {
	env, err := cluster.DecodeMessage(data)
	if err != nil {
		return nil, err
	}
	if env.Kind != ClientRespKind {
		// Only responses reach a router: it emits requests and awaits replies.
		// A request or a consensus frame here can only be a routing bug.
		return nil, fmt.Errorf("naylamp: router received a non-response envelope kind %d", env.Kind)
	}
	resp, err := DecodeClientResponse(env)
	if err != nil {
		// These replies come from our own replicas, not from remote clients, so
		// a body that will not parse is corruption or version skew inside the
		// cluster and stays fatal. The asymmetry with the Node's silent drop of
		// a malformed request is deliberate: the direction of trust differs.
		return nil, fmt.Errorf("naylamp: router got an undecodable response: %w", err)
	}

	ref, live := r.pending[resp.ReqID]
	if !live {
		// A late or duplicate reply for an attempt already superseded: there is
		// no live request under this id. Dropping it is the only deterministic
		// choice, and it is also how a sibling leg's late reply lands after its
		// operation was retired by another leg's exhaust.
		return nil, nil
	}
	delete(r.pending, resp.ReqID)
	if ref.leg < 0 {
		return r.handleWriteResponse(ref.opID, resp)
	}
	return r.handleSearchResponse(ref.opID, ref.leg, resp)
}

// handleWriteResponse advances or completes one write: OK records the commit
// index and retires the op, InvalidArgument is terminal, and a retryable status
// re-emits after following any usable redirect hint.
func (r *Router) handleWriteResponse(opID uint64, resp ClientResponse) ([][]byte, error) {
	o, ok := r.ops[opID]
	if !ok {
		return nil, nil
	}
	switch resp.Status {
	case StatusOK:
		if resp.Index == 0 {
			// A write acknowledges with the log index it committed under. An OK
			// with a zero index can only be a crossed search reply or
			// corruption; it is not the write ack this router awaits.
			return nil, fmt.Errorf("naylamp: router got a StatusOK write ack with a zero index")
		}
		r.results[opID] = RouteResult{Status: StatusOK, Index: resp.Index}
		delete(r.ops, opID)
		return nil, nil
	case StatusInvalidArgument:
		r.results[opID] = RouteResult{Status: StatusInvalidArgument}
		delete(r.ops, opID)
		return nil, nil
	case StatusNotLeader:
		o.lastRetryable = StatusNotLeader
		group := r.shards.Groups[o.shard].Nodes
		if pos, found := groupIndex(group, resp.Leader); found && resp.Leader != cluster.None {
			o.targetIdx = pos // the hint knows the leader; obey it
		} else {
			// No usable hint: zero means the replica knows no leader, and an
			// id outside the group cannot be obeyed. Probe the next member.
			o.targetIdx = (o.targetIdx + 1) % len(group)
		}
		return r.emitAttempt(opID, o)
	case StatusNotReady:
		o.lastRetryable = StatusNotReady
		// The leader exists but has no commit in its term yet; the same target
		// just needs another try.
		return r.emitAttempt(opID, o)
	default:
		// DecodeClientResponse already rejects an unknown status, so this is
		// unreachable; it keeps the switch total.
		return nil, fmt.Errorf("naylamp: router got an unknown status %d", resp.Status)
	}
}

// handleSearchResponse advances or completes one leg of a search. A leg's OK
// carries its neighbors, and an empty list is legitimate because a shard may
// hold no data for the query; the last leg to answer merges every leg's list,
// indexed by shard for a deterministic order, into the global top k. An
// InvalidArgument from any leg retires the whole operation, and a retryable
// status re-emits that leg alone.
func (r *Router) handleSearchResponse(opID uint64, leg int, resp ClientResponse) ([][]byte, error) {
	o, ok := r.searchOps[opID]
	if !ok {
		return nil, nil
	}
	lg := &o.legs[leg]
	switch resp.Status {
	case StatusOK:
		if resp.Index != 0 {
			// A search leg answers with neighbors and a zero index. A nonzero
			// index can only be a crossed write ack or corruption, the exact
			// mirror of the write path's zero-index guard.
			return nil, fmt.Errorf("naylamp: router got a StatusOK search reply with a nonzero index %d", resp.Index)
		}
		lg.result = resp.Neighbors
		if !lg.done {
			lg.done = true
			o.remaining--
		}
		if o.remaining == 0 {
			lists := make([][]vector.Neighbor, len(o.legs))
			for i := range o.legs {
				lists[o.legs[i].shard] = o.legs[i].result
			}
			r.results[opID] = RouteResult{Status: StatusOK, Neighbors: mergeTopK(lists, o.k)}
			delete(r.searchOps, opID)
		}
		return nil, nil
	case StatusInvalidArgument:
		r.results[opID] = RouteResult{Status: StatusInvalidArgument}
		delete(r.searchOps, opID)
		return nil, nil
	case StatusNotLeader:
		lg.lastRetryable = StatusNotLeader
		group := r.shards.Groups[lg.shard].Nodes
		if pos, found := groupIndex(group, resp.Leader); found && resp.Leader != cluster.None {
			lg.targetIdx = pos // the hint knows the leader; obey it
		} else {
			lg.targetIdx = (lg.targetIdx + 1) % len(group)
		}
		return r.emitLegAttempt(opID, o, leg)
	case StatusNotReady:
		lg.lastRetryable = StatusNotReady
		return r.emitLegAttempt(opID, o, leg)
	default:
		return nil, fmt.Errorf("naylamp: router got an unknown status %d", resp.Status)
	}
}

// Result reports an operation's outcome once, then forgets it, exactly like
// ReadServable on a node: an unknown or still-pending op returns false.
func (r *Router) Result(opID uint64) (RouteResult, bool) {
	res, ok := r.results[opID]
	if !ok {
		return RouteResult{}, false
	}
	delete(r.results, opID)
	return res, true
}

// groupIndex returns the position of id in a group and whether it is a member.
// It is a linear scan, not a map lookup: groups are tiny and the emission path
// must stay free of map ranges for determinism. The caller guards the reserved
// zero id itself, so this scan stays a pure membership question.
func groupIndex(nodes []cluster.NodeAddr, id cluster.NodeID) (int, bool) {
	for i := range nodes {
		if nodes[i].ID == id {
			return i, true
		}
	}
	return 0, false
}
