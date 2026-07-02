// Package cluster provides the network substrate the Naylamp consensus layer
// builds on: node identity and static membership, a wire envelope framed with
// the same CRC block format the storage layer uses on disk, and a deliberately
// weak Transport contract (at-most-once and unordered) served by both a
// deterministic in-memory fabric (SimNet) and a TCP adapter.
package cluster

import (
	"errors"
	"fmt"
)

// NodeID identifies a node in the cluster. Zero is reserved as "no node" so a
// forgotten or zeroed field never silently aliases a real member.
type NodeID uint64

// None is the zero NodeID, used wherever "no node" is meaningful (e.g. no vote
// granted yet, no known leader).
const None NodeID = 0

// NodeAddr binds a node id to a network address. The address is used by the
// TCP transport; the simulated network routes purely by id and ignores it.
type NodeAddr struct {
	ID   NodeID
	Addr string
}

// Config is the static cluster membership for Phase 3: the full list of nodes.
// Dynamic membership changes are layered on top later (single-server changes
// in 3.3); the substrate only needs to know who exists and how to reach them.
type Config struct {
	Nodes []NodeAddr
}

// Validate checks the config is usable: at least one node, no zero ids, no
// duplicate ids. Addresses may be empty when only the simulated transport is
// used, so they are deliberately not validated here.
func (c Config) Validate() error {
	if len(c.Nodes) == 0 {
		return errors.New("cluster: config has no nodes")
	}
	seen := make(map[NodeID]bool, len(c.Nodes))
	for _, n := range c.Nodes {
		if n.ID == None {
			return errors.New("cluster: node id 0 is reserved")
		}
		if seen[n.ID] {
			return fmt.Errorf("cluster: duplicate node id %d", n.ID)
		}
		seen[n.ID] = true
	}
	return nil
}

// Contains reports whether id is a member of the cluster.
func (c Config) Contains(id NodeID) bool {
	for _, n := range c.Nodes {
		if n.ID == id {
			return true
		}
	}
	return false
}

// Peers returns every member id except self, in config order.
func (c Config) Peers(self NodeID) []NodeID {
	peers := make([]NodeID, 0, len(c.Nodes))
	for _, n := range c.Nodes {
		if n.ID != self {
			peers = append(peers, n.ID)
		}
	}
	return peers
}

// IDs returns all member ids in config order.
func (c Config) IDs() []NodeID {
	ids := make([]NodeID, 0, len(c.Nodes))
	for _, n := range c.Nodes {
		ids = append(ids, n.ID)
	}
	return ids
}

// Quorum returns the majority size for the current membership.
func (c Config) Quorum() int {
	return len(c.Nodes)/2 + 1
}
