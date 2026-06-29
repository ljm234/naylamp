package naylamp

import (
	"errors"
	"testing"

	"naylamp/engine/vector"
)

// TestEngine_FullLifecycle exercises the public API the way a user would:
// create a collection, insert vectors, query, and delete.
func TestEngine_FullLifecycle(t *testing.T) {
	e := New()

	col, err := e.CreateCollection("docs", 3, vector.CosineDistance, 42)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}

	// Insert three vectors.
	mustUpsert(t, col, 1, []float32{1, 0, 0})
	mustUpsert(t, col, 2, []float32{0, 1, 0})
	mustUpsert(t, col, 3, []float32{0, 0, 1})

	if col.Len() != 3 {
		t.Fatalf("Len() = %d, want 3", col.Len())
	}

	// Query: closest to [1,0,0] should be id 1.
	got, err := col.Query([]float32{1, 0, 0}, 1)
	if err != nil {
		t.Fatalf("Query: %v", err)
	}
	if len(got) != 1 || got[0].ID != 1 {
		t.Errorf("Query closest = %+v, want id 1", got)
	}

	// Delete id 1, then it must be gone from the store.
	if err := col.Delete(1); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if col.Len() != 2 {
		t.Errorf("Len() after delete = %d, want 2", col.Len())
	}
}

// TestEngine_LookupSameCollection: a collection created can be fetched by name.
func TestEngine_LookupSameCollection(t *testing.T) {
	e := New()
	created, err := e.CreateCollection("docs", 4, vector.L2Distance, 1)
	if err != nil {
		t.Fatalf("CreateCollection: %v", err)
	}
	fetched, err := e.Collection("docs")
	if err != nil {
		t.Fatalf("Collection: %v", err)
	}
	if created != fetched {
		t.Error("fetched collection is not the same instance as created")
	}
}

// TestEngine_Errors checks the API rejects bad input as expected.
func TestEngine_Errors(t *testing.T) {
	e := New()
	col, _ := e.CreateCollection("docs", 3, vector.CosineDistance, 1)

	// Wrong dimensionality on upsert.
	if err := col.Upsert(1, []float32{1, 2}); err == nil {
		t.Error("Upsert with wrong dim should fail, got nil")
	}

	// Wrong dimensionality on query.
	if _, err := col.Query([]float32{1, 2}, 1); err == nil {
		t.Error("Query with wrong dim should fail, got nil")
	}

	// Duplicate collection name.
	if _, err := e.CreateCollection("docs", 3, vector.CosineDistance, 1); !errors.Is(err, ErrCollectionExists) {
		t.Errorf("duplicate create: got %v, want ErrCollectionExists", err)
	}

	// Unknown collection lookup.
	if _, err := e.Collection("ghost"); !errors.Is(err, ErrCollectionNotFound) {
		t.Errorf("unknown lookup: got %v, want ErrCollectionNotFound", err)
	}

	// Invalid dim at creation.
	if _, err := e.CreateCollection("bad", 0, vector.CosineDistance, 1); err == nil {
		t.Error("CreateCollection with dim 0 should fail, got nil")
	}
}

// mustUpsert is a helper that fails the test if Upsert returns an error.
func mustUpsert(t *testing.T, c *Collection, id uint64, data []float32) {
	t.Helper()
	if err := c.Upsert(id, data); err != nil {
		t.Fatalf("Upsert(%d): %v", id, err)
	}
}
