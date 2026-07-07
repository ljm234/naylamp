package main

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"naylamp/engine/cluster"
	"naylamp/engine/naylamp"
)

// clientID is this client's identity on the fabric. It is a member of no shard
// group, so a node never confuses its traffic with a peer's. The test package
// keeps its own unexported copy; this is the binary's.
const clientID cluster.NodeID = 90

// handlerSwap is the client transport's inbound trampoline. The transport is
// built once with swap.deliver, and each new view points swap at that view's
// RouterHost handler. Because the listener is never recreated, the outbound
// links the nodes cache toward the client survive every view rotation.
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

// groupFlag accumulates repeated -group values, one shard each, in order.
type groupFlag []string

func (g *groupFlag) String() string { return strings.Join(*g, ";") }

func (g *groupFlag) Set(v string) error {
	*g = append(*g, v)
	return nil
}

// client holds the routing state across REPL commands: the parsed shard
// groups, the shared transport and its trampoline, and the current view.
type client struct {
	groups   [][]nodeAddr
	swap     *handlerSwap
	tr       cluster.Transport
	dim      int
	deadline time.Duration
	poll     time.Duration
	maxRot   int

	gen  int
	view *naylamp.RouterHost
}

// runClient runs the routing client REPL over a real TCP transport.
func runClient(args []string) {
	log.SetPrefix("client: ")
	log.SetFlags(log.LstdFlags)
	fs := flag.NewFlagSet("client", flag.ExitOnError)
	var listen string
	var groups groupFlag
	var dim int
	var deadline, poll time.Duration
	fs.StringVar(&listen, "listen", "", "listen address host:port (required)")
	fs.Var(&groups, "group", "one shard as id=addr,id=addr (repeatable)")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.DurationVar(&deadline, "deadline", 3*time.Second, "per-view result deadline")
	fs.DurationVar(&poll, "poll", 20*time.Millisecond, "result poll interval")
	_ = fs.Parse(args)

	if listen == "" || len(groups) == 0 {
		fmt.Fprintln(os.Stderr, "client: -listen and at least one -group are required")
		fs.Usage()
		os.Exit(2)
	}

	parsed := make([][]nodeAddr, 0, len(groups))
	for i, g := range groups {
		nodes, err := parseNodeList(g)
		if err != nil {
			log.Fatalf("bad -group %d (%q): %v", i, g, err)
		}
		if len(nodes) == 0 {
			log.Fatalf("empty -group %d", i)
		}
		parsed = append(parsed, nodes)
	}

	// (i) The client transport is created ONCE with the trampoline as its
	// handler, so the listener and the outbound links the nodes cache toward it
	// outlive every view rotation.
	swap := &handlerSwap{}
	tr, err := cluster.NewTCPTransport(clientID, listen, swap.deliver)
	if err != nil {
		log.Fatalf("tcp listen %s: %v", listen, err)
	}
	defer func() { _ = tr.Close() }()

	// (iii) Register every node of every shard once on the shared transport.
	for _, g := range parsed {
		for _, na := range g {
			tr.AddPeer(na.id, na.addr)
		}
	}

	c := &client{
		groups:   parsed,
		swap:     swap,
		tr:       tr,
		dim:      dim,
		deadline: deadline,
		poll:     poll,
		maxRot:   largestGroup(parsed),
	}
	c.view = makeRouterHost(parsed, 0, swap, tr)

	fmt.Printf("client %d ready: %d shard(s), view gen 0\n", clientID, len(parsed))
	for i, g := range parsed {
		names := make([]string, len(g))
		for j, na := range g {
			names[j] = strconv.FormatUint(uint64(na.id), 10)
		}
		fmt.Printf("  shard %d: %s\n", i, strings.Join(names, ","))
	}
	fmt.Println("type help for commands")
	c.repl()
}

// makeRouterHost builds the view for one generation: each group rotated gen
// positions (copied, never mutating the parsed flags), a router over the
// resulting shard map, and a RouterHost whose bind points the trampoline at it
// and returns the SHARED transport.
func makeRouterHost(groups [][]nodeAddr, gen int, swap *handlerSwap, tr cluster.Transport) *naylamp.RouterHost {
	shardGroups := make([]cluster.Config, len(groups))
	for i, g := range groups {
		rotated := rotateNodes(g, gen)
		nodes := make([]cluster.NodeAddr, len(rotated))
		for j, na := range rotated {
			// Addr stays empty: the transport routes by its own peer table.
			nodes[j] = cluster.NodeAddr{ID: na.id}
		}
		shardGroups[i] = cluster.Config{Nodes: nodes}
	}
	router, err := naylamp.NewRouter(clientID, cluster.ShardMap{Groups: shardGroups})
	if err != nil {
		log.Fatalf("build router: %v", err)
	}
	rh, err := naylamp.NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		swap.Set(h)
		return tr
	})
	if err != nil {
		log.Fatalf("build router host: %v", err)
	}
	return rh
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

func largestGroup(groups [][]nodeAddr) int {
	largest := 0
	for _, g := range groups {
		if len(g) > largest {
			largest = len(g)
		}
	}
	return largest
}

// repl reads commands until end of input or exit.
func (c *client) repl() {
	sc := bufio.NewScanner(os.Stdin)
	fmt.Print("> ")
	for sc.Scan() {
		if fields := strings.Fields(sc.Text()); len(fields) > 0 {
			if c.dispatch(fields) {
				return
			}
		}
		fmt.Print("> ")
	}
}

