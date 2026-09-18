package main

import (
	"bufio"
	"errors"
	"os"
	"strings"
	"testing"
)

// newStdin swaps os.Stdin for a file holding exactly the given bytes and returns
// a function that puts it back. The file is CREATED rather than opened, so the
// test hands the scanner a descriptor it made itself and no path is ever read
// from a variable, which is what gosec's G304 is about.
func newStdin(t *testing.T, input string) {
	t.Helper()
	f, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatalf("create the input: %v", err)
	}
	if _, werr := f.WriteString(input); werr != nil {
		t.Fatalf("write the input: %v", werr)
	}
	if _, serr := f.Seek(0, 0); serr != nil {
		t.Fatalf("rewind the input: %v", serr)
	}
	old := os.Stdin
	os.Stdin = f
	t.Cleanup(func() {
		os.Stdin = old
		_ = f.Close()
	})
}

// A stream that dies mid-read and a stream the operator ended look identical at
// the prompt: the Scan loop stops and the function returns. Only the exit status
// and the message can tell them apart, and before this row existed neither did:
// the REPL returned as if end of input had been typed and the process exited
// zero.
//
// The reachable way in is a line past the scanner's ceiling, which is what
// pasting a large vector at the prompt produces. The input below is two such
// lines' worth, so Scan stops with its own error before it can hand a single
// field to dispatch, and the row asserts that the error comes back instead of
// being swallowed. It exercises no command, so the zero client is enough.
func TestClientReplReportsAReadFailureInsteadOfEndingSilently(t *testing.T) {
	newStdin(t, strings.Repeat("a", 2*bufio.MaxScanTokenSize)+"\n")

	err := (&client{}).repl()
	if err == nil {
		t.Fatal("a read that died at the scanner's ceiling ended the REPL as if end of input had been typed: the session closes with no message and the process exits zero")
	}
	if !errors.Is(err, bufio.ErrTooLong) {
		t.Fatalf("the REPL reported %v, which does not name the scanner's own error", err)
	}
}

// The control, and it is the half that keeps the row above honest: a stream that
// ends is NOT a failure, so the ordinary path must still answer nil. Without
// this, a REPL that reported every ending as an error would pass the row above.
func TestClientReplAcceptsEndOfInput(t *testing.T) {
	newStdin(t, "")

	if err := (&client{}).repl(); err != nil {
		t.Fatalf("an empty stream is end of input, not a failure, and it came back as %v", err)
	}
}
