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
	var k, dim int
	var deadline, poll time.Duration
	fs.StringVar(&listen, "listen", "", "this client's own listen address host:port (required)")
	fs.Var(&groups, "group", "one shard as id=addr,id=addr (repeatable, at least one required)")
	fs.StringVar(&op, "op", "", "operation: put, del, or search (required)")
	fs.Uint64Var(&id, "id", 0, "vector id for put and del")
	fs.StringVar(&vecArg, "vec", "", "vector as f,f,f for put and search")
	fs.IntVar(&k, "k", 10, "number of neighbors to return for search")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.DurationVar(&deadline, "deadline", 5*time.Second, "deadline for the operation's result")
	fs.DurationVar(&poll, "poll", 20*time.Millisecond, "result poll interval")
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

	// Emit, poll for a result, and re-emit on a rotated view every reemitInterval
	// until the deadline. A single emission is not enough against the real
	// transport: it is at-most-once and the router does not retry replies
	// (DEFER-011), so a lost response, for example one sent on a stale link the
	// leader cached toward a previous client process at this same identity, would
	// hang forever. The client is the protocol above the transport, where retries
	// belong. All three operations are idempotent under re-emission: an upsert of
	// the same id and vector, a delete, and a read-only search, and a committed
	// duplicate is legitimate under the log-fidelity semantics.
	end := time.Now().Add(deadline)
	for gen := 0; ; gen++ {
		if gen > 0 && !time.Now().Before(end) {
			break
		}
		rh, verr := makeView(parsed, gen, swap, tr)
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
// handler.
func makeView(groups [][]nodeAddr, gen int, swap *handlerSwap, tr cluster.Transport) (*naylamp.RouterHost, error) {
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
	router, err := naylamp.NewRouter(clientID, cluster.ShardMap{Groups: shardGroups})
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
