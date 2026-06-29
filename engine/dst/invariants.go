package dst

import (
	"fmt"

	"naylamp/engine/naylamp"
)

// checkInvariants verifies the engine agrees with the oracle. These are the
// properties that must ALWAYS hold, no matter what random sequence of
// operations ran. A violation means a real bug in the engine.
func checkInvariants(col *naylamp.Collection, orc *oracle) error {
	// Invariant 1: the counts match. The engine must hold exactly as many
	// vectors as the oracle expects.
	if col.Len() != orc.count() {
		return fmt.Errorf("count mismatch: engine has %d, oracle expects %d", col.Len(), orc.count())
	}

	// Invariant 2: every id the oracle expects must be findable. We query with
	// each expected vector's own data and confirm its id comes back as the
	// closest match (a vector is always nearest to itself).
	for _, id := range orc.ids() {
		data := orc.vectors[id]

		results, err := col.Query(data, 1)
		if err != nil {
			return fmt.Errorf("query for id %d failed: %w", id, err)
		}
		if len(results) == 0 {
			return fmt.Errorf("id %d expected to exist but query returned nothing", id)
		}
		if results[0].ID != id {
			return fmt.Errorf("id %d expected as closest match, got id %d", id, results[0].ID)
		}
	}

	return nil
}
