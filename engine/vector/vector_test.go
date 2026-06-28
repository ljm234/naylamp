package vector

import (
	"errors"
	"math"
	"testing"
)

func TestVector_Dim(t *testing.T) {
	v := Vector{ID: 1, Data: []float32{1, 2, 3}}
	if got := v.Dim(); got != 3 {
		t.Errorf("Dim() = %d, want 3", got)
	}
}

func TestVector_Validate(t *testing.T) {
	tests := []struct {
		name    string
		data    []float32
		wantErr error
	}{
		{
			name:    "valid vector",
			data:    []float32{0.1, -0.5, 0.8},
			wantErr: nil,
		},
		{
			name:    "single element is valid",
			data:    []float32{1.0},
			wantErr: nil,
		},
		{
			name:    "empty data is rejected",
			data:    []float32{},
			wantErr: ErrEmptyVector,
		},
		{
			name:    "nil data is rejected",
			data:    nil,
			wantErr: ErrEmptyVector,
		},
		{
			name:    "NaN is rejected",
			data:    []float32{1.0, float32(math.NaN()), 3.0},
			wantErr: ErrNonFinite,
		},
		{
			name:    "positive infinity is rejected",
			data:    []float32{1.0, float32(math.Inf(1))},
			wantErr: ErrNonFinite,
		},
		{
			name:    "negative infinity is rejected",
			data:    []float32{float32(math.Inf(-1)), 2.0},
			wantErr: ErrNonFinite,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := Vector{ID: 1, Data: tt.data}
			err := v.Validate()
			if !errors.Is(err, tt.wantErr) {
				t.Errorf("Validate() error = %v, want %v", err, tt.wantErr)
			}
		})
	}
}
