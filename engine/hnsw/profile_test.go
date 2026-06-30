package hnsw

import (
	"testing"

	"naylamp/engine/vector"
)

// BenchmarkBuildIndex builds an index of moderate size so we can profile where
// construction spends its time. Run with CPU profiling:
//
//	go test -run=^$ -bench=BuildIndex -benchtime=1x -cpuprofile=cpu.out ./hnsw/...
//	go tool pprof -top -nodecount=15 cpu.out
func BenchmarkBuildIndex(b *testing.B) {
	const (
		n   = 30000
		dim = 64
	)
	vecs := makeRandomVectors(n, dim, 1)

	b.ResetTimer()
	for iter := 0; iter < b.N; iter++ {
		store := vector.NewStore()
		idx := NewIndex(DefaultParams(), vector.CosineDistance, func(id uint64) ([]float32, bool) {
			v, err := store.Get(id)
			if err != nil {
				return nil, false
			}
			return v.Data, true
		}, 1)
		for _, v := range vecs {
			_ = store.Insert(v)
			_ = idx.Insert(v.ID)
		}
	}
}
