package raft

import "testing"

// ent builds a bare entry for tests.
func ent(index, term uint64) Entry {
	return Entry{Index: index, Term: term}
}

// mustAppend seeds a log or fails the test.
func mustAppend(t *testing.T, l *Log, entries ...Entry) {
	t.Helper()
	if err := l.Append(entries...); err != nil {
		t.Fatalf("seed append: %v", err)
	}
}

func TestLog_EmptyState(t *testing.T) {
	l := NewLog()
	if l.LastIndex() != 0 || l.LastTerm() != 0 {
		t.Fatalf("empty log: last=(%d,%d), want (0,0)", l.LastIndex(), l.LastTerm())
	}
	if term, ok := l.Term(0); !ok || term != 0 {
		t.Fatalf("sentinel Term(0)=(%d,%v), want (0,true)", term, ok)
	}
	if _, ok := l.Term(1); ok {
		t.Fatalf("Term(1) answered on empty log")
	}
	if _, ok := l.Entry(1); ok {
		t.Fatalf("Entry(1) answered on empty log")
	}
	if s := l.Slice(1); s != nil {
		t.Fatalf("Slice on empty log = %v, want nil", s)
	}
}

func TestLog_AppendAndRead(t *testing.T) {
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2))
	if l.LastIndex() != 3 || l.LastTerm() != 2 {
		t.Fatalf("last=(%d,%d), want (3,2)", l.LastIndex(), l.LastTerm())
	}
	if term, ok := l.Term(2); !ok || term != 1 {
		t.Fatalf("Term(2)=(%d,%v), want (1,true)", term, ok)
	}
	if err := l.Append(ent(5, 2)); err == nil {
		t.Fatalf("gap append accepted")
	}
	if err := l.Append(ent(4, 1)); err == nil {
		t.Fatalf("term regression accepted")
	}
	out := l.Slice(2)
	if len(out) != 2 || out[0].Index != 2 || out[1].Index != 3 {
		t.Fatalf("Slice(2) = %v", out)
	}
	out[0].Index = 99
	if got, _ := l.Entry(2); got.Index != 2 {
		t.Fatalf("Slice shares backing array with the log")
	}
}

func TestLog_TryAppend_MatchAndIdempotent(t *testing.T) {
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2))

	last, ok := l.TryAppend(3, 2, []Entry{ent(4, 2), ent(5, 2)})
	if !ok || last != 5 {
		t.Fatalf("append at tail = (%d,%v), want (5,true)", last, ok)
	}
	// Retransmission of the same batch must be a no-op that still succeeds.
	last, ok = l.TryAppend(3, 2, []Entry{ent(4, 2), ent(5, 2)})
	if !ok || last != 5 || l.LastIndex() != 5 {
		t.Fatalf("retransmission = (%d,%v), log last %d", last, ok, l.LastIndex())
	}
	// Unknown previous position is refused.
	if _, ok := l.TryAppend(10, 2, []Entry{ent(11, 2)}); ok {
		t.Fatalf("append beyond log accepted")
	}
	// Wrong previous term is refused.
	if _, ok := l.TryAppend(3, 9, []Entry{ent(4, 9)}); ok {
		t.Fatalf("prev term mismatch accepted")
	}
	// A batch that is not contiguous from prev is malformed.
	if _, ok := l.TryAppend(5, 2, []Entry{ent(7, 2)}); ok {
		t.Fatalf("non-contiguous batch accepted")
	}
	// Heartbeat: empty entries against a matching position succeed.
	if last, ok := l.TryAppend(5, 2, nil); !ok || last != 5 {
		t.Fatalf("heartbeat = (%d,%v), want (5,true)", last, ok)
	}
}

func TestLog_TryAppend_ConflictTruncation(t *testing.T) {
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2), ent(4, 2), ent(5, 2))

	// New leader overwrites a divergent suffix: skip the matching prefix,
	// truncate at the first conflict, install the incoming tail.
	last, ok := l.TryAppend(2, 1, []Entry{ent(3, 2), ent(4, 3)})
	if !ok || last != 4 {
		t.Fatalf("conflict append = (%d,%v), want (4,true)", last, ok)
	}
	if term, _ := l.Term(3); term != 2 {
		t.Fatalf("matching entry 3 was rewritten: term %d", term)
	}
	if term, _ := l.Term(4); term != 3 {
		t.Fatalf("conflicting entry 4 not replaced: term %d", term)
	}
	if _, ok := l.Entry(5); ok {
		t.Fatalf("divergent suffix survived truncation")
	}
}

