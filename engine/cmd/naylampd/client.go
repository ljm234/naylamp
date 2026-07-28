package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"naylamp/engine/cluster"
	"naylamp/engine/naylamp"
)

// clientID is this client's identity on the fabric. It is a member of no shard
// group, so a node never confuses its traffic with a peer's, and it is the id a
// node must be told with -client so it can dial the client back.
const clientID cluster.NodeID = 90

// reemitInterval is how long the client waits for a result before re-emitting on
// a rotated view. It is short enough to recover a lost response within a human
// scale deadline, and long enough that a healthy operation resolves inside one
// window without a redundant re-emission.
const reemitInterval = 400 * time.Millisecond

// groupFlag accumulates repeated -group values, one shard each, in order.
type groupFlag []string

func (g *groupFlag) String() string { return strings.Join(*g, ";") }

func (g *groupFlag) Set(v string) error {
	*g = append(*g, v)
	return nil
}

// runClient runs a single routing operation over mutual TLS and exits: status 0
// when the result is StatusOK, status 1 on any failure (the deadline elapsed, a
// poisoned router, or a terminal non-OK status), and status 2 on a usage error.
// It is not interactive: the operation is chosen by -op and its arguments, the
// result is printed to stdout in a parseable form, and there is no REPL and no
// stdin. Within the deadline the operation is re-emitted on a rotated view every
// reemitInterval, because the transport is at-most-once and the router does not
// retry replies; a single emission whose response is lost would otherwise hang.
func runClient(args []string) {
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	var listen, op, vecArg string
	var groups groupFlag
	var id uint64
	var k, dim, count int
	var deadline, poll, tick time.Duration
	var serviceHealth, timing bool
	fs.StringVar(&listen, "listen", "", "this client's own listen address host:port (required)")
	fs.Var(&groups, "group", "one shard as id=addr,id=addr (repeatable, at least one required)")
	fs.StringVar(&op, "op", "", "operation: put, del, or search (required)")
	fs.Uint64Var(&id, "id", 0, "vector id for put and del")
	fs.StringVar(&vecArg, "vec", "", "vector as f,f,f for put and search")
	fs.IntVar(&k, "k", 10, "number of neighbors to return for search")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.DurationVar(&deadline, "deadline", 5*time.Second, "deadline for the operation's result")
	fs.DurationVar(&poll, "poll", 20*time.Millisecond, "result poll interval")
	fs.BoolVar(&serviceHealth, "service-health", false, "drive a continuous ticked load over one rotating router; off by default, one feature with the node -service-health, so enable both or neither")
	fs.BoolVar(&timing, "timing", false, "print one timing line per operation to stdout, after the result; off by default, and off means byte-identical output")
	fs.IntVar(&count, "count", 1, "operations the continuous load re-issues; above 1 requires -service-health")
	fs.DurationVar(&tick, "tick", 10*time.Millisecond, "router tick period under -service-health, matching the node -tick")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylampd client -listen ADDR -group id=addr,... -op OP [args]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "TLS material is read from NAYLAMP_TLS_CERT, NAYLAMP_TLS_KEY, and NAYLAMP_TLS_CA")
	}
	_ = fs.Parse(args)

	if listen == "" || len(groups) == 0 || op == "" {
		fmt.Fprintln(os.Stderr, "client: -listen, at least one -group, and -op are required")
		fs.Usage()
		os.Exit(2)
	}

	// A count above one is continuous load, which only the service-health feature
	// drives, so refuse it here rather than silently running one operation and
	// ignoring the flag. Validated before the network so a usage error costs
	// nothing on the wire and exits 2, not 1.
	if count != 1 && !serviceHealth {
		fmt.Fprintln(os.Stderr, "client: -count above 1 requires -service-health; continuous load is part of that feature")
		os.Exit(2)
	}

	// The continuous load has its own reporting and does not time individual
	// operations, so accepting -timing there would take the flag and print
	// nothing. Refused for the same reason -count is refused above: a flag that
	// is silently ignored is worse than one that is rejected.
	if timing && serviceHealth {
		fmt.Fprintln(os.Stderr, "client: -timing does not apply under -service-health; that load reports its own tally, not per-operation times")
		os.Exit(2)
	}

	// Validate the operation and its arguments before touching the network, so a
	// usage error costs nothing on the wire and exits 2, not 1.
	emit, describe, verr := buildOp(op, id, vecArg, k, dim)
	if verr != nil {
		fmt.Fprintf(os.Stderr, "client: %v\n", verr)
		os.Exit(2)
	}

	parsed := make([][]nodeAddr, 0, len(groups))
	for i, g := range groups {
		nodes, perr := parseNodeList(g)
		if perr != nil {
			fmt.Fprintf(os.Stderr, "client: bad -group %d (%q): %v\n", i, g, perr)
			os.Exit(2)
		}
		if len(nodes) == 0 {
			fmt.Fprintf(os.Stderr, "client: empty -group %d\n", i)
			os.Exit(2)
		}
		parsed = append(parsed, nodes)
	}

	mat, err := tlsMaterialFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "client: %v\n", err)
		os.Exit(2)
	}

	// One transport for the whole run, built once with a swapping trampoline so a
	// rotated view can repoint the inbound handler without tearing down the
	// listener. The nodes dial this client back by its id, so the listener must
	// outlive every re-emission.
	swap := &handlerSwap{}
	tr, err := cluster.NewTCPTransport(clientID, listen, swap.deliver, mat)
	if err != nil {
		fmt.Fprintf(os.Stderr, "client: tcp listen %s: %v\n", listen, err)
		os.Exit(1)
	}
	defer func() { _ = tr.Close() }()
	for _, g := range parsed {
		for _, na := range g {
			tr.AddPeer(na.id, na.addr)
		}
	}

	// Under -service-health the client runs a different recovery: one long-lived
	// router with timeout rotation on, ticked so the rotation and peer probe wake,
	// carrying a continuous load. It never returns.
	if serviceHealth {
		runClientReach(parsed, emit, describe, swap, tr, count, tick, deadline, poll)
	}

	// Emit, poll for a result, and re-emit on a rotated view every reemitInterval
	// until the deadline. A single emission is not enough against the real
	// transport: it is at-most-once and the router does not retry replies
	// (DEFER-011), so a lost response, for example one sent on a stale link the
	// leader cached toward a previous client process at this same identity, would
	// hang forever. The client is the protocol above the transport, where retries
	// belong. All three operations are idempotent under re-emission: an upsert of
	// the same id and vector, a delete, and a read-only search, and a committed
	// duplicate is legitimate under the log-fidelity semantics.
	// started is the reference for -timing. It is taken here, before the first
	// view is built, so the reported elapsed covers what a caller waits for: the
	// emission, the wait, and every re-emission the deadline allowed. The clock
	// is local to this process and the span never leaves it, so nothing here
	// depends on the hosts' clocks agreeing.
	started := time.Now()
	end := started.Add(deadline)
	for gen := 0; ; gen++ {
		if gen > 0 && !time.Now().Before(end) {
			break
		}
		rh, verr := makeView(parsed, gen, swap, tr, false)
		if verr != nil {
			fmt.Fprintf(os.Stderr, "client: %v\n", verr)
			os.Exit(1)
		}
		opID, eerr := emit(rh)
		if eerr != nil {
			if errors.Is(eerr, naylamp.ErrInvalidArgument) {
				fmt.Fprintln(os.Stderr, "client: invalid argument")
				os.Exit(1)
			}
			fmt.Fprintf(os.Stderr, "client: emit: %v\n", eerr)
			os.Exit(1)
		}

		// Wait for a result for at most one re-emission window, and never past the
		// overall deadline.
		window := reemitInterval
		if rem := time.Until(end); rem < window {
			window = rem
		}
		res, ok := awaitResult(rh, opID, window, poll)
		if perr := rh.Err(); perr != nil {
			fmt.Fprintf(os.Stderr, "client: router host poisoned: %v\n", perr)
			os.Exit(1)
		}
		if ok && !res.Exhausted {
			switch res.Status {
			case naylamp.StatusOK:
				fmt.Println(describe(res))
				printTiming(timing, op, "ok", started, gen)
				os.Exit(0)
			case naylamp.StatusInvalidArgument:
				// A terminal input error: re-emitting cannot change it.
				fmt.Fprintln(os.Stderr, "client: status invalid-argument")
				os.Exit(1)
			}
		}
		// No result yet, a retryable status, or the router exhausted its own
		// per-view retries: rotate the view and re-emit while the deadline allows.
		// The old router host is abandoned WITHOUT Close, which would close the
		// shared transport; a late reply to its op lands on the new view's stale
		// path and is dropped deterministically.
	}
	fmt.Fprintf(os.Stderr, "client: no result within %s; the cluster may be unreachable or without a leader\n", deadline)
	printTiming(timing, op, "timeout", started, 0)
	os.Exit(1)
}

