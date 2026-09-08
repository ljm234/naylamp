#!/bin/sh
# cert-margen.sh: how much life the gate demands of its TLS material, written
# ONCE because the number has to be the same in three scripts that deliberately
# share nothing else.
#
# WHY IT IS A FILE AND NOT A LITERAL, and the reason is a trap that was already
# sprung. `gate/build.sh` re-mints only when the material fails this margin, and
# `gate/p2-preflight.sh` refuses to start when it fails the same margin. If the
# two numbers ever differ, there is a DEAD ZONE between them: a window in which
# the preflight says no and the documented remedy, running build.sh, keeps the
# certificates exactly as they were. Measured on 2026-09-08 with both at 7200:
# build.sh was run against material with 10 h 47 min left and kept it.
#
# AND THAT RUN DOES NOT DEMONSTRATE THE DEADLOCK, which a reader caught. The dead
# zone is the stretch BETWEEN the two figures: material with more than two hours
# and less than six left is refused by one and kept by the other. Ten hours and
# forty-seven minutes is past both, so that run is the ordinary case. The dead
# zone is real by arithmetic; that measurement is not what makes it real.
#
# WHY IT IS NOT IN gate/common.sh, which is where gate-wide constants live.
# common.sh calls `require_env NAYLAMP_GATE_HOSTS` and two more at source time
# and EXITS 2 when they are unset, because it carries the identity of the iron
# fleet. `build.sh` and `p2-preflight.sh` have to run with no fleet at all, so
# sourcing it there would turn a local build into an exit 2. This file carries
# the number and nothing else: no side effects, no environment required, so the
# three can source it and the bootstrap script is not made to depend on the
# fleet.
#
# THE NUMBER, and what it buys. gencerts issues material valid for 24 hours
# forward (engine/cluster/tlstest/tlstest.go:55 and :90 mint with -1h and +24h;
# the extra hour is in the PAST, for clock skew, so the usable window is 24 and
# not the 25 the notBefore..notAfter span suggests). Six hours of margin means
# the preflight refuses to open a session that could run out of certificate
# halfway, and build.sh re-mints in exactly the same window rather than handing
# back the same expiring set.
#
# Raising it costs nothing but re-minting more often. Lowering it below the
# length of an iron session is what must not happen: a gate run takes hours.
CERT_MARGEN_SEG=21600
