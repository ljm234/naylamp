// Package persist provides the on-disk durability layer for the Naylamp
// engine: a versioned binary format, a write-ahead log, snapshots, and
// crash-safe recovery. This file defines the low-level framing every other
// piece relies on: a self-describing block with a magic number, a format
// version, a length-prefixed payload, and a CRC32C checksum so corruption on
// disk is detected rather than silently loaded.
package persist

import (
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
)

// magic identifies a Naylamp on-disk block ("NYLP" in ASCII). It is the first
// thing written and read, so a file that is not ours is rejected immediately.
const magic uint32 = 0x4E594C50 // 'N' 'Y' 'L' 'P'

// formatVersion is the current on-disk format version. Readers reject versions
// they do not understand, which lets the format evolve without silently
// misreading older or newer files.
const formatVersion uint16 = 1

// BlockType tags what a block contains, so a reader can tell a WAL record from
// a snapshot section without guessing.
type BlockType uint16

const (
	// BlockVector is a single serialized vector.
	BlockVector BlockType = 1
	// BlockNode is a single serialized HNSW graph node.
	BlockNode BlockType = 2
	// BlockIndexMeta is the index metadata (params, entry point, counts).
	BlockIndexMeta BlockType = 3
	// BlockWALRecord is a write-ahead log record.
	BlockWALRecord BlockType = 4
)

// crc32cTable is the Castagnoli polynomial table, the CRC used by modern
// storage systems (stronger error detection than the IEEE polynomial, and
// hardware-accelerated on most CPUs).
var crc32cTable = crc32.MakeTable(crc32.Castagnoli)

// Framing errors, exported as sentinels so callers can match with errors.Is.
var (
	// ErrBadMagic means the data does not start with the Naylamp magic number.
	ErrBadMagic = errors.New("persist: bad magic number (not a Naylamp block)")
	// ErrUnknownVersion means the block's format version is not supported.
	ErrUnknownVersion = errors.New("persist: unknown format version")
	// ErrChecksum means the stored CRC does not match the payload (corruption).
	ErrChecksum = errors.New("persist: checksum mismatch (corrupted block)")
	// ErrShortBlock means the data ended before a full block was read (a torn
	// or truncated write, e.g. a crash mid-write).
	ErrShortBlock = errors.New("persist: short block (truncated data)")
)

// blockHeader is the fixed-size prefix of every block on disk. Layout, all
// little-endian:
//
//	magic   uint32 (4 bytes)
//	version uint16 (2 bytes)
//	type    uint16 (2 bytes)
//	length  uint32 (4 bytes)  -- payload length in bytes
//
// Followed by length bytes of payload, then a uint32 CRC32C of the payload.
const headerSize = 4 + 2 + 2 + 4

// writeBlock frames payload as a complete block (header + payload + CRC) and
// writes it to w. It returns the total number of bytes written. The CRC covers
// only the payload; the header is small and its own corruption shows up as a
// bad magic, version, or an implausible length.
func writeBlock(w io.Writer, typ BlockType, payload []byte) (int, error) {
	header := make([]byte, headerSize)
	binary.LittleEndian.PutUint32(header[0:], magic)
	binary.LittleEndian.PutUint16(header[4:], formatVersion)
	binary.LittleEndian.PutUint16(header[6:], uint16(typ))
	binary.LittleEndian.PutUint32(header[8:], uint32(len(payload))) //nolint:gosec // payload length is bounded by sane block sizes, not attacker-controlled

	crc := crc32.Checksum(payload, crc32cTable)
	trailer := make([]byte, 4)
	binary.LittleEndian.PutUint32(trailer, crc)

	total := 0
	n, err := w.Write(header)
	total += n
	if err != nil {
		return total, err
	}
	n, err = w.Write(payload)
	total += n
	if err != nil {
		return total, err
	}
	n, err = w.Write(trailer)
	total += n
	if err != nil {
		return total, err
	}
	return total, nil
}

// readBlock reads one block from r and returns its type and payload. It
// validates the magic number, format version, and CRC, returning a typed error
// for each failure mode. io.EOF is returned cleanly when r is exhausted at a
// block boundary (the normal end of a file); a partial block at the very end
// returns ErrShortBlock, which callers treat as a torn tail and stop on.
func readBlock(r io.Reader) (BlockType, []byte, error) {
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(r, header); err != nil {
		if errors.Is(err, io.EOF) {
			return 0, nil, io.EOF // clean end at a block boundary
		}
		if errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, nil, ErrShortBlock // torn header
		}
		return 0, nil, err
	}

	if got := binary.LittleEndian.Uint32(header[0:]); got != magic {
		return 0, nil, fmt.Errorf("%w: got %#x", ErrBadMagic, got)
	}
	if got := binary.LittleEndian.Uint16(header[4:]); got != formatVersion {
		return 0, nil, fmt.Errorf("%w: got %d, support %d", ErrUnknownVersion, got, formatVersion)
	}
	typ := BlockType(binary.LittleEndian.Uint16(header[6:]))
	length := binary.LittleEndian.Uint32(header[8:])

	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, nil, ErrShortBlock // payload truncated
		}
		return 0, nil, err
	}

	trailer := make([]byte, 4)
	if _, err := io.ReadFull(r, trailer); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, nil, ErrShortBlock // CRC truncated
		}
		return 0, nil, err
	}
	wantCRC := binary.LittleEndian.Uint32(trailer)
	if gotCRC := crc32.Checksum(payload, crc32cTable); gotCRC != wantCRC {
		return 0, nil, fmt.Errorf("%w: want %#x got %#x", ErrChecksum, wantCRC, gotCRC)
	}

	return typ, payload, nil
}