// printTiming writes one timing line to stdout when -timing is on, and nothing
// at all when it is off, so an ordinary run stays byte-identical. The line is
// key=value in the same shape as the result lines above, so a gate script can
// select it with a prefix match and sum the field it wants. A timed-out
// operation is reported too: a latency run that silently dropped its failures
// would report the mean of the survivors and call it the mean.
// attempts is the number of emissions the operation took, so a slow sample can
// be told apart from one that merely waited out a re-emission window; it is
// reported as zero when the deadline elapsed with no result.
func printTiming(on bool, op, status string, started time.Time, gen int) {
	if !on {
		return
	}
	attempts := 0
	if status == "ok" {
		attempts = gen + 1
	}
	fmt.Printf("timing op=%s status=%s elapsed_us=%d attempts=%d\n",
		op, status, time.Since(started).Microseconds(), attempts)
}

// runClientReach drives the service-health load and exits. It keeps one router
// host alive for the whole run with timeout rotation on, advances that host's
// logical clock from a ticker at the node tick cadence so the rotation and the
// paced peer probe wake, and re-issues the operation up to count times within the
// deadline. A single operation cannot unseat a mute leader: it retires exhausted
// after its bounded per-view retries, before the leader's multi-window step-down
// completes, so the load issues a fresh operation the moment the last one
// exhausts, exactly as the router host contract expects of a caller past a
// budget. It prints the first success and a final tally, and exits 0 if any
// operation was served StatusOK, the recovery observed end to end, or 1 if the
// deadline elapsed with none served. It does not stop at the first success, so
// the same run also sustains the healthy-load control, where every operation is
// served and the leader must never step down.
func runClientReach(groups [][]nodeAddr, emit func(*naylamp.RouterHost) (uint64, error), describe func(naylamp.RouteResult) string, swap *handlerSwap, tr cluster.Transport, count int, tick, deadline, poll time.Duration) {
	if count < 1 {
		count = 1
	}
	// One rotating router host for the whole run. Generation 0 is the identity view,
	// because the router's own timeout rotation, not a rebuilt view, moves the target
	// here; the view is rebuilt only in the single-operation client above.
	rh, verr := makeView(groups, 0, swap, tr, true)
	if verr != nil {
		fmt.Fprintf(os.Stderr, "client: %v\n", verr)
		os.Exit(1)
	}

	// A ticker advances the router's logical clock so its retransmit timeouts and
	// target rotation fire; a router that is never ticked never times an attempt
	// out. now counts ticks, the same monotone clock the nodes advance on.
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(tick)
		defer ticker.Stop()
		var now cluster.Tick
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				now++
				if terr := rh.Tick(now); terr != nil {
					// A poisoned host is fatal; the operation loop observes the same
					// poison through rh.Err and exits with the diagnosis.
					return
				}
			}
		}
	}()
	halt := func() {
		close(stop)
		wg.Wait()
	}

	end := time.Now().Add(deadline)
	served, attempted := 0, 0
	for i := 0; i < count && time.Now().Before(end); i++ {
		attempted++
		opID, eerr := emit(rh)
		if eerr != nil {
			if errors.Is(eerr, naylamp.ErrInvalidArgument) {
				fmt.Fprintln(os.Stderr, "client: invalid argument")
				halt()
				os.Exit(1)
			}
			fmt.Fprintf(os.Stderr, "client: emit: %v\n", eerr)
			halt()
			os.Exit(1)
		}
		// Wait for this operation to reach a terminal or exhausted result, never past
		// the overall deadline, then let the next iteration re-issue a fresh one.
		res, ok := awaitResult(rh, opID, time.Until(end), poll)
		if perr := rh.Err(); perr != nil {
			fmt.Fprintf(os.Stderr, "client: router host poisoned: %v\n", perr)
			halt()
			os.Exit(1)
		}
		switch {
		case ok && !res.Exhausted && res.Status == naylamp.StatusOK:
			served++
			// The first success is the recovery; print it once so the log carries the
			// moment and the committed index, then keep the load going.
			if served == 1 {
				fmt.Printf("service-health: first served at op %d %s\n", i, describe(res))
			}
		case ok && !res.Exhausted && res.Status == naylamp.StatusInvalidArgument:
			// A terminal input error: re-issuing cannot change it.
			fmt.Fprintln(os.Stderr, "client: status invalid-argument")
			halt()
			os.Exit(1)
		default:
			// Exhausted its per-view retries, or no result before the deadline: the
			// next iteration issues a fresh operation. Left unprinted so a long run
			// does not flood the log with one line per unserved attempt.
		}
	}
	halt()
	fmt.Printf("service-health load: served=%d attempted=%d\n", served, attempted)
	if served > 0 {
		os.Exit(0)
	}
	os.Exit(1)
}

