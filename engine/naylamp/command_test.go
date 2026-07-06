package naylamp

import (
	"errors"
	"math"
	"testing"
)

func TestCommand_UpsertRoundTrip(t *testing.T) {
	vec := []float32{0, -1.5, 3.25e7, float32(math.Pi), -0.000244140625}
	raw := encodeUpsert(math.MaxUint64, vec)
	c, err := decodeCommand(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if c.Op != opUpsert || c.ID != math.MaxUint64 || len(c.Vec) != len(vec) {
		t.Fatalf("round trip shape wrong: %+v", c)
	}
	for i := range vec {
		if math.Float32bits(c.Vec[i]) != math.Float32bits(vec[i]) {
			t.Fatalf("float bits not preserved at %d: %x vs %x", i, math.Float32bits(c.Vec[i]), math.Float32bits(vec[i]))
		}
	}
}

func TestCommand_DeleteRoundTrip(t *testing.T) {
	raw := encodeDelete(42)
	c, err := decodeCommand(raw)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if c.Op != opDelete || c.ID != 42 || c.Vec != nil {
		t.Fatalf("round trip wrong: %+v", c)
	}
}

func TestCommand_MalformedFailsLoudly(t *testing.T) {
	upsert := encodeUpsert(7, []float32{1, 2})
	lyingHigh := append([]byte(nil), upsert...)
	lyingHigh[9] = 5 // claims 5 floats, carries 2
	lyingLow := append([]byte(nil), upsert...)
	lyingLow[9] = 1 // claims 1 float, carries 2: trailing bytes
	badOp := append([]byte(nil), upsert...)
	badOp[0] = 9

	cases := map[string][]byte{
		"empty":                   {},
		"short header":            {opDelete, 1, 2, 3},
		"unknown op":              badOp,
		"truncated upsert header": encodeUpsert(7, []float32{1})[:10],
		"zero dimensions":         append([]byte{opUpsert}, make([]byte, 12)...),
		"count above payload":     lyingHigh,
		"count below payload":     lyingLow,
		"trailing on delete":      append(encodeDelete(7), 0xAA),
	}
	for name, raw := range cases {
		if _, err := decodeCommand(raw); !errors.Is(err, ErrMalformedCommand) {
			t.Fatalf("%s accepted: %v", name, err)
		}
	}
}
