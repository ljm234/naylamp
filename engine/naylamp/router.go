package naylamp

import (
	"errors"
	"fmt"
	"math"
	"sort"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

// Router is the sans-io write coordinator: it turns a client Upsert or Delete
// into consensus traffic aimed at the right shard's leader, follows redirect
// hints, retries a bounded number of times across an election, and holds each
// operation's outcome for a one-shot Result. It owns no goroutines and no
// timers, and reads no wall clock: the caller moves every frame and advances a
// logical clock through Tick, so an operation terminates by a response, by
// exhausting its retry budget, or by timing out an unanswered attempt, never by
// wall time. A Router the caller never ticks behaves as it did before timeouts.
//
// Determinism rule: no path that emits a frame ranges a map. A target is chosen
// by slice index and a redirect hint by linear scan; each HandleMessage
// processes exactly one response and emits at most one frame; and Tick collects
// the due attempts out of its pending map but sorts them by request id before
// emitting a single frame, so a seeded simulation replays a router's traffic
// identically.
type Router struct {
	id     cluster.NodeID
	shards cluster.ShardMap

	reqSeq uint64
	opSeq  uint64

	// now is the Router's logical clock, advanced only by Tick and read only to
	// stamp and time out attempts. It stays 0 until the caller first ticks, so a
	// Router nobody ticks stamps every attempt at 0 and never times one out.
	now cluster.Tick

	pending   map[uint64]pendingRef  // request id of a live attempt -> the op and leg it belongs to
	ops       map[uint64]*routeOp    // op id -> the write operation in flight
	searchOps map[uint64]*searchOp   // op id -> the search operation in flight
	results   map[uint64]RouteResult // op id -> its terminal (or exhausted) result

	// Timeout-rotation tuning, all inert unless rotateOnTimeout is set. When it is
	// off the coordinator behaves exactly as it did before rotation existed, and
	// retransmitTicks alone is read, defaulting to retransmitTimeout so the sealed
	// timeout behavior is unchanged.
	rotateOnTimeout     bool
	rotateAfterTimeouts int          // consecutive timeouts against a target before abandoning it
	retransmitTicks     cluster.Tick // unanswered-attempt timeout before a resend or rotation
	probeTicks          cluster.Tick // paced peer-probe cadence while a mute hint is suppressed
	suppressCooldown    cluster.Tick // how long a redirect hint back to an abandoned target is ignored
}

// rotState is the per-target rotation state a routeOp or a searchLeg carries,
// used only when rotateOnTimeout is set and otherwise left at its zero value.
// timeouts counts consecutive retransmit timeouts against the current target; on
// the rotateAfterTimeouts-th the target is abandoned. suppressedTarget and
// suppressUntil hold a bounded cooldown during which a redirect hint back to that
// abandoned target is ignored, so a leader that has gone mute toward this client
// cannot bounce the operation straight back to itself; the cooldown auto-heals on
// expiry, so a leader whose egress recovered is reachable again. holdUntil parks
// the operation between paced peer probes while the hint is suppressed, so a peer
// is reached every probe cadence without a tight re-emit loop spending the whole
// retry budget at once.
type rotState struct {
	timeouts         int
	suppressedTarget cluster.NodeID
	suppressUntil    cluster.Tick
	holdUntil        cluster.Tick
}

// pendingRef correlates a response to the attempt that provoked it. The
// correlation is by attempt AND by leg, because a search lives as independent
// legs and a response must find exactly its own; leg -1 marks a write.
// emittedAt records the tick the attempt went out on, so Tick can time out and
// retransmit a frame that was lost (DEFER-011). target records the node the
// attempt was aimed at, so a reply bearing this reqID from any other node is
// dropped as stale and never resolves the operation (DEFER-012).
type pendingRef struct {
	opID      uint64
	leg       int
	emittedAt cluster.Tick
	target    cluster.NodeID
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
	rot           rotState
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
	rot           rotState
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

// RouterOptions tunes a coordinator's retry behavior. Its zero value is the
// historical coordinator: no target rotation on timeout and the default
// retransmit budget. RotateOnTimeout turns on the timeout-driven target rotation
// and the redirect-hint suppression that pair with the core's service-health
// signal; the two are one feature and must be enabled together, since rotating
// without the signal reopens the mute-leader hint bounce and the signal without
// rotating deadlocks the recovery. The tuning fields fall back to their defaults
// when left zero.
type RouterOptions struct {
	RotateOnTimeout bool
	// RotateAfterTimeouts is how many consecutive timeouts against one target the
	// coordinator tolerates before abandoning it; below it a retransmit re-aims at
	// the same target, exactly as it did before rotation existed, so a single lost
	// frame never moves the target. Zero uses defaultRotateAfterTimeouts.
	RotateAfterTimeouts int
	// RetransmitTicks is how long an attempt may go unanswered before a Tick
	// resends or rotates it. Zero uses retransmitTimeout.
	RetransmitTicks cluster.Tick
	// ProbeTicks is the cadence at which a parked operation probes a peer while a
	// mute leader's hint is suppressed, kept near one election window so a peer is
	// reached every window without burning the retry budget in a tight loop. Zero
	// uses defaultProbeTicks.
	ProbeTicks cluster.Tick
	// SuppressCooldown is how long a redirect hint back to an abandoned target is
	// ignored. It is bounded and auto-healing: once it elapses the target is
	// eligible again, so a leader whose egress recovered is not stranded. Zero uses
	// RetransmitTicks, so the cooldown scales with the retransmit budget.
	SuppressCooldown cluster.Tick
}

// defaultRotateAfterTimeouts keeps a lost frame from moving the target: the first
// timeout re-aims at the same node, exactly as the plain retransmit does, and only
// a second consecutive silence abandons it. defaultProbeTicks is the paced peer
// probe cadence, near one default election window so a peer is reached every
// window while a mute leader's hint is suppressed.
const (
	defaultRotateAfterTimeouts              = 2
	defaultProbeTicks          cluster.Tick = 10
)

// NewRouter builds a write coordinator over a shard map with the default options
// (no timeout rotation), byte-for-byte the historical coordinator.
func NewRouter(id cluster.NodeID, m cluster.ShardMap) (*Router, error) {
	return NewRouterWithOptions(id, m, RouterOptions{})
}

// NewRouterWithOptions builds a coordinator with explicit retry options. The map
// is validated, and the router's own id may be neither the reserved zero nor a
// member of any group: a router that shared an id with a replica would hand that
// replica's consensus traffic to the router and hand a Node the client responses
// it declares fatal.
func NewRouterWithOptions(id cluster.NodeID, m cluster.ShardMap, opts RouterOptions) (*Router, error) {
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
	r := &Router{
		id:                  id,
		shards:              m,
		pending:             make(map[uint64]pendingRef),
		ops:                 make(map[uint64]*routeOp),
		searchOps:           make(map[uint64]*searchOp),
		results:             make(map[uint64]RouteResult),
		rotateOnTimeout:     opts.RotateOnTimeout,
		rotateAfterTimeouts: defaultRotateAfterTimeouts,
		retransmitTicks:     retransmitTimeout,
		probeTicks:          defaultProbeTicks,
	}
	if opts.RotateAfterTimeouts > 0 {
		r.rotateAfterTimeouts = opts.RotateAfterTimeouts
	}
	if opts.RetransmitTicks > 0 {
		r.retransmitTicks = opts.RetransmitTicks
	}
	if opts.ProbeTicks > 0 {
		r.probeTicks = opts.ProbeTicks
	}
	r.suppressCooldown = r.retransmitTicks
	if opts.SuppressCooldown > 0 {
		r.suppressCooldown = opts.SuppressCooldown
	}
	return r, nil
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
	// emittedAt stamps this attempt for the DEFER-011 retransmit timeout, and
	// target records where it was aimed for the DEFER-012 stale-origin drop.
	r.pending[reqID] = pendingRef{opID: opID, leg: -1, emittedAt: r.now, target: target}
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
	// emittedAt stamps this attempt for the DEFER-011 retransmit timeout, and
	// target records where it was aimed for the DEFER-012 stale-origin drop.
	r.pending[reqID] = pendingRef{opID: opID, leg: leg, emittedAt: r.now, target: target}
	lg.attemptsLeft--
	k := uint32(o.k) //nolint:gosec // the API bounds k to uint32, so the conversion cannot truncate
	frame, err := EncodeClientRequest(r.id, target, ClientRequest{Op: ReqSearch, ReqID: reqID, K: k, Vec: o.query})
	if err != nil {
		return nil, err
	}
	return [][]byte{frame}, nil
}

// retransmitTimeout is how many ticks an attempt may go unanswered before Tick
// resends it. It sits above a full randomized election window (raft resets its
// election in [ElectionTicks, 2*ElectionTicks), 10 to 20 ticks by default), so
// a retransmit does not fire while a leader is merely being elected, yet it is
// short enough to recover a dropped frame within a couple of election cycles.
const retransmitTimeout cluster.Tick = 50

// Tick advances the Router's logical clock to now and retransmits every live
// attempt that has gone unanswered for at least retransmitTimeout ticks
// (DEFER-011). now is monotonic: it is the fabric's clock, which only advances.
// A retransmit walks the SAME re-emission path a retryable response takes,
// emitAttempt for a write and emitLegAttempt for a search leg, so it spends one
// attempt from the op's budget and retires the op as exhausted on the last try,
// exactly as a live response would; retransmitting is idempotent at the router
// because the superseded attempt's request id is consumed, so at most one reply
// ever resolves the op.
//
// The clock is the argument, never time.Now, so a seeded simulation feeds the
// same ticks and replays the same retransmissions. To hold the determinism rule
// that no emitting path ranges a map, the due attempts are gathered from
// r.pending and sorted by request id, and only then does the loop emit, in the
// attempts' own emission order.
func (r *Router) Tick(now cluster.Tick) ([][]byte, error) {
	r.now = now
	var out [][]byte

	// Phase 1: retransmit due pending attempts. Gather first, emit second: ranging
	// r.pending only collects the due request ids into a slice; the sorted slice
	// below is what the emitting loop walks. With rotation on, retransmit also
	// counts the timeout toward abandoning a silent target.
	var due []uint64
	for reqID, ref := range r.pending {
		if now-ref.emittedAt >= r.retransmitTicks {
			due = append(due, reqID)
		}
	}
	sort.Slice(due, func(i, j int) bool { return due[i] < due[j] })
	for _, reqID := range due {
		ref, ok := r.pending[reqID]
		if !ok {
			// A retransmit earlier in this same tick already retired the op and
			// swept this leg's entry: nothing is left to resend.
			continue
		}
		// Consume the timed-out attempt before re-emitting, exactly as the
		// response path deletes the old request id before emitAttempt hands out a
		// fresh one. A late reply for this id now lands on the stale path.
		delete(r.pending, reqID)
		frames, err := r.retransmit(ref)
		if err != nil {
			return nil, err
		}
		out = append(out, frames...)
	}

	// Phase 2: re-probe parked operations whose paced hold has elapsed, so a peer
	// keeps being reached while a mute leader's hint is suppressed. Inert unless
	// rotation is on, so an idle tick with nothing due stays byte-for-byte a no-op.
	if r.rotateOnTimeout {
		frames, err := r.probeHeld(now)
		if err != nil {
			return nil, err
		}
		out = append(out, frames...)
	}
	return out, nil
}

// probeHeld re-probes every parked operation whose hold has elapsed, one paced
// peer probe each, so a peer keeps being reached while a mute leader's hint is
// suppressed. Writes are gathered and emitted in op-id order and search legs in
// (op-id, leg) order, so no emitting path ranges a map for its order and a seeded
// run replays the probes identically.
func (r *Router) probeHeld(now cluster.Tick) ([][]byte, error) {
	var out [][]byte

	var writeIDs []uint64
	for opID, o := range r.ops {
		if o.rot.holdUntil != 0 && now >= o.rot.holdUntil {
			writeIDs = append(writeIDs, opID)
		}
	}
	sort.Slice(writeIDs, func(i, j int) bool { return writeIDs[i] < writeIDs[j] })
	for _, opID := range writeIDs {
		o := r.ops[opID]
		o.rot.holdUntil = 0
		group := r.shards.Groups[o.shard].Nodes
		o.targetIdx = nextLiveTarget(group, o.targetIdx, &o.rot, now)
		frames, err := r.emitAttempt(opID, o)
		if err != nil {
			return nil, err
		}
		out = append(out, frames...)
	}

	type heldLeg struct {
		opID uint64
		leg  int
	}
	var legs []heldLeg
	for opID, o := range r.searchOps {
		for i := range o.legs {
			if o.legs[i].rot.holdUntil != 0 && now >= o.legs[i].rot.holdUntil {
				legs = append(legs, heldLeg{opID: opID, leg: i})
			}
		}
	}
	sort.Slice(legs, func(i, j int) bool {
		if legs[i].opID != legs[j].opID {
			return legs[i].opID < legs[j].opID
		}
		return legs[i].leg < legs[j].leg
	})
	for _, hl := range legs {
		o := r.searchOps[hl.opID]
		if o == nil {
			// A prior held leg of this same op already retired the whole search
			// (its budget was spent), so this sibling leg has nothing left to
			// probe. Skip it, the same way the retransmit path drops a leg whose
			// op is already gone.
			continue
		}
		lg := &o.legs[hl.leg]
		lg.rot.holdUntil = 0
		group := r.shards.Groups[lg.shard].Nodes
		lg.targetIdx = nextLiveTarget(group, lg.targetIdx, &lg.rot, now)
		frames, err := r.emitLegAttempt(hl.opID, o, hl.leg)
		if err != nil {
			return nil, err
		}
		out = append(out, frames...)
	}
	return out, nil
}

// nextLiveTarget returns the next target index after from, skipping a target
// under an active suppression cooldown. With nothing suppressed, which is always
// the case while rotation is off and also once a cooldown elapses, it is a plain
// round-robin step, byte-for-byte the old hintless rotation. If every member is
// the suppressed one it steps anyway, so an operation never deadlocks on an empty
// choice.
func nextLiveTarget(group []cluster.NodeAddr, from int, rot *rotState, now cluster.Tick) int {
	n := len(group)
	suppressed := rot.suppressedTarget != cluster.None && now < rot.suppressUntil
	for step := 1; step <= n; step++ {
		idx := (from + step) % n
		if !suppressed || group[idx].ID != rot.suppressedTarget {
			return idx
		}
	}
	return (from + 1) % n
}

// hintSuppressed reports whether a redirect hint points at a target still under
// its cooldown, which the coordinator declines to obey so a mute leader cannot
// bounce the operation straight back to itself.
func (r *Router) hintSuppressed(rot *rotState, hint cluster.NodeID) bool {
	return rot.suppressedTarget != cluster.None && r.now < rot.suppressUntil && hint == rot.suppressedTarget
}

// onTimeout advances one target's rotation state after it timed out. Below the
// threshold it leaves the target in place, so the retransmit re-aims at the same
// node exactly as it did before rotation existed; at the threshold it abandons the
// silent target under a bounded cooldown and rotates to the next live member.
func (r *Router) onTimeout(group []cluster.NodeAddr, targetIdx *int, rot *rotState) {
	rot.timeouts++
	if rot.timeouts < r.rotateAfterTimeouts {
		return
	}
	rot.timeouts = 0
	rot.suppressedTarget = group[*targetIdx].ID
	rot.suppressUntil = r.now + r.suppressCooldown
	*targetIdx = nextLiveTarget(group, *targetIdx, rot, r.now)
}

// retransmit re-emits one timed-out attempt down the same path a retryable
// response would: emitAttempt for a write, emitLegAttempt for a search leg. If
// the operation was already retired, by a terminal reply or by a sibling leg's
// exhaust, there is nothing to resend and the orphaned entry, already deleted by
// the caller, simply stays gone.
func (r *Router) retransmit(ref pendingRef) ([][]byte, error) {
	if ref.leg < 0 {
		o, ok := r.ops[ref.opID]
		if !ok {
			return nil, nil
		}
		if r.rotateOnTimeout {
			r.onTimeout(r.shards.Groups[o.shard].Nodes, &o.targetIdx, &o.rot)
		}
		return r.emitAttempt(ref.opID, o)
	}
	o, ok := r.searchOps[ref.opID]
	if !ok {
		return nil, nil
	}
	if r.rotateOnTimeout {
		lg := &o.legs[ref.leg]
		r.onTimeout(r.shards.Groups[lg.shard].Nodes, &lg.targetIdx, &lg.rot)
	}
	return r.emitLegAttempt(ref.opID, o, ref.leg)
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
	return r.HandleEnvelope(env)
}

// HandleEnvelope handles one already decoded response envelope. The RouterHost
// decodes to check who sent it and calls this, so the frame is parsed once
// rather than once per layer.
func (r *Router) HandleEnvelope(env cluster.Envelope) ([][]byte, error) {
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

	// DEFER-012: a response resolves an operation only when it comes from the
	// exact node the live attempt was aimed at. A frame carrying our reqID but a
	// From other than that target is a superseded replica answering late, after
	// the op advanced to a new target; correlating it would let a stale node
	// resolve the operation. Drop it and leave the attempt live for the real
	// target's reply. A reply from the right target is untouched, so the check is
	// purely additive.
	if held, ok := r.pending[resp.ReqID]; ok && env.From != held.target {
		return nil, nil
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
	if r.rotateOnTimeout {
		o.rot.timeouts = 0 // any answer proves this target is not silent
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
		return r.redirectWrite(opID, o, resp.Leader)
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

// redirectWrite advances one write past a NotLeader. With rotation on, a hint
// back to a suppressed mute leader is not obeyed: the operation parks and Tick
// probes a peer at the paced cadence until the cooldown heals or the hint points
// elsewhere. Any usable hint is obeyed, and a hintless answer rotates to the next
// live member, which reduces to the plain round-robin when nothing is suppressed.
func (r *Router) redirectWrite(opID uint64, o *routeOp, hint cluster.NodeID) ([][]byte, error) {
	group := r.shards.Groups[o.shard].Nodes
	if r.rotateOnTimeout && r.hintSuppressed(&o.rot, hint) {
		o.rot.holdUntil = r.now + r.probeTicks
		return nil, nil
	}
	if pos, found := groupIndex(group, hint); found && hint != cluster.None {
		o.targetIdx = pos // the hint knows the leader; obey it
	} else {
		// No usable hint: zero means the replica knows no leader, and an id
		// outside the group cannot be obeyed. Probe the next live member.
		o.targetIdx = nextLiveTarget(group, o.targetIdx, &o.rot, r.now)
	}
	return r.emitAttempt(opID, o)
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
	if r.rotateOnTimeout {
		lg.rot.timeouts = 0 // any answer proves this target is not silent
	}
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
		return r.redirectLeg(opID, o, leg, resp.Leader)
	case StatusNotReady:
		lg.lastRetryable = StatusNotReady
		return r.emitLegAttempt(opID, o, leg)
	default:
		return nil, fmt.Errorf("naylamp: router got an unknown status %d", resp.Status)
	}
}

// redirectLeg advances one search leg past a NotLeader, the search-side mirror of
// redirectWrite: a hint back to a suppressed mute leader parks the leg for a paced
// probe, any usable hint is obeyed, and a hintless answer rotates to the next live
// member.
func (r *Router) redirectLeg(opID uint64, o *searchOp, leg int, hint cluster.NodeID) ([][]byte, error) {
	lg := &o.legs[leg]
	group := r.shards.Groups[lg.shard].Nodes
	if r.rotateOnTimeout && r.hintSuppressed(&lg.rot, hint) {
		lg.rot.holdUntil = r.now + r.probeTicks
		return nil, nil
	}
	if pos, found := groupIndex(group, hint); found && hint != cluster.None {
		lg.targetIdx = pos // the hint knows the leader; obey it
	} else {
		lg.targetIdx = nextLiveTarget(group, lg.targetIdx, &lg.rot, r.now)
	}
	return r.emitLegAttempt(opID, o, leg)
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