// handlerSwap is the client transport's inbound trampoline. The transport is
// built once with swap.deliver, and each rotated view repoints swap at that
// view's router host handler. Because the listener is never recreated, the links
// the nodes cache toward this client survive every re-emission.
type handlerSwap struct {
	mu sync.Mutex
	h  cluster.Handler
}

func (s *handlerSwap) Set(h cluster.Handler) {
	s.mu.Lock()
	s.h = h
	s.mu.Unlock()
}

func (s *handlerSwap) deliver(from cluster.NodeID, data []byte) {
	s.mu.Lock()
	h := s.h
	s.mu.Unlock()
	if h != nil {
		h(from, data)
	}
}

// makeView builds the router host for one re-emission generation: each shard's
// nodes rotated gen positions, so a fresh emission tries a different member
// first, over the shared transport, with the trampoline pointed at the new
// handler. When rotate is false the router is the historical coordinator with no
// timeout rotation, byte-for-byte the single-operation client; when true it turns
// on the timeout-driven target rotation and hint suppression, whose tunings fall
// to the sealed defaults, so a ticked host recovers from a mute leader.
func makeView(groups [][]nodeAddr, gen int, swap *handlerSwap, tr cluster.Transport, rotate bool) (*naylamp.RouterHost, error) {
	shardGroups := make([]cluster.Config, len(groups))
	for i, g := range groups {
		rotated := rotateNodes(g, gen)
		nodes := make([]cluster.NodeAddr, len(rotated))
		for j, na := range rotated {
			// Addr stays empty because the transport routes by its own peer table.
			nodes[j] = cluster.NodeAddr{ID: na.id}
		}
		shardGroups[i] = cluster.Config{Nodes: nodes}
	}
	var router *naylamp.Router
	var err error
	if rotate {
		router, err = naylamp.NewRouterWithOptions(clientID, cluster.ShardMap{Groups: shardGroups}, naylamp.RouterOptions{RotateOnTimeout: true})
	} else {
		router, err = naylamp.NewRouter(clientID, cluster.ShardMap{Groups: shardGroups})
	}
	if err != nil {
		return nil, fmt.Errorf("build router: %w", err)
	}
	return naylamp.NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		swap.Set(h)
		return tr
	})
}

