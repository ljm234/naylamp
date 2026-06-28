package vector

import (
	"errors"
	"testing"
)

func TestStore_InsertLenGet(t *testing.T) {
	s := NewStore()
	_ = s.Insert(Vector{ID: 1, Data: []float32{1, 0}})
	_ = s.Insert(Vector{ID: 2, Data: []float32{0, 1}})
	_ = s.Insert(Vector{ID: 3, Data: []float32{1, 1}})

	if s.Len() != 3 {
		t.Fatalf("Len() = %d, want 3", s.Len())
	}

	v, err := s.Get(2)
	if err != nil {
		t.Fatalf("Get(2) returned error: %v", err)
	}
	if v.ID != 2 {
		t.Errorf("Get(2).ID = %d, want 2", v.ID)
	}
}

func TestStore_Delete(t *testing.T) {
	s := NewStore()
	_ = s.Insert(Vector{ID: 1, Data: []float32{1, 0}})

	if err := s.Delete(1); err != nil {
		t.Fatalf("Delete(1) returned error: %v", err)
	}
	if _, err := s.Get(1); !errors.Is(err, ErrNotFound) {
		t.Errorf("Get after delete: got %v, want ErrNotFound", err)
	}
	// deleting again should report not found
	if err := s.Delete(1); !errors.Is(err, ErrNotFound) {
		t.Errorf("Delete twice: got %v, want ErrNotFound", err)
	}
}

func TestStore_InsertRejectsInvalid(t *testing.T) {
	s := NewStore()
	err := s.Insert(Vector{ID: 1, Data: []float32{}}) // empty data
	if !errors.Is(err, ErrEmptyVector) {
		t.Errorf("Insert(empty): got %v, want ErrEmptyVector", err)
	}
	if s.Len() != 0 {
		t.Errorf("Len() = %d after rejected insert, want 0", s.Len())
	}
}

func TestStore_Search(t *testing.T) {
	s := NewStore()
	// Three points on a line. Query is closest to id 1, then 2, then 3.
	_ = s.Insert(Vector{ID: 1, Data: []float32{1, 0}})
	_ = s.Insert(Vector{ID: 2, Data: []float32{5, 0}})
	_ = s.Insert(Vector{ID: 3, Data: []float32{10, 0}})

	query := []float32{0, 0}
	got := s.Search(query, 2, L2Distance)

	if len(got) != 2 {
		t.Fatalf("Search returned %d results, want 2", len(got))
	}
	// Nearest to [0,0] is id 1 (distance 1), then id 2 (distance 5).
	if got[0].ID != 1 {
		t.Errorf("closest = id %d, want id 1", got[0].ID)
	}
	if got[1].ID != 2 {
		t.Errorf("second = id %d, want id 2", got[1].ID)
	}
}
