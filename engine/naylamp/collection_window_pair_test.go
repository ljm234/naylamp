package naylamp

import (
	"os"
	"strings"
	"testing"
)

// The two window defenders need each other and until 2026-08-31 nothing said
// so outside the register. The measured split, twenty runs per cell against
// mutations of Upsert in operations.go:
//
//	mutation                             window probe   atomicity defender
//	no Lock at all                       green          red
//	Lock released BEFORE index.Insert     green          red
//	Lock taken AFTER store.Insert         red            green
//
// Retiring either one leaves an end of the window unwatched, and retiring the
// atomicity defender leaves unwatched the end that the most destructive
// mutation opens. A comment saying so is a request for attention, and this
// house has already written down that a request for attention is obeyed when
// somebody looks and not before. So the pair is held by two things that fail
// on their own.
//
// The first is the two lines below, and they are the strong half: they name
// both test functions as values, so deleting either one stops the PACKAGE from
// compiling. Not a failing test, a build error, in CI and on any laptop, before
// a single test runs.
//
// The second is the check in this file, and it is the weak half, said so
// plainly: it reads the two source files and asserts each names the other, so
// the pair cannot be quietly separated in the prose either. It is a text check
// and it has the limit every text check has: it sees that the sentence is
// written, not that the tests still do what the sentence claims. What it
// defends is deletion and separation, which is the failure mode that actually
// happened to other red arms in this tree.
var (
	_ = TestCollection_UpsertAndDeleteAreAtomicAcrossTheWindow
	_ = TestCollection_NoReaderCanSeeTheStoreAheadOfTheIndex
)

func TestCollection_TheTwoWindowDefendersStillNameEachOther(t *testing.T) {
	pares := []struct{ fichero, debeNombrar string }{
		{"collection_window_test.go", "collection_concurrency_test.go"},
		{"collection_concurrency_test.go", "collection_window_test.go"},
	}
	for _, p := range pares {
		b, err := os.ReadFile(p.fichero)
		if err != nil {
			t.Fatalf("%s: %v", p.fichero, err)
		}
		if !strings.Contains(string(b), p.debeNombrar) {
			t.Errorf("%s no nombra a %s: los dos fijan extremos distintos de la misma ventana "+
				"y el que los separe tiene que leer por que", p.fichero, p.debeNombrar)
		}
	}
}
