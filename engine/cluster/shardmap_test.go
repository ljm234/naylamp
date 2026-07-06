package cluster

import (
	"strings"
	"testing"
)

// shardGroups builds k disjoint replica groups of three nodes each with
// globally unique ids.
func shardGroups(k int) []Config {
	groups := make([]Config, k)
	id := NodeID(1)
	for s := range groups {
		var nodes []NodeAddr
		for r := 0; r < 3; r++ {
			nodes = append(nodes, NodeAddr{ID: id})
			id++
		}
		groups[s] = Config{Nodes: nodes}
	}
	return groups
}

// TestShardMap_SplitMix64KnownAnswers freezes the routing hash itself with
// reference values computed from the public domain SplitMix64 definition
// (the zero input matches the generator's published first output for state
// zero). If this test ever breaks, data placement changed and every stored
// record is orphaned: fix the hash, never update the constants.
func TestShardMap_SplitMix64KnownAnswers(t *testing.T) {
	cases := map[uint64]uint64{
		0:                  0xE220A8397B1DCDAF,
		1:                  0x910A2DEC89025CC1,
		2:                  0x975835DE1C9756CE,
		42:                 0xBDD732262FEB6E95,
		0xFFFFFFFFFFFFFFFF: 0xE4D971771B652C20,
	}
	for in, want := range cases {
		if got := splitmix64(in); got != want {
			t.Fatalf("splitmix64(%#x) = %#x, want %#x", in, got, want)
		}
	}
}

// TestShardMap_DeterministicRouting: same id, same shard, always, on the
// same map and on an equal one, and every answer is in range.
func TestShardMap_DeterministicRouting(t *testing.T) {
	m := ShardMap{Groups: shardGroups(4)}
	if err := m.Validate(); err != nil {
		t.Fatalf("valid map rejected: %v", err)
	}
	m2 := ShardMap{Groups: shardGroups(4)}
	for id := uint64(0); id < 10000; id++ {
		s := m.ShardFor(id)
		if s < 0 || s >= m.K() {
			t.Fatalf("shard out of range for id %d: %d", id, s)
		}
		if s != m.ShardFor(id) || s != m2.ShardFor(id) {
			t.Fatalf("routing not deterministic for id %d", id)
		}
	}
}

// TestShardMap_SequentialIDsSpreadEvenly pins the mixing quality on the
// common case: sequential ids. Measured deviation is well under 100 per
// shard for this exact input; the bound of 300 leaves room without letting
// a broken mix pass.
func TestShardMap_SequentialIDsSpreadEvenly(t *testing.T) {
	const n, k = 10000, 4
	m := ShardMap{Groups: shardGroups(k)}
	counts := make([]int, k)
	for id := uint64(0); id < n; id++ {
		counts[m.ShardFor(id)]++
	}
	for s, c := range counts {
		if c < n/k-300 || c > n/k+300 {
			t.Fatalf("shard %d holds %d of %d sequential ids, want %d within 300: %v", s, c, n, n/k, counts)
		}
	}
}

// TestShardMap_ValidateFailsLoudly: an unusable map is refused with a
// reason, never silently accepted.
func TestShardMap_ValidateFailsLoudly(t *testing.T) {
	if err := (ShardMap{}).Validate(); err == nil {
		t.Fatalf("empty shard map accepted")
	}
	dup := shardGroups(2)
	dup[1].Nodes[0].ID = dup[0].Nodes[0].ID
	if err := (ShardMap{Groups: dup}).Validate(); err == nil || !strings.Contains(err.Error(), "serves shards") {
		t.Fatalf("duplicate node id across shards accepted: %v", err)
	}
	bad := shardGroups(2)
	bad[0] = Config{}
	if err := (ShardMap{Groups: bad}).Validate(); err == nil {
		t.Fatalf("shard with an invalid replica group accepted")
	}
}
