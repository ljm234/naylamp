package cluster

import (
	"errors"
	"fmt"
)

// ShardMap is the static partition of a collection: K shards, each an
// independent raft replica group. The map is fixed for the lifetime of the
// cluster in this phase; rebalancing a live cluster is a deliberate
// deferral, so the map carries no versioning and no state of its own.
//
// Routing is by hash of the record id, not by vector geometry: ids spread
// uniformly across shards regardless of insertion order, every shard holds
// a random sample of the collection, and a search therefore visits every
// shard and merges (scatter-gather), which the router above implements.
type ShardMap struct {
	// Groups holds one replica set config per shard; the slice index is
	// the shard number and is part of the routing contract.
	Groups []Config
}

// K returns the number of shards.
func (m ShardMap) K() int { return len(m.Groups) }

// Validate checks the map is usable: at least one shard, every group a
// valid replica set, and node ids globally unique across groups, because a
// single transport fabric routes frames by node id and one id serving two
// shards would deliver one shard's consensus traffic into the other.
func (m ShardMap) Validate() error {
	if len(m.Groups) == 0 {
		return errors.New("cluster: shard map with zero shards")
	}
	seen := make(map[NodeID]int)
	for shard, g := range m.Groups {
		if err := g.Validate(); err != nil {
			return fmt.Errorf("cluster: shard %d: %w", shard, err)
		}
		for _, n := range g.Nodes {
			if prev, dup := seen[n.ID]; dup {
				return fmt.Errorf("cluster: node %d serves shards %d and %d", n.ID, prev, shard)
			}
			seen[n.ID] = shard
		}
	}
	return nil
}

// ShardFor routes one record id to its shard. Same id, same shard, always:
// routing is data placement, and the hash below is frozen by known answer
// tests because changing it would orphan every record already stored under
// the old map.
func (m ShardMap) ShardFor(id uint64) int {
	return int(splitmix64(id) % uint64(len(m.Groups))) //nolint:gosec // the modulus is the shard count, a small positive int, so neither conversion can truncate
}

// splitmix64 is the output mix of the SplitMix64 generator (Steele, Lea and
// Flood's SplittableRandom, public domain reference by Vigna), used here as
// a 64 bit hash: add the golden gamma, then two multiply xorshift rounds.
// Full avalanche in four arithmetic operations, no tables, which is why
// sequential ids, the common case for a vector collection, land uniformly.
func splitmix64(x uint64) uint64 {
	x += 0x9E3779B97F4A7C15
	x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9
	x = (x ^ (x >> 27)) * 0x94D049BB133111EB
	return x ^ (x >> 31)
}