// dispatch runs one command and reports whether the REPL should exit.
func (c *client) dispatch(fields []string) bool {
	switch fields[0] {
	case "put":
		if len(fields) != 3 {
			fmt.Println("usage: put <id> <f,f,f>")
			return false
		}
		id, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			fmt.Println("usage: put <id> <f,f,f>")
			return false
		}
		vec, ok := c.vecArg(fields[2])
		if !ok {
			return false
		}
		c.execute(func(rh *naylamp.RouterHost) (uint64, error) { return rh.Upsert(id, vec) }, describeWrite)
	case "del":
		if len(fields) != 2 {
			fmt.Println("usage: del <id>")
			return false
		}
		id, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			fmt.Println("usage: del <id>")
			return false
		}
		c.execute(func(rh *naylamp.RouterHost) (uint64, error) { return rh.Delete(id) }, describeWrite)
	case "search":
		if len(fields) != 3 {
			fmt.Println("usage: search <f,f,f> <k>")
			return false
		}
		vec, ok := c.vecArg(fields[1])
		if !ok {
			return false
		}
		k, err := strconv.Atoi(fields[2])
		if err != nil {
			fmt.Println("usage: search <f,f,f> <k>")
			return false
		}
		c.execute(func(rh *naylamp.RouterHost) (uint64, error) { return rh.Search(vec, k) }, describeSearch)
	case "help":
		printHelp()
	case "exit", "quit":
		return true
	default:
		fmt.Printf("unknown command %q; type help\n", fields[0])
	}
	return false
}

// vecArg parses a comma-separated vector and checks its dimension.
func (c *client) vecArg(s string) ([]float32, bool) {
	vec, err := parseVec(s)
	if err != nil {
		fmt.Printf("bad vector %q: %v\n", s, err)
		return nil, false
	}
	if len(vec) != c.dim {
		fmt.Printf("vector has dim %d, client configured for %d\n", len(vec), c.dim)
		return nil, false
	}
	return vec, true
}

// execute runs one operation with view-rotation recovery. The router is
// response-driven and still has no protocol timeout of its own (DEFER-011): a
// dead target yields only silence. This caller policy, a deadline, a fresh
// operation, and a view rotation, is the honest recovery until the protocol
// pays for its own.
func (c *client) execute(emit func(*naylamp.RouterHost) (uint64, error), describe func(naylamp.RouteResult) string) {
	for rot := 0; ; rot++ {
		rh := c.view
		opID, err := emit(rh)
		if err != nil {
			if errors.Is(err, naylamp.ErrInvalidArgument) {
				fmt.Println("invalid argument")
				return
			}
			log.Fatalf("router host error: %v", err)
		}
		if res, ok := c.await(rh, opID); ok {
			fmt.Println(describe(res))
			return
		}
		if perr := rh.Err(); perr != nil {
			log.Fatalf("router host poisoned: %v", perr)
		}
		if rot >= c.maxRot {
			fmt.Printf("operation failed after %d views; is the cluster electing?\n", rot+1)
			return
		}
		fmt.Printf("timeout on view %d; rotating view\n", c.gen)
		c.gen++
		// A replaced RouterHost is abandoned WITHOUT Close, which would close
		// the shared transport. It stops receiving because the trampoline now
		// points at the new one, and any late reply to its operations lands on
		// the new router's stale path and is dropped deterministically.
		c.view = makeRouterHost(c.groups, c.gen, c.swap, c.tr)
	}
}

// await polls Result every c.poll until c.deadline, then checks once more.
func (c *client) await(rh *naylamp.RouterHost, opID uint64) (naylamp.RouteResult, bool) {
	end := time.Now().Add(c.deadline)
	for time.Now().Before(end) {
		if res, ok := rh.Result(opID); ok {
			return res, true
		}
		time.Sleep(c.poll)
	}
	return rh.Result(opID)
}

func describeWrite(res naylamp.RouteResult) string {
	switch {
	case res.Exhausted:
		return fmt.Sprintf("exhausted after retries; last status %s", statusName(res.Status))
	case res.Status == naylamp.StatusOK:
		return fmt.Sprintf("ok index=%d", res.Index)
	case res.Status == naylamp.StatusInvalidArgument:
		return "invalid argument"
	default:
		return fmt.Sprintf("status %s", statusName(res.Status))
	}
}

func describeSearch(res naylamp.RouteResult) string {
	switch {
	case res.Exhausted:
		return fmt.Sprintf("exhausted after retries; last status %s", statusName(res.Status))
	case res.Status == naylamp.StatusOK:
		if len(res.Neighbors) == 0 {
			return "ok: no neighbors"
		}
		parts := make([]string, len(res.Neighbors))
		for i, nb := range res.Neighbors {
			parts[i] = fmt.Sprintf("id=%d dist=%g", nb.ID, nb.Distance)
		}
		return "ok: " + strings.Join(parts, " ")
	case res.Status == naylamp.StatusInvalidArgument:
		return "invalid argument"
	default:
		return fmt.Sprintf("status %s", statusName(res.Status))
	}
}

func statusName(s naylamp.ClientStatus) string {
	switch s {
	case naylamp.StatusOK:
		return "ok"
	case naylamp.StatusNotLeader:
		return "not-leader"
	case naylamp.StatusNotReady:
		return "not-ready"
	case naylamp.StatusInvalidArgument:
		return "invalid-argument"
	default:
		return fmt.Sprintf("unknown(%d)", s)
	}
}

// parseVec parses a comma-separated float vector.
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

func printHelp() {
	fmt.Println("commands:")
	fmt.Println("  put <id> <f,f,f>     upsert a vector under an id")
	fmt.Println("  del <id>             delete a vector")
	fmt.Println("  search <f,f,f> <k>   k nearest neighbors of a query")
	fmt.Println("  help                 this message")
	fmt.Println("  exit                 quit (alias quit)")
}
