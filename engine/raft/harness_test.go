package raft

import (
	"bytes"
	"math/rand/v2"
	"os"
	"testing"

	"naylamp/engine/cluster"
)

// harness runs a whole Raft cluster inside one goroutine on the simulated
// network. Deliveries, steps and ticks all derive from seeds, so any failure
// replays exactly. It doubles as the continuous checker for the four safety
// properties of the paper: election safety, log matching, leader
// completeness and state machine safety.
type harness struct {
	t   *testing.T
	fab *cluster.SimNet
	cfg cluster.Config

	nodes map[cluster.NodeID]*Raft
	eps   map[cluster.NodeID]cluster.Transport
	inbox map[cluster.NodeID][]Message

	leaders     map[uint64]cluster.NodeID // term -> first observed leader
	elections   int
	appliedUpTo map[cluster.NodeID]uint64
	applied     map[uint64]Entry // index -> the one entry ever applied there
	committed   map[uint64]Entry // the client-visible oracle: acked = committed

	ticks int
}

func newHarness(t *testing.T, n int, seed uint64, simCfg cluster.SimConfig) *harness {
	return newHarnessOpts(t, n, seed, simCfg, harnessOptions())
}

// harnessOptions is DefaultOptions with CheckQuorum on, the configuration the
// harness exercises by default now that a leader self-demotes on quorum loss.
// Set NAYLAMP_RAFT_CHECKQUORUM=off to run the same suite with the guard
// disabled, which is how the seeded sweep is checked both ways.
func harnessOptions() Options {
	opts := DefaultOptions()
	opts.CheckQuorum = os.Getenv("NAYLAMP_RAFT_CHECKQUORUM") != "off"
	return opts
}

func newHarnessOpts(t *testing.T, n int, seed uint64, simCfg cluster.SimConfig, opts Options) *harness {
	t.Helper()
	cfg := cluster.Config{}
	for i := 1; i <= n; i++ {
		cfg.Nodes = append(cfg.Nodes, cluster.NodeAddr{ID: cluster.NodeID(i)})
	}
	h := &harness{
		t: t, fab: cluster.NewSimNet(seed, simCfg), cfg: cfg,
		nodes:   map[cluster.NodeID]*Raft{},
		eps:     map[cluster.NodeID]cluster.Transport{},
		inbox:   map[cluster.NodeID][]Message{},
		leaders: map[uint64]cluster.NodeID{}, appliedUpTo: map[cluster.NodeID]uint64{},
		applied: map[uint64]Entry{}, committed: map[uint64]Entry{},
	}
	for _, na := range cfg.Nodes {
		id := na.ID
		node, err := New(id, cfg, rand.New(rand.NewPCG(seed, uint64(id))), opts) //nolint:gosec // deterministic seeded RNG for reproducible tests, not security
		if err != nil {
			t.Fatalf("new raft %d: %v", id, err)
		}
		h.nodes[id] = node
		ep, err := h.fab.Endpoint(id, func(from cluster.NodeID, data []byte) {
			m, derr := DecodeMsg(data)
			if derr != nil {
				t.Fatalf("decode inbound at %d from %d: %v", id, from, derr)
			}
			h.inbox[id] = append(h.inbox[id], m)
		})
		if err != nil {
			t.Fatalf("endpoint %d: %v", id, err)
		}
		h.eps[id] = ep
	}
	return h
}

// tick advances the whole world one unit: the fabric delivers into inboxes,
// every node steps its inbox, every node ticks. All iteration is in config
// order; nothing depends on map order.
func (h *harness) tick() {
	h.ticks++
	h.fab.Tick()
	for _, id := range h.cfg.IDs() {
		msgs := h.inbox[id]
		h.inbox[id] = nil
		for _, m := range msgs {
			h.drain(id, h.nodes[id].Step(m))
		}
	}
	for _, id := range h.cfg.IDs() {
		h.drain(id, h.nodes[id].Tick())
	}
	if h.ticks%25 == 0 {
		h.checkLogMatching()
	}
}

func (h *harness) runTicks(n int) {
	for i := 0; i < n; i++ {
		h.tick()
	}
}

// drain acts on one Ready: record applies, ship messages, observe roles.
func (h *harness) drain(id cluster.NodeID, rd Ready) {
	for _, e := range rd.Committed {
		h.recordApply(id, e)
	}
	for _, m := range rd.Msgs {
		raw, err := EncodeMsg(m)
		if err != nil {
			h.t.Fatalf("encode from %d: %v", id, err)
		}
		if err := h.eps[id].Send(m.To, raw); err != nil {
			h.t.Fatalf("send from %d: %v", id, err)
		}
	}
	h.observeRoles()
}

// recordApply enforces in-order apply per node and State Machine Safety
// globally: no two nodes may ever apply different entries at one index.
func (h *harness) recordApply(id cluster.NodeID, e Entry) {
	if e.Index != h.appliedUpTo[id]+1 {
		h.t.Fatalf("node %d applied index %d after %d: out of order", id, e.Index, h.appliedUpTo[id])
	}
	h.appliedUpTo[id] = e.Index
	if prev, ok := h.applied[e.Index]; ok {
		if prev.Term != e.Term || !bytes.Equal(prev.Data, e.Data) {
			h.t.Fatalf("state machine safety violated at index %d by node %d", e.Index, id)
		}
		return
	}
	h.applied[e.Index] = e
	h.committed[e.Index] = e
}

