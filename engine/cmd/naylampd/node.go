package main

import (
	"flag"
	"fmt"
	"log"
	"math/rand/v2"
	"os"
	"os/signal"
	"sort"
	"sync"
	"syscall"
	"time"

	"naylamp/engine/cluster"
	"naylamp/engine/naylamp"
)

// runNode runs one replica of a shard group over a real TCP transport secured
// with mutual TLS, driven by a wall-clock ticker, until a signal stops it. The
// TLS material comes from the environment; everything else is a flag. The data
// directory is required with no default, so a deployment never silently writes
// state under a temporary path it did not choose.
func runNode(args []string) {
	fs := flag.NewFlagSet("node", flag.ExitOnError)
	var id uint
	var listen, peers, clientSpec, dir string
	var dim int
	var tick time.Duration
	fs.UintVar(&id, "id", 0, "this node's id (required)")
	fs.StringVar(&listen, "listen", "", "listen address host:port (required)")
	fs.StringVar(&peers, "peers", "", "other group members as id=addr,id=addr")
	fs.StringVar(&clientSpec, "client", "", "client as id=addr (empty for none)")
	fs.StringVar(&dir, "dir", "", "data directory (required)")
	fs.IntVar(&dim, "dim", 3, "vector dimension")
	fs.DurationVar(&tick, "tick", 10*time.Millisecond, "logical tick period")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: naylampd node [flags]")
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, "TLS material is read from NAYLAMP_TLS_CERT, NAYLAMP_TLS_KEY, and NAYLAMP_TLS_CA")
	}
	_ = fs.Parse(args)

	if id == 0 || listen == "" || dir == "" {
		fmt.Fprintln(os.Stderr, "node: -id, -listen, and -dir are required")
		fs.Usage()
		os.Exit(2)
	}

	mat, err := tlsMaterialFromEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "node: %v\n", err)
		os.Exit(2)
	}

	nid := cluster.NodeID(id)
	logger := log.New(os.Stderr, fmt.Sprintf("node %d: ", id), log.LstdFlags)

	if merr := os.MkdirAll(dir, 0o750); merr != nil {
		logger.Fatalf("mkdir %s: %v", dir, merr)
	}

	peerList, err := parseNodeList(peers)
	if err != nil {
		logger.Fatalf("bad -peers: %v", err)
	}

	// Config carries self and peers with ids ascending. The transport does not
	// read Config, so the address stays empty here; peers are dialed through the
	// transport's own peer table registered below.
	memberIDs := []cluster.NodeID{nid}
	for _, p := range peerList {
		memberIDs = append(memberIDs, p.id)
	}
	sort.Slice(memberIDs, func(i, j int) bool { return memberIDs[i] < memberIDs[j] })
	members := make([]cluster.NodeAddr, len(memberIDs))
	for i, mid := range memberIDs {
		members[i] = cluster.NodeAddr{ID: mid}
	}
	cfg := cluster.Config{Nodes: members}

	// A seed unique per process: the id fixes one coordinate and the wall clock
	// the other, so two nodes never draw the same randomized election timeout.
	rng := rand.New(rand.NewPCG(uint64(id), uint64(time.Now().UnixNano()))) //nolint:gosec // a node seed for randomized election timeouts, not cryptographic
	node, err := naylamp.OpenNode(dir, nid, cfg, dim, rng, naylamp.NodeOptions{})
	if err != nil {
		logger.Fatalf("open node: %v", err)
	}

	var transport *cluster.TCPTransport
	host, err := naylamp.NewHost(node, func(h cluster.Handler) cluster.Transport {
		tr, terr := cluster.NewTCPTransport(nid, listen, h, mat)
		if terr != nil {
			logger.Fatalf("tcp listen %s: %v", listen, terr)
		}
		transport = tr
		return tr
	})
	if err != nil {
		logger.Fatalf("open host: %v", err)
	}

	for _, p := range peerList {
		transport.AddPeer(p.id, p.addr)
	}
	if clientSpec != "" {
		cl, cerr := parseNodeList(clientSpec)
		if cerr != nil || len(cl) != 1 {
			logger.Fatalf("bad -client %q", clientSpec)
		}
		// Without this the node cannot dial the client back and every response
		// is lost in silence.
		transport.AddPeer(cl[0].id, cl[0].addr)
	}

	logger.Printf("listening on %s, group of %d, dir %s", listen, len(members), dir)

	// One ticker goroutine advances the logical clock and reports role changes
	// to stderr, which is how an operator sees who to kill and how a test sees
	// that a leader has emerged.
	stop := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		ticker := time.NewTicker(tick)
		defer ticker.Stop()
		lastRole, lastLeader := host.Role(), host.Leader()
		logger.Printf("role=%v leader=%v", lastRole, lastLeader)
		var lastReadCtx uint64
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				if terr := host.Tick(); terr != nil {
					// A Host poison is fatal to the process: the node's state is
					// corrupt or its storage is broken.
					logger.Fatalf("tick: %v", terr)
				}
				if r, l := host.Role(), host.Leader(); r != lastRole || l != lastLeader {
					lastRole, lastLeader = r, l
					logger.Printf("role=%v leader=%v", r, l)
				}
				// A read index confirms only after a majority answered its round,
				// so this line, logged when the context rises, is the observable
				// proof that the majority round completed before any answer. It
				// sits outside the role change above on purpose: a read confirms
				// under steady leadership, which never changes the role line.
				if ctx, idx := host.LastConfirmedRead(); ctx > lastReadCtx {
					lastReadCtx = ctx
					logger.Printf("readindex ctx=%d index=%d", ctx, idx)
				}
			}
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	logger.Printf("shutting down")
	close(stop)
	wg.Wait()
	if cerr := host.Close(); cerr != nil {
		logger.Printf("close: %v", cerr)
	}
	logger.Printf("stopped")
	os.Exit(0)
}
