package persist

import "math"

// float32bits and float32frombits convert a float32 to and from its raw IEEE
// 754 bit pattern, so floats can be written with a fixed byte order. They wrap
// the math package for readability at the call sites in the codec.
func float32bits(f float32) uint32     { return math.Float32bits(f) }
func float32frombits(b uint32) float32 { return math.Float32frombits(b) }
