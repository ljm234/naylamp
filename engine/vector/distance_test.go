package vector

import (
	"math"
	"testing"
)

// floatEqual reports whether two float32 values are within a small tolerance.
// Floating-point math is not exact, so we never compare with ==.
func floatEqual(a, b float32) bool {
	const tolerance = 1e-6
	return math.Abs(float64(a)-float64(b)) < tolerance
}

func TestDotProduct(t *testing.T) {
	// [1,2,3] . [4,5,6] = 4 + 10 + 18 = 32
	a := []float32{1, 2, 3}
	b := []float32{4, 5, 6}
	if got := DotProduct(a, b); !floatEqual(got, 32) {
		t.Errorf("DotProduct = %v, want 32", got)
	}
}

func TestL2Distance(t *testing.T) {
	// [0,0] -> [3,4]: sqrt(9 + 16) = sqrt(25) = 5
	a := []float32{0, 0}
	b := []float32{3, 4}
	if got := L2Distance(a, b); !floatEqual(got, 5) {
		t.Errorf("L2Distance = %v, want 5", got)
	}
	// distance from a vector to itself is 0
	if got := L2Distance(a, a); !floatEqual(got, 0) {
		t.Errorf("L2Distance(a,a) = %v, want 0", got)
	}
}

func TestCosineDistance(t *testing.T) {
	// identical direction -> distance 0
	a := []float32{1, 2, 3}
	if got := CosineDistance(a, a); !floatEqual(got, 0) {
		t.Errorf("CosineDistance(a,a) = %v, want 0", got)
	}
	// orthogonal vectors -> similarity 0 -> distance 1
	x := []float32{1, 0}
	y := []float32{0, 1}
	if got := CosineDistance(x, y); !floatEqual(got, 1) {
		t.Errorf("CosineDistance(orthogonal) = %v, want 1", got)
	}
	// zero vector -> guard returns 1
	zero := []float32{0, 0}
	if got := CosineDistance(zero, y); !floatEqual(got, 1) {
		t.Errorf("CosineDistance(zero) = %v, want 1", got)
	}
}