// observeRoles enforces Election Safety (at most one leader per term) and,
// on each newly observed leader, Leader Completeness: its log must contain
// every entry the oracle already saw committed.
func (h *harness) observeRoles() {
	for _, id := range h.cfg.IDs() {
		n := h.nodes[id]
		if n.Role() != RoleLeader {
			continue
		}
		term := n.Term()
		if lead, ok := h.leaders[term]; ok {
			if lead != id {
				h.t.Fatalf("election safety violated: term %d has leaders %d and %d", term, lead, id)
			}
			continue
		}
		h.leaders[term] = id
		h.elections++
		for idx := uint64(1); ; idx++ {
			e, ok := h.committed[idx]
			if !ok {
				break
			}
			got, ok2 := n.log.Term(idx)
			if !ok2 || got != e.Term {
				h.t.Fatalf("leader completeness violated: leader %d of term %d misses committed index %d", id, term, idx)
			}
		}
	}
}

// checkLogMatching verifies the property directly for every pair: find the
// highest index where both logs hold the same term, then everything at or
// below it must be identical in term and data.
func (h *harness) checkLogMatching() {
	ids := h.cfg.IDs()
	for a := 0; a < len(ids); a++ {
		for b := a + 1; b < len(ids); b++ {
			la, lb := h.nodes[ids[a]].log, h.nodes[ids[b]].log
			m := min(la.LastIndex(), lb.LastIndex())
			var agree uint64
			for i := m; i >= 1; i-- {
				ta, oka := la.Term(i)
				tb, okb := lb.Term(i)
				if oka && okb && ta == tb {
					agree = i
					break
				}
			}
			for i := uint64(1); i <= agree; i++ {
				ta, _ := la.Term(i)
				tb, _ := lb.Term(i)
				if ta != tb {
					h.t.Fatalf("log matching violated between %d and %d at index %d", ids[a], ids[b], i)
				}
				ea, _ := la.Entry(i)
				eb, _ := lb.Entry(i)
				if !bytes.Equal(ea.Data, eb.Data) {
					h.t.Fatalf("log matching data mismatch between %d and %d at index %d", ids[a], ids[b], i)
				}
			}
		}
	}
}

// leader returns the live leader with the highest term, failing the test if
// two leaders ever share one term.
func (h *harness) leader() *Raft {
	var lead *Raft
	for _, id := range h.cfg.IDs() {
		n := h.nodes[id]
		if n.Role() != RoleLeader {
			continue
		}
		if lead != nil && lead.Term() == n.Term() {
			h.t.Fatalf("two live leaders share term %d", n.Term())
		}
		if lead == nil || n.Term() > lead.Term() {
			lead = n
		}
	}
	return lead
}

// waitLeader ticks until some node leads, bounded.
func (h *harness) waitLeader(maxTicks int) *Raft {
	for i := 0; i < maxTicks; i++ {
		if lead := h.leader(); lead != nil {
			return lead
		}
		h.tick()
	}
	h.t.Fatalf("no leader after %d ticks", maxTicks)
	return nil
}

// propose hands data to the current leader when one exists.
func (h *harness) propose(data []byte) bool {
	lead := h.leader()
	if lead == nil {
		return false
	}
	_, rd, err := lead.Propose(data)
	if err != nil {
		return false
	}
	h.drain(lead.ID(), rd)
	return true
}

// waitCommittedData ticks until the oracle sees data committed, bounded.
func (h *harness) waitCommittedData(data string, maxTicks int) {
	for i := 0; i < maxTicks; i++ {
		for _, e := range h.committed {
			if string(e.Data) == data {
				return
			}
		}
		h.tick()
	}
	h.t.Fatalf("entry %q not committed after %d ticks", data, maxTicks)
}

// quiesce heals every partition and runs the cluster fault-free until all
// commit indexes agree and stay stable, then verifies the closing
// invariants: liveness reached, logs match, and every committed entry is
// present on every node. This is the "no acknowledged write is ever lost"
// check of the subphase.
func (h *harness) quiesce(maxTicks int) {
	h.fab.HealAll()
	stable := 0
	for i := 0; i < maxTicks && stable < 20; i++ {
		h.tick()
		c := h.nodes[h.cfg.IDs()[0]].hs.Commit
		same := c > 0
		for _, id := range h.cfg.IDs() {
			if h.nodes[id].hs.Commit != c {
				same = false
				break
			}
		}
		if same {
			stable++
		} else {
			stable = 0
		}
	}
	if stable < 20 {
		h.t.Fatalf("cluster did not converge within %d ticks after heal", maxTicks)
	}
	h.checkLogMatching()
	for idx := uint64(1); ; idx++ {
		e, ok := h.committed[idx]
		if !ok {
			break
		}
		for _, id := range h.cfg.IDs() {
			got, ok2 := h.nodes[id].log.Term(idx)
			if !ok2 || got != e.Term {
				h.t.Fatalf("committed index %d missing on node %d after quiesce", idx, id)
			}
		}
	}
}