func TestLog_CompactTo(t *testing.T) {
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2), ent(4, 2), ent(5, 3), ent(6, 3))

	if err := l.CompactTo(4, 2); err != nil {
		t.Fatalf("compact: %v", err)
	}
	if l.LastIndex() != 6 || l.LastTerm() != 3 {
		t.Fatalf("after compact last=(%d,%d), want (6,3)", l.LastIndex(), l.LastTerm())
	}
	if term, ok := l.Term(4); !ok || term != 2 {
		t.Fatalf("base Term(4)=(%d,%v), want (2,true)", term, ok)
	}
	if _, ok := l.Term(3); ok {
		t.Fatalf("Term below base answered")
	}
	if _, ok := l.Entry(4); ok {
		t.Fatalf("Entry at base still present")
	}
	if s := l.Slice(1); len(s) != 2 || s[0].Index != 5 {
		t.Fatalf("Slice after compact = %v", s)
	}
	// Idempotent at or below the current base.
	if err := l.CompactTo(2, 1); err != nil {
		t.Fatalf("re-compact below base: %v", err)
	}
	// Beyond the last index and term mismatches are refused.
	if err := l.CompactTo(10, 3); err == nil {
		t.Fatalf("compact beyond last accepted")
	}
	if err := l.CompactTo(5, 9); err == nil {
		t.Fatalf("compact with wrong term accepted")
	}
	// The log keeps working on top of a base.
	if err := l.Append(ent(7, 3)); err != nil {
		t.Fatalf("append after compact: %v", err)
	}
	// Probing below the base is treated as matched committed history, and
	// entries at or below the base are skipped.
	last, ok := l.TryAppend(3, 999, []Entry{ent(4, 2), ent(5, 3)})
	if !ok || last != 7 {
		t.Fatalf("probe below base = (%d,%v), want (7,true)", last, ok)
	}
}

func TestLog_IsUpToDate(t *testing.T) {
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2))

	cases := []struct {
		lastIndex, lastTerm uint64
		want                bool
	}{
		{3, 2, true},
		{5, 2, true},
		{2, 2, false},
		{1, 3, true},
		{9, 1, false},
	}
	for _, c := range cases {
		if got := l.IsUpToDate(c.lastIndex, c.lastTerm); got != c.want {
			t.Fatalf("IsUpToDate(%d,%d) = %v, want %v", c.lastIndex, c.lastTerm, got, c.want)
		}
	}
}

func TestLog_ResetToSnapshot(t *testing.T) {
	// Matching position: the suffix survives.
	l := NewLog()
	mustAppend(t, l, ent(1, 1), ent(2, 1), ent(3, 2), ent(4, 2), ent(5, 3), ent(6, 3))
	l.ResetToSnapshot(4, 2)
	if l.LastIndex() != 6 || l.LastTerm() != 3 {
		t.Fatalf("suffix lost: last=(%d,%d)", l.LastIndex(), l.LastTerm())
	}
	if term, ok := l.Term(4); !ok || term != 2 {
		t.Fatalf("base wrong: (%d,%v)", term, ok)
	}
	if _, ok := l.Entry(4); ok {
		t.Fatalf("entry at base survived")
	}
	// Stale snapshot: no-op.
	l.ResetToSnapshot(2, 1)
	if l.LastIndex() != 6 {
		t.Fatalf("stale snapshot mutated the log")
	}
	// Mismatching term at the position: everything is stale history.
	l.ResetToSnapshot(5, 9)
	if l.LastIndex() != 5 || l.LastTerm() != 9 || len(l.entries) != 0 {
		t.Fatalf("mismatch did not discard: last=(%d,%d) n=%d", l.LastIndex(), l.LastTerm(), len(l.entries))
	}
	// Snapshot beyond the log: fresh base, appends continue after it.
	l2 := NewLog()
	mustAppend(t, l2, ent(1, 1))
	l2.ResetToSnapshot(10, 4)
	if l2.LastIndex() != 10 || l2.LastTerm() != 4 {
		t.Fatalf("beyond-log reset wrong: (%d,%d)", l2.LastIndex(), l2.LastTerm())
	}
	if err := l2.Append(ent(11, 4)); err != nil {
		t.Fatalf("append after reset: %v", err)
	}
}
