package vector

import "math"

// DotProduct returns the dot product of two vectors: the sum of their
// element-wise products. It is the building block for the other metrics.
// The accumulator is float64 to limit rounding error, then returned as float32.
func DotProduct(a, b []float32) float32 {
	var sum float64
	for i := range a {
		sum += float64(a[i]) * float64(b[i])
	}
	return float32(sum)
}

// L2Distance returns the Euclidean (straight-line) distance between two
// vectors: the square root of the sum of squared differences. Smaller means
// closer. It powers nearest-neighbor search when the metric is Euclidean.
func L2Distance(a, b []float32) float32 {
	var sum float64
	for i := range a {
		d := float64(a[i]) - float64(b[i])
		sum += d * d
	}
	return float32(math.Sqrt(sum))
}

// CosineDistance returns 1 minus the cosine similarity of two vectors, so
// that smaller means more similar (an angle of zero gives distance zero).
// It measures direction, not magnitude, which is why it is the default for
// comparing text embeddings. If either vector has zero magnitude the result
// is 1 (maximally dissimilar), avoiding a division by zero.
func CosineDistance(a, b []float32) float32 {
	var dot, normA, normB float64
	for i := range a {
		av, bv := float64(a[i]), float64(b[i])
		dot += av * bv
		normA += av * av
		normB += bv * bv
	}
	if normA == 0 || normB == 0 {
		return 1
	}
	similarity := dot / (math.Sqrt(normA) * math.Sqrt(normB))
	return float32(1 - similarity)
}
