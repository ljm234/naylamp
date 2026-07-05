package persist

import "io"

// This file exposes the block framing to sibling packages. The framing itself
// (magic, version, type, CRC32C) lives in format.go and is used internally by
// the WAL, snapshots and the manifest; the cluster layer reuses the same
// framing for its wire messages, so every byte that crosses the network
// carries the same integrity guarantees as every byte that touches disk. The
// wrappers are additive: nothing in the sealed persistence paths changes.
// The block type registry below is the single authority for cross-package
// types, so two packages can never collide on a number.

// BlockClusterMessage frames a cluster wire message. It extends the block
// type registry defined in format.go.
const BlockClusterMessage BlockType = 5

// BlockRaftHardState frames a Raft node's persisted hard state (term, vote,
// commit), the part of consensus state that must survive a crash.
const BlockRaftHardState BlockType = 6

// BlockRaftEntry frames one replicated log entry in the Raft durable log.
const BlockRaftEntry BlockType = 7

// BlockRaftSnapshot frames the durable snapshot of a Raft node: the applied
// state machine image at a log position, plus that position's index and term.
const BlockRaftSnapshot BlockType = 8

// WriteBlock frames payload with the block format (magic, version, type,
// length, CRC32C) and writes it to w, returning the bytes written.
func WriteBlock(w io.Writer, typ BlockType, payload []byte) (int, error) {
	return writeBlock(w, typ, payload)
}

// ReadBlock reads one framed block from r, verifying magic, version and
// checksum, and returns its type and payload. Errors mirror the internal
// reader: io.EOF at a clean end; ErrShortBlock, ErrBadMagic,
// ErrUnknownVersion or ErrChecksum otherwise.
func ReadBlock(r io.Reader) (BlockType, []byte, error) {
	return readBlock(r)
}
