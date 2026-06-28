// Package vector provides the in-memory vector store and distance metrics
// that form the storage substrate of the Naylamp engine. The HNSW index
// builds its graph over the vectors stored here, and the brute-force k-NN
// search defined alongside the store serves as the ground truth against
// which the index's recall is measured.
package vector

import (
	"errors"
	"math"
)

// Vector is a single embedding: a unique identifier paired with its
// float32 components. float32 is used (rather than float64) because
// embedding models emit float32 and it halves the memory footprint, which
// is decisive when a database holds millions of vectors.
type Vector struct {
	ID   uint64
	Data []float32
}

// Dim returns the dimensionality of the vector.
func (v Vector) Dim() int {
	return len(v.Data)
}

// Validation errors. They are package-level sentinels so callers can match
// them with errors.Is rather than comparing error strings.
var (
	// ErrEmptyVector indicates a vector with no components.
	ErrEmptyVector = errors.New("vector: data is empty")
	// ErrNonFinite indicates a component that is NaN or +/-Inf, which would
	// corrupt every downstream distance computation.
	ErrNonFinite = errors.New("vector: data contains a non-finite value (NaN or Inf)")
)

// Validate reports whether the vector is well-formed: non-empty and free of
// non-finite values. It is the single gate every vector passes through
// before entering the store, so the distance functions can assume clean input.
func (v Vector) Validate() error {
	if len(v.Data) == 0 {
		return ErrEmptyVector
	}
	for _, x := range v.Data {
		if math.IsNaN(float64(x)) || math.IsInf(float64(x), 0) {
			return ErrNonFinite
		}
	}
	return nil
}
