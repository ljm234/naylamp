package naylamp

import (
	"sync"
	"testing"
	"time"

	"naylamp/engine/cluster"
	"naylamp/engine/raft"
)

// TestRouterHost_ClusterOverRealTCP is the first evidence in the repo over real
// sockets: three replicated nodes and a routing client, each on a loopback TCP
// transport driven by a real wall-clock ticker. It is deliberately
// nondeterministic, real time and real sockets, so it proves the wiring holds
// in a production-representative shape; correctness still lives in the seeded
// simulation, never here.
func TestRouterHost_ClusterOverRealTCP(t *testing.T) {
	ids := []cluster.NodeID{1, 2, 3}
	cfg := cluster.Config{Nodes: []cluster.NodeAddr{{ID: 1}, {ID: 2}, {ID: 3}}}

	// (a) Three nodes, each a Host over a real loopback TCP transport captured
	// in a map so the test can wire peers by address afterwards.
	hosts := map[cluster.NodeID]*Host{}
	transports := map[cluster.NodeID]*cluster.TCPTransport{}
	for _, id := range ids {
		node, err := OpenNode(t.TempDir(), id, cfg, 3, testRNG(uint64(id)+1600), NodeOptions{})
		if err != nil {
			t.Fatalf("open %d: %v", id, err)
		}
		hid := id
		host, err := NewHost(node, func(h cluster.Handler) cluster.Transport {
			tr, terr := cluster.NewTCPTransport(hid, "127.0.0.1:0", h)
			if terr != nil {
				t.Fatalf("tcp %d: %v", hid, terr)
			}
			transports[hid] = tr
			return tr
		})
		if err != nil {
			t.Fatalf("host %d: %v", id, err)
		}
		hosts[id] = host
	}
	closeHosts := func() {
		for _, id := range ids {
			if h := hosts[id]; h != nil {
				_ = h.Close()
			}
		}
	}
	defer closeHosts()

	// (b) Mutual AddPeer among the three nodes, before any ticker runs, so the
	// first election traffic already has an address to reach.
	for _, from := range ids {
		for _, to := range ids {
			if from != to {
				transports[from].AddPeer(to, transports[to].Addr())
			}
		}
	}

	// (c) One real ticker per host at 5ms. A tick error is published to a
	// buffered channel and the goroutine returns; it never calls t.Fatalf,
	// because it is not the test goroutine.
	stop := make(chan struct{})
	var wg sync.WaitGroup
	var stopOnce sync.Once
	tickErrs := make(chan error, len(ids))
	haltTickers := func() { stopOnce.Do(func() { close(stop); wg.Wait() }) }
	defer haltTickers()
	for _, id := range ids {
		h := hosts[id]
		wg.Add(1)
		go func() {
			defer wg.Done()
			ticker := time.NewTicker(5 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-stop:
					return
				case <-ticker.C:
					if err := h.Tick(); err != nil {
						tickErrs <- err
						return
					}
				}
			}
		}()
	}

	// (d) Deadline-bounded polling, never blind sleeps. Every turn checks the
	// ticker error channel and each host's poison, failing from the test
	// goroutine.
	var rh *RouterHost
	checkHealth := func() {
		select {
		case err := <-tickErrs:
			t.Fatalf("host ticker error: %v", err)
		default:
		}
		for _, id := range ids {
			if err := hosts[id].Err(); err != nil {
				t.Fatalf("host %d poisoned: %v", id, err)
			}
		}
		if rh != nil {
			if err := rh.Err(); err != nil {
				t.Fatalf("router host poisoned: %v", err)
			}
		}
	}
	pollUntil := func(what string, cond func() bool) {
		deadline := time.Now().Add(10 * time.Second)
		for time.Now().Before(deadline) {
			checkHealth()
			if cond() {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
		checkHealth()
		if !cond() {
			t.Fatalf("%s not reached within the deadline", what)
		}
	}
	leaderOf := func() cluster.NodeID {
		for _, id := range ids {
			if hosts[id].Role() == raft.RoleLeader {
				return id
			}
		}
		return cluster.None
	}

	var lead cluster.NodeID
	pollUntil("leader election", func() bool {
		lead = leaderOf()
		return lead != cluster.None
	})

	// (e) Build the router with the sitting leader NOT first, so the first
	// attempt is a follower and the NotLeader redirect is exercised over TCP.
	rotated := rotateSoLeaderNotFirst(cfg.Nodes, lead)
	sm := cluster.ShardMap{Groups: []cluster.Config{{Nodes: rotated}}}
	router, err := NewRouter(routerID, sm)
	if err != nil {
		t.Fatalf("new router: %v", err)
	}
	var routerTransport *cluster.TCPTransport
	rh, err = NewRouterHost(router, func(h cluster.Handler) cluster.Transport {
		tr, terr := cluster.NewTCPTransport(routerID, "127.0.0.1:0", h)
		if terr != nil {
			t.Fatalf("tcp router: %v", terr)
		}
		routerTransport = tr
		return tr
	})
	if err != nil {
		t.Fatalf("router host: %v", err)
	}
	defer func() {
		if rh != nil {
			_ = rh.Close()
		}
	}()
	// Cross wiring: the router must dial every node, and every node must be able
	// to dial the router back. Without this mutual registration the response is
	// lost in silence and the client hangs.
	for _, id := range ids {
		routerTransport.AddPeer(id, transports[id].Addr())
		transports[id].AddPeer(routerID, routerTransport.Addr())
	}

	// (f) A write through the router. Its first target is a follower, so this
	// one path already proves the NotLeader redirect over real TCP.
	upOp, err := rh.Upsert(1, []float32{1, 0, 0})
	if err != nil {
		t.Fatalf("router host upsert: %v", err)
	}
	var upRes RouteResult
	pollUntil("upsert result", func() bool {
		r, ok := rh.Result(upOp)
		if ok {
			upRes = r
		}
		return ok
	})
	if upRes.Status != StatusOK || upRes.Index == 0 || upRes.Exhausted {
		t.Fatalf("upsert did not complete OK: %+v", upRes)
	}

	// (g) A search through the router finds the one vector written.
	srOp, err := rh.Search([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("router host search: %v", err)
	}
	var srRes RouteResult
	pollUntil("search result", func() bool {
		r, ok := rh.Result(srOp)
		if ok {
			srRes = r
		}
		return ok
	})
	if srRes.Status != StatusOK || srRes.Exhausted || srRes.Index != 0 {
		t.Fatalf("search did not complete OK: %+v", srRes)
	}
	if len(srRes.Neighbors) != 1 || srRes.Neighbors[0].ID != 1 {
		t.Fatalf("search returned the wrong nearest: %+v", srRes.Neighbors)
	}

	// (h) Clean, ordered shutdown: stop the tickers, confirm nothing poisoned,
	// then close the router host and every node host.
	haltTickers()
	if err := rh.Err(); err != nil {
		t.Fatalf("router host poisoned at shutdown: %v", err)
	}
	for _, id := range ids {
		if err := hosts[id].Err(); err != nil {
			t.Fatalf("host %d poisoned at shutdown: %v", id, err)
		}
	}
	if err := rh.Close(); err != nil {
		t.Fatalf("router host close: %v", err)
	}
	for _, id := range ids {
		if err := hosts[id].Close(); err != nil {
			t.Fatalf("host %d close: %v", id, err)
		}
	}
}
