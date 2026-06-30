package hnsw

// cosineDistanceWithNorms computes cosine distance using precomputed norms,
// avoiding the repeated norm calculation that dominated the search hot loop.
// It assumes both norms are already known (cached on the nodes). The result is
// 1 - cosine similarity, so smaller means more similar, matching the public
// vector.CosineDistance. If either norm is zero the result is 1.
//
// This is an internal fast path used only when the index metric is cosine
// distance. For any other metric the index falls back to idx.metric.
func cosineDistanceWithNorms(a, b []float32, normA, normB float32) float32 {
	if normA == 0 || normB == 0 {
		return 1
	}
	var dot float64
	for i := range a {
		dot += float64(a[i]) * float64(b[i])
	}
	similarity := dot / (float64(normA) * float64(normB))
	return float32(1 - similarity)
}
