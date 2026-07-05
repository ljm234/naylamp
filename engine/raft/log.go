package raft

import (
	"errors"
	"fmt"
)

// Log is the in-memory replicated log. Indexing follows the paper: entries
// are 1-based and index 0 is the empty sentinel with term 0. The log keeps a
// compaction base (baseIndex, baseTerm), the position of the last entry
// folded into a snapshot. Subphase 3.2 never compacts, but the durable log
// and InstallSnapshot of 3.3 do, and retrofitting offset arithmetic under a
// live consensus core is exactly the rework that building it in from day one
// avoids. Everything at or below the base is by definition committed,
// applied and immutable.
type Log struct {
	baseIndex uint64
	baseTerm  uint64
	entries   []Entry // entries[i].Index == baseIndex + uint64(i) + 1
}

// NewLog returns an empty log with no compaction base.
func NewLog() *Log { return &Log{} }

// LastIndex returns the index of the last entry, or the base when empty.
func (l *Log) LastIndex() uint64 {
	return l.baseIndex + uint64(len(l.entries))
}

// LastTerm returns the term of the last entry, or the base term when empty.
func (l *Log) LastTerm() uint64 {
	if len(l.entries) == 0 {
		return l.baseTerm
	}
	return l.entries[len(l.entries)-1].Term
}

// Term returns the term of the entry at index i. The second result is false
// when the log cannot answer: above the last entry or strictly below the
// compaction base. The sentinel 0 and the base itself still answer.
func (l *Log) Term(i uint64) (uint64, bool) {
	switch {
	case i == 0:
		return 0, true
	case i < l.baseIndex:
		return 0, false
	case i == l.baseIndex:
		return l.baseTerm, true
	case i > l.LastIndex():
		return 0, false
	}
	return l.entries[i-l.baseIndex-1].Term, true
}

// Entry returns the entry at index i when it is still present.
func (l *Log) Entry(i uint64) (Entry, bool) {
	if i <= l.baseIndex || i > l.LastIndex() {
		return Entry{}, false
	}
	return l.entries[i-l.baseIndex-1], true
}

// Slice returns a copy of the entries from index from through the last one.
// Copying keeps the log's backing array out of reach of message buffers.
func (l *Log) Slice(from uint64) []Entry {
	if from <= l.baseIndex {
		from = l.baseIndex + 1
	}
	last := l.LastIndex()
	if from > last {
		return nil
	}
	out := make([]Entry, last-from+1)
	copy(out, l.entries[from-l.baseIndex-1:])
	return out
}

// Append adds pre-formed entries to the tail. This is the leader-side path:
// raft.go assigns Index and Term at Propose time, so a gap or a term
// regression here is a programming error, not a protocol condition.
func (l *Log) Append(entries ...Entry) error {
	for _, e := range entries {
		if e.Index != l.LastIndex()+1 {
			return fmt.Errorf("raft: append index %d does not follow last index %d", e.Index, l.LastIndex())
		}
		if e.Term < l.LastTerm() {
			return fmt.Errorf("raft: append term %d regresses from term %d", e.Term, l.LastTerm())
		}
		l.entries = append(l.entries, e)
	}
	return nil
}

// matches reports whether the log contains index i with term t. Positions
// strictly below the compaction base are considered matched: only committed
// entries are ever compacted, and committed entries are immutable, so a
// leader probing under the base is probing history that already agreed. The
// base itself is verifiable and is verified.
func (l *Log) matches(i, t uint64) bool {
	if i < l.baseIndex {
		return true
	}
	term, ok := l.Term(i)
	return ok && term == t
}

// TryAppend is the follower side of AppendEntries: the log matching check
// and conflict resolution of the paper in one operation. It refuses when the
// log does not contain (prevIndex, prevTerm), and it refuses malformed
// batches whose entries are not contiguous from prevIndex. Otherwise it
// walks the incoming entries: ones the log already holds with the same term
// are skipped, which makes retransmitted and reordered messages idempotent;
// the first index holding a different term is a conflict, so the divergent
// suffix is truncated and replaced by the incoming tail. Returns the new
// last index and whether the append was accepted.
func (l *Log) TryAppend(prevIndex, prevTerm uint64, entries []Entry) (uint64, bool) {
	next := prevIndex + 1
	for _, e := range entries {
		if e.Index != next {
			return l.LastIndex(), false
		}
		next++
	}
	if !l.matches(prevIndex, prevTerm) {
		return l.LastIndex(), false
	}
	for k, e := range entries {
		if e.Index <= l.baseIndex {
			continue // compacted, therefore committed and identical
		}
		term, ok := l.Term(e.Index)
		if ok && term == e.Term {
			continue // already present
		}
		if ok {
			// Conflict: keep the agreed prefix, drop the divergent suffix.
			l.entries = l.entries[:e.Index-l.baseIndex-1]
		}
		l.entries = append(l.entries, entries[k:]...)
		break
	}
	return l.LastIndex(), true
}

// CompactTo drops every entry at or below index, recording (index, term) as
// the new base. Callers must only compact committed history; the log
// enforces what it can verify: the position must exist with that exact term
// and the base never moves backwards. Idempotent below the current base.
func (l *Log) CompactTo(index, term uint64) error {
	if index <= l.baseIndex {
		return nil
	}
	if index > l.LastIndex() {
		return fmt.Errorf("raft: compact to %d beyond last index %d", index, l.LastIndex())
	}
	got, _ := l.Term(index)
	if got != term {
		return errors.New("raft: compact term mismatch")
	}
	l.entries = append([]Entry(nil), l.entries[index-l.baseIndex:]...)
	l.baseIndex = index
	l.baseTerm = term
	return nil
}

// ResetToSnapshot installs a snapshot position as the new compaction base,
// following section 7 of the paper: when the log still holds an entry at
// (index, term), the suffix beyond it is retained; any other content is
// stale history and the whole log is discarded. A snapshot at or below the
// current base is itself stale and is a no-op.
func (l *Log) ResetToSnapshot(index, term uint64) {
	if index <= l.baseIndex {
		return
	}
	if got, ok := l.Term(index); ok && got == term {
		l.entries = append([]Entry(nil), l.entries[index-l.baseIndex:]...)
	} else {
		l.entries = nil
	}
	l.baseIndex = index
	l.baseTerm = term
}

// IsUpToDate implements the voting restriction of section 5.4.1: a vote may
// only go to a candidate whose log is at least as complete as ours, which is
// what keeps every committed entry present in any electable leader.
func (l *Log) IsUpToDate(lastIndex, lastTerm uint64) bool {
	if lastTerm != l.LastTerm() {
		return lastTerm > l.LastTerm()
	}
	return lastIndex >= l.LastIndex()
}
