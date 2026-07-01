package persist

import (
	"fmt"
	"testing"

	"math/rand/v2"

	"naylamp/engine/vector"
)

// This file benchmarks the cost of durability: how fast writes commit under
// each fsync policy, and how long recovery takes as a function of WAL size.
// These are the concrete numbers that quantify the durability guarantees.

// BenchmarkDurability_WriteThroughput measures append throughput under both
// fsync policies. FsyncAlways is the durable, production setting; FsyncNever is
// the upper bound with no durability, included to show the cost of fsync.
func BenchmarkDurability_WriteThroughput(b *testing.B) {
	const dim = 128
	policies := []struct {
		name   string
		policy FsyncPolicy
	}{
		{"FsyncAlways", FsyncAlways},
		{"FsyncNever", FsyncNever},
	}

	for _, p := range policies {
		b.Run(p.name, func(b *testing.B) {
			dir := b.TempDir()
			wal, err := OpenWAL(dir, p.policy)
			if err != nil {
				b.Fatalf("open wal: %v", err)
			}
			defer func() { _ = wal.Close() }()

			rng := rand.New(rand.NewPCG(1, 0)) //nolint:gosec // deterministic RNG for reproducible bench data, not security
			data := make([]float32, dim)
			for i := range data {
				data[i] = float32(rng.NormFloat64())
			}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := wal.Append(OpUpsert, vector.Vector{ID: uint64(i + 1), Data: data}); err != nil {
					b.Fatalf("append: %v", err)
				}
			}
			b.StopTimer()
		})
	}
}

// BenchmarkDurability_RecoveryTime measures how long recovery takes as the WAL
// grows. It is reported per WAL size so the scaling is visible.
func BenchmarkDurability_RecoveryTime(b *testing.B) {
	const dim = 128
	sizes := []int{1000, 10000, 50000}

	for _, size := range sizes {
		b.Run(fmt.Sprintf("records=%d", size), func(b *testing.B) {
			// Prepare a data dir with `size` records in the WAL, once.
			dir := b.TempDir()
			wal, err := OpenWAL(dir, FsyncNever) // fast setup; durability not under test here
			if err != nil {
				b.Fatalf("open wal: %v", err)
			}
			rng := rand.New(rand.NewPCG(2, 0)) //nolint:gosec // deterministic RNG for reproducible bench data, not security
			for i := 1; i <= size; i++ {
				data := make([]float32, dim)
				for j := range data {
					data[j] = float32(rng.NormFloat64())
				}
				if _, err := wal.Append(OpUpsert, vector.Vector{ID: uint64(i), Data: data}); err != nil {
					b.Fatalf("append: %v", err)
				}
			}
			if err := wal.Close(); err != nil {
				b.Fatalf("close: %v", err)
			}

			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				state, rerr := Recover(dir, vector.CosineDistance, 1)
				if rerr != nil {
					b.Fatalf("recover: %v", rerr)
				}
				if state.Index.Len() != size {
					b.Fatalf("recovered %d, want %d", state.Index.Len(), size)
				}
			}
		})
	}
}