// rotateNodes returns a copy of g shifted gen positions, leaving g untouched.
func rotateNodes(g []nodeAddr, gen int) []nodeAddr {
	n := len(g)
	out := make([]nodeAddr, n)
	shift := gen % n
	for i := 0; i < n; i++ {
		out[i] = g[(i+shift)%n]
	}
	return out
}

// buildOp validates -op and its arguments and returns the closure that emits it
// plus the formatter for its OK result. A validation failure is a usage error.
func buildOp(op string, id uint64, vecArg string, k, dim int) (func(*naylamp.RouterHost) (uint64, error), func(naylamp.RouteResult) string, error) {
	switch op {
	case "put":
		if id == 0 {
			return nil, nil, errors.New("put requires -id (a nonzero vector id)")
		}
		vec, err := parseVecDim(vecArg, dim)
		if err != nil {
			return nil, nil, fmt.Errorf("put: %w", err)
		}
		return func(rh *naylamp.RouterHost) (uint64, error) { return rh.Upsert(id, vec) }, describeWrite, nil
	case "del":
		if id == 0 {
			return nil, nil, errors.New("del requires -id (a nonzero vector id)")
		}
		return func(rh *naylamp.RouterHost) (uint64, error) { return rh.Delete(id) }, describeWrite, nil
	case "search":
		if k <= 0 {
			return nil, nil, errors.New("search requires -k greater than zero")
		}
		vec, err := parseVecDim(vecArg, dim)
		if err != nil {
			return nil, nil, fmt.Errorf("search: %w", err)
		}
		return func(rh *naylamp.RouterHost) (uint64, error) { return rh.Search(vec, k) }, describeSearch, nil
	default:
		return nil, nil, fmt.Errorf("unknown -op %q (want put, del, or search)", op)
	}
}

// awaitResult polls Result every poll until deadline, then checks once more, so
// a result that lands exactly at the deadline is not missed.
func awaitResult(rh *naylamp.RouterHost, opID uint64, deadline, poll time.Duration) (naylamp.RouteResult, bool) {
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if res, ok := rh.Result(opID); ok {
			return res, true
		}
		time.Sleep(poll)
	}
	return rh.Result(opID)
}

// describeWrite formats an OK put or delete: a single line carrying the commit
// index, parseable as ok index=N.
func describeWrite(res naylamp.RouteResult) string {
	return fmt.Sprintf("ok index=%d", res.Index)
}

// describeSearch formats an OK search: one line per neighbor as id=N dist=D, in
// rank order, or a single ok neighbors=0 line when the query found nothing.
func describeSearch(res naylamp.RouteResult) string {
	if len(res.Neighbors) == 0 {
		return "ok neighbors=0"
	}
	lines := make([]string, len(res.Neighbors))
	for i, nb := range res.Neighbors {
		lines[i] = fmt.Sprintf("id=%d dist=%g", nb.ID, nb.Distance)
	}
	return strings.Join(lines, "\n")
}

// parseVecDim parses a comma-separated float vector and checks its dimension.
func parseVecDim(s string, dim int) ([]float32, error) {
	if s == "" {
		return nil, errors.New("a -vec is required")
	}
	vec, err := parseVec(s)
	if err != nil {
		return nil, fmt.Errorf("bad vector %q: %w", s, err)
	}
	if len(vec) != dim {
		return nil, fmt.Errorf("vector has dim %d, want %d", len(vec), dim)
	}
	return vec, nil
}

// parseVec parses a comma-separated float32 vector.
func parseVec(s string) ([]float32, error) {
	parts := strings.Split(s, ",")
	vec := make([]float32, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		v, err := strconv.ParseFloat(p, 32)
		if err != nil {
			return nil, fmt.Errorf("component %q: %w", p, err)
		}
		vec = append(vec, float32(v))
	}
	return vec, nil
}
