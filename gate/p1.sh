#!/usr/bin/env bash
# p1.sh: the iron gate for the central property of Phase 1.
#
# The property is stated outside this repository, in NAYLAMP_PHASE_1.md, and its
# three clauses are: (i) the index's live id set is exactly the ids upserted and
# not deleted, in both directions; (ii) every live id is reachable, meaning a
# query with its own vector returns it first; and (iii) a k-NN query returns
# min(k, live) live ids and the returned set agrees with brute force above a
# recall floor, at the point declared there.
#
# WHAT CARRIES THE PROPERTY IS THE TREE'S OWN TEST BINARIES, cross compiled to
# linux/arm64 and static, and not a program written for this gate. The assertions
# are the ones CI runs on every push, so the hardware corroborates the local
# defender instead of replacing it. That choice and its price are argued in
# NAYLAMP_PROPUESTA_GATE_PHASE1_2026-08-10.md, which is this script's design and
# lives in the workspace, never in this repository.
#
# What it costs, said here because it is the one thing the carrier gives up:
# CGO_ENABLED=0 means no -race on iron, measured. Concurrency is outside the
# property, so nothing claimed is lost, but on that axis the iron is WEAKER than
# CI and the artifact says so rather than letting a green read as more.
#
# No daemon, no cluster, no TLS. This gate runs the engine as a library: there is
# no network, no client, no naylampd and no quorum to form, so it needs neither
# gate/build.sh nor the certificates the other gates mint. It needs ssh and scp,
# and nothing else off this machine.
#
# NAYLAMP_P1_LOCAL=1 runs the REHEARSAL instead: the hosts must be loopback,
# three directories on this machine play the fleet, the binaries are native, and
# the run banners both streams and names its artifact p1-local-<run id>, so its
# output can never read as gate evidence. Its job is to debug this script before
# the script costs VM time; the iron run is what seals, and this is never it.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"

# NAYLAMP_GATE_PRIVATE IS REQUIRED AND UNUSED HERE, and that is worth one line
# rather than a workaround. common.sh demands it because the Phase 3 and Phase 4
# gates wire a cluster over the private addresses; this gate never opens a socket.
# Sourcing common.sh anyway is the right trade: the host table, the ssh options
# and the two transfer helpers are shared, and duplicating them here would drift
# the day one of them changes.

# ---- the working directory on each host, and the deletion rule ---------------
#
# One directory per run, named from the run id, and nothing this gate writes ever
# lands anywhere else. The removal in P1.hygiene is written against a literal
# prefix with the run id appended inline, never against a bare variable, because
# that pattern admits a day when the variable arrives empty and the deletion
# lands on the home directory. RUN_ID is validated the moment it is built.
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
case "${RUN_ID}" in
	[0-9]*Z-[0-9]*) ;;
	*) echo "gate: refusing to run: the run id ${RUN_ID} is not the shape this script deletes by" >&2; exit 2 ;;
esac
REMOTE_DIR="naylamp-p1-${RUN_ID}"

OUT_LOCAL="${OUT_DIR}/p1-${RUN_ID}"
# The red arm's copies live OUTSIDE the repository, under the system temp
# directory, and the run id keeps two runs from colliding.
MUT_ROOT="${TMPDIR:-/tmp}/naylamp-p1-mut-${RUN_ID}"
DST_BIN="${OUT_DIR}/p1-dst.test"
HNSW_BIN="${OUT_DIR}/p1-hnsw.test"
# The native pair exists only so P1.pre can ask -test.list a question the
# cross compiled pair cannot answer on this machine. Same source, same phase.
DST_NATIVE="${OUT_DIR}/p1-dst.native.test"
HNSW_NATIVE="${OUT_DIR}/p1-hnsw.native.test"

# ---- the localhost rehearsal, NAYLAMP_P1_LOCAL=1 -------------------------------
#
# THE REHEARSAL IS NOT THE GATE, and it is built so its output can never read as
# the gate's evidence, the same question the red arm of common.sh answers for a
# stub ssh. Three layers, and none of them asks anyone to remember anything:
#
#   1. The artifact's hosts line can never name the fleet: local mode refuses to
#      run unless all three addresses are loopback.
#   2. A banner on BOTH streams says what the run is, because stdout is the
#      artifact stream and stderr is the console.
#   3. The artifact directory names itself: p1-local-<run id>, never p1-<run id>.
#
# And a fourth by construction: the transport below never execs an ssh, so the
# real fleet cannot be touched by this run at all.
#
# What plays the host is three per-node directories under gate/out, each used as
# HOME for its node, so the three-host structure (the upload, the sha256
# comparison, the per-node outputs, hygiene's probes) runs the same code path as
# iron. The binaries are the NATIVE build, because the cross pair cannot exec on
# this machine. And the tree may be dirty: the rehearsal exists to debug the
# script BEFORE it costs VM time, uncommitted work included, so P1.provenance
# notes the dirty tree instead of failing it. The banner is what keeps that
# relaxation from ever reading as a seal.
if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
	for _n in "${NODE_IDS[@]}"; do
		case "${HOSTS[$_n]}" in
			127.0.0.1|localhost|::1) ;;
			*) echo "gate: NAYLAMP_P1_LOCAL=1 refuses to run with a non-loopback address (node ${_n} is ${HOSTS[$_n]}): a rehearsal's hosts line can never name the fleet" >&2; exit 2 ;;
		esac
	done
	local_paths() {
		LOCAL_FLEET="${OUT_DIR}/p1-local-fleet-${RUN_ID}"
		OUT_LOCAL="${OUT_DIR}/p1-local-${RUN_ID}"
	}
	local_paths
	rehearsal_setup() {
		mkdir -p "${LOCAL_FLEET}/bin"
		local _n
		for _n in "${NODE_IDS[@]}"; do mkdir -p "${LOCAL_FLEET}/${_n}"; done
		if [ ! -x "${LOCAL_FLEET}/bin/sha256sum" ]; then
			cat > "${LOCAL_FLEET}/bin/sha256sum" <<'SHIM'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
SHIM
			chmod +x "${LOCAL_FLEET}/bin/sha256sum"
		fi
	}
	# The transport. Each node's HOME is its directory, so "~" lands inside the
	# fleet; the shim dir rides on PATH because sha256sum does not exist here.
	run_on() {
		local n="$1"
		shift
		( export HOME="${LOCAL_FLEET}/${n}"; cd "${LOCAL_FLEET}/${n}" && PATH="${LOCAL_FLEET}/bin:${PATH}" bash -c "$*" )
	}
	copy_to() {
		local n="$1" src="$2" dst="$3"
		cp "${src}" "${LOCAL_FLEET}/${n}/${dst}"
	}
	echo "gate: REHEARSAL RUN (NAYLAMP_P1_LOCAL=1): the hosts are directories on this machine and the binaries are native; nothing this run prints is gate evidence" >&2
	echo "gate: REHEARSAL RUN (NAYLAMP_P1_LOCAL=1): the hosts are directories on this machine and the binaries are native; nothing this run prints is gate evidence"
	echo "gate: rehearsal note, written BEFORE any figure and not after: this machine has 64 GB and 10 cores, and the fleet is Standard_B2pls_v2, 2 vCPU and 4 GiB, burstable. No wall-clock or memory figure of this run predicts the iron session, and the campaign's 226.3 MB of process, invisible here, is within budget there. Do not size the iron session from this artifact" >&2
	echo "gate: rehearsal note, written BEFORE any figure and not after: this machine has 64 GB and 10 cores, and the fleet is Standard_B2pls_v2, 2 vCPU and 4 GiB, burstable. No wall-clock or memory figure of this run predicts the iron session, and the campaign's 226.3 MB of process, invisible here, is within budget there. Do not size the iron session from this artifact"
fi

# ---- budgets, and every one of them is a CEILING and not an estimate ---------
#
# A loose test binary runs with its timeout DISABLED, so this gate writes every
# one of them explicitly. A row that dies on the clock is not a red of its
# clause, and TIMEOUT is a distinct outcome of the red arm for that reason.
#
# THE NUMBERS ARE CHOSEN MARGINS AND THE ARITHMETIC IS WRITTEN OUT, because a
# budget that only shows its result cannot be argued with. All three start from a
# laptop measurement scaled by the 3 to 5 the proposal fixes for these VMs, which
# is a house rule and not a measurement, and then take a margin over the top of
# that range. The full-length probe this gate demands before a sealing run is
# what replaces the rule with a measurement.
#
#   sweep    328.3s on the laptop, archived on a43070b. Times 5 is 1642s.
#            3600s is 2.19 times that. See the NOTE ON THE SWEEP FIGURE below.
#   recall   the three points together, of which only the 50k one carries a
#            figure: 162.603s on a quiet laptop. Times 5 is 813s, and the other
#            two are cheap. 1800s is 2.21 times that.
#   point    598.41s, the worst of five campaign runs. Times 5 is 2992s, which
#            is the 50 min the proposal budgets per VM. 5400s is 1.81 times that.
#
# THE MARGINS ARE WIDE ON PURPOSE AND THE REASON IS THE SKU. B2pls_v2 is a burst
# VM: a sweep that saturates a core for half an hour exhausts its credits and
# drops to baseline, and the three hosts do not hold the same balance. Time enters
# no verdict here, so a slow host costs wall clock and not a red.
SWEEP_TIMEOUT=3600s
RECALL_TIMEOUT=1800s
POINT_TIMEOUT=5400s

# Note on the sweep figure, and it is a defect of the design document that this
# script found by having to pick a number. The 328.3s above is archived on
# a43070b, and the same document carries a LATER measurement of the same work,
# 186.87s to 188.08s with D1 in and 183.96s without, on 0e7066f. The two do not
# share tree or toolchain, so neither supersedes the other by arithmetic, and the
# ceiling is taken from the SLOWER of the two on purpose. It is noted in the
# artifact so that nobody derives a per-VM estimate from a figure this gate is
# only using as a ceiling.

# Which host carries the red arm, and it is named because the design says it must
# be and does not say which. Node 1 by default; the artifact records whichever
# ran. The red arm attests ONE host, not three, and that is an exclusion.
RED_NODE="${NAYLAMP_P1_RED_NODE:-1}"
case " ${NODE_IDS[*]} " in
	*" ${RED_NODE} "*) ;;
	*) echo "gate: NAYLAMP_P1_RED_NODE=${RED_NODE} is not one of the node ids ${NODE_IDS[*]}" >&2; exit 2 ;;
esac

# ---- the anchored test selectors --------------------------------------------
#
# ANCHORED, and for two reasons and not one. The cost: unanchored, Recall matches
# four tests and Scale matches five, among them cases that run for hours. And the
# hygiene: this gate's whole claim that nothing writes a file on the hosts rests
# on the three file-writing tests staying out of the selection, and they only
# stay out while these are anchored. P1.pre proves each of them selects exactly
# one test before any of them runs.
RUN_SWEEP='^TestDST_ManySeeds$'
RUN_POINT='^TestPoint_TheThreeClausesTogetherByTheAPI$'
RUN_R500='^TestHNSW_RecallVsBruteForce$'
RUN_R5K='^TestHNSW_RecallAtScale$'
RUN_R50K='^TestHNSW_RecallLargeScale$'

# ---- the variables this gate refuses ----------------------------------------
#
# NAYLAMP_DST_SEEDS REPLACES THE COMPILED BUDGET OUTRIGHT and nothing in the tree
# catches it: TestDST_ManySeeds accepts any integer above zero, so
# NAYLAMP_DST_SEEDS=1 runs one seed and passes. Refusing it in the shell is the
# ONLY defense, which is why it carries a negative arm of its own in P1.pre.
#
# It is refused on the host as well, and that is not belt and braces. GOFLAGS
# cannot reach an already compiled binary, but this variable travels through the
# environment exactly the same on the far side of an ssh, and a login profile on
# a host is a place nobody looks.
#
# GOFLAGS stays on the list for the local side, where the binaries are built.
REFUSED_VARS="NAYLAMP_DST_SEEDS NAYLAMP_CLUSTER_SEED NAYLAMP_CLUSTER_SEEDS GOFLAGS"

# ---- verdict registry, the shape omnibus.sh and servicehealth.sh use ---------
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0
RUN_STARTED=0
HOSTS_REACHABLE=0
UPLOADED=0

pass() { echo "gate: PASS $*"; }
note() { echo "gate: $*"; }
fail() { echo "gate: FAIL $*" >&2; CHECK_FAILED=1; }
stop() { echo "gate: STOP $*" >&2; exit 1; }

record_verdict() { VERDICTS="${VERDICTS}$1=$2 "; }
# PRECEDENCE IS fail, THEN none, THEN pass, and the middle one is not the shape
# the other gates use. They have no way to record "did not run"; this one does,
# because the seeded sweep aborts on the first violation and leaves its two
# siblings unrun. An unrun check that a later line marks pass has to keep saying
# unrun, so none wins over pass here and nowhere else.
verdict_of() {
	case "${VERDICTS}" in
		*" $1=fail "*) printf fail ;;
		*" $1=none "*) printf none ;;
		*" $1=pass "*) printf pass ;;
		*) printf none ;;
	esac
}
begin_check() { CHECK_FAILED=0; }
end_check() {
	if [ "${CHECK_FAILED}" -eq 0 ]; then
		record_verdict "$1" pass
	else
		record_verdict "$1" fail
	fi
}

emit_final_verdict() {
	[ -z "${EXPECTED}" ] && return 0
	local id v bad=""
	for id in ${EXPECTED}; do
		v="$(verdict_of "${id}")"
		printf 'gate: verdict %s = %s\n' "${id}" "${v}" >&2
		if [ "${v}" != pass ]; then
			bad="${bad} ${id}(${v})"
		fi
	done
	if [ "${COMPLETED}" -eq 1 ] && [ -z "${bad}" ]; then
		echo "gate: all checks passed (${EXPECTED})"
		return 0
	fi
	if [ -n "${bad}" ]; then
		echo "gate: NOT A SUCCESS; checks without a passing verdict:${bad}" >&2
	else
		echo "gate: NOT A SUCCESS; the run did not reach a clean completion" >&2
	fi
	return 1
}

# A CHECK THAT DID NOT RUN IS NOT GREEN, and this gate has a case the others do
# not: the campaign aborts on four t.Fatalf that belong to no clause, so its five
# verdicts can end up unrun while the process merely exits non zero. not_run
# records them as such instead of as failures, so the artifact says which of the
# two happened.
not_run() {
	local id
	for id in "$@"; do
		record_verdict "${id}" none
		echo "gate: NOT RUN ${id}" >&2
	done
}

cleanup() {
	local rc=$?
	set +e
	if [ "${HOSTS_REACHABLE}" -eq 1 ] && [ "${UPLOADED}" -eq 1 ]; then
		echo "gate: the run is ending with material still on the hosts; P1.hygiene is what removes it and it did not complete" >&2
		# The printed command carries the prefix LITERAL and the run id appended,
		# never a bare variable, for the same reason the real removal does: this
		# line is meant to be pasted, and a pasted rm whose variable arrives empty
		# lands on the home directory.
		echo "gate: remove it by hand with: for h in \$(echo \${NAYLAMP_GATE_HOSTS} | tr , ' '); do ssh -i \${NAYLAMP_GATE_KEY} \${NAYLAMP_GATE_USER:-ubuntu}@\$h 'rm -rf ~/naylamp-p1-${RUN_ID}'; done" >&2
		echo "gate: and on this machine: rm -rf ${TMPDIR:-/tmp}/naylamp-p1-mut-${RUN_ID}" >&2
		if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
			echo "gate: and the rehearsal fleet: rm -rf ${OUT_DIR}/p1-local-fleet-${RUN_ID}" >&2
		fi
	elif [ "${RUN_STARTED}" -eq 1 ] && [ "${HOSTS_REACHABLE}" -eq 0 ]; then
		echo "gate: no host was ever confirmed reachable, so nothing was uploaded and there is nothing to remove" >&2
	fi
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# ---- host helpers ------------------------------------------------------------

require_hosts_reachable() {
	local n rc=0 unreachable=""
	for n in "${NODE_IDS[@]}"; do
		if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
			run_on "$n" true >/dev/null 2>&1 && rc=0 || rc=$?
		else
			ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_OPTS[@]}" \
				"${NAYLAMP_GATE_USER}@${HOSTS[$n]}" true >/dev/null 2>&1 && rc=0 || rc=$?
		fi
		if [ "${rc}" -eq 0 ]; then
			note "reach: node ${n} (${HOSTS[$n]}) answers"
		else
			unreachable="${unreachable} ${n}(${HOSTS[$n]})"
		fi
	done
	if [ -n "${unreachable}" ]; then
		stop "unreachable host(s):${unreachable}. Check the instances are started and that NAYLAMP_GATE_HOSTS holds their CURRENT public addresses, which change across a deallocate and start."
	fi
	HOSTS_REACHABLE=1
	note "reach: all three hosts answer"
}

# run_test <node> <remote binary name> <selector> <timeout> <extra args...>
#
# Both streams are captured, and that is not tidiness. PASS goes to stdout while
# "testing: warning: no tests to run" and "panic: test timed out" go to stderr,
# so an artifact built from stdout alone makes the two silent failure modes
# invisible. The remote side refuses the sweep variables before it execs
# anything, which is the second half of the defense P1.pre proves locally.
run_test() {
	local n="$1" bin="$2" sel="$3" tmo="$4"
	shift 4
	run_on "$n" "cd ~/${REMOTE_DIR} && pwd -P && for v in ${REFUSED_VARS}; do
		if [ -n \"\${!v:-}\" ]; then echo \"host: \$v is set on this host and can decide the size of the sweep\" >&2; exit 3; fi
	done && ./${bin} -test.run '${sel}' -test.v -test.timeout ${tmo} $*" 2>&1
}

# refused_on_host <file>: true when the far side refused because one of the sweep
# variables is set in that host's own environment. It is this gate's own guard
# firing, not a red of any clause, and reading it as one would put a false red in
# a sealing artifact. The first version recognised it in one of the four places
# that call run_test.
refused_on_host() {
	grep -q 'is set on this host and can decide the size of the sweep' "$1"
}

# ---- the failure patterns, defined ONCE and read by both paths --------------
#
# THE GATE'S OWN DETECTOR AND THE RED ARM'S EXPECTATION READ THE SAME TABLE, and
# that is the whole reason this function exists rather than the patterns sitting
# where each is used. On 25 August 2026 they were two: the detector in the
# campaign phase anchored its alternatives directly behind the label and could
# not match a single shape failure, while row 5 of the red arm used a different
# expression that could. Two regexes in one file, one output, opposite verdicts.
#
# AND THE REASON IT WAS INVISIBLE IS THE ONE WORTH WRITING DOWN: the red arm was
# scoring with a pattern the gate did not use, so it went green over a detector
# that was broken. A red arm that does not exercise EXACTLY the path it defends
# proves nothing about that path, and when it shares the fault it confirms it.
# Unifying is what makes the arm exercise the same object as the gate.
#
# UNIFYING ALONE WOULD NOT BE ENOUGH, so P1.pre carries a control that runs this
# table against real failure lines taken from measured mutant output. Without it
# a wrong entry here would be wrong in both paths at once and the arm would go
# green again, which is the same defect one level up.
failure_re() {
	case "$1" in
		P1.exact|P1.point.exact)   printf 'index set mismatch' ;;
		P1.ledger|P1.point.ledger) printf 'count mismatch' ;;
		P1.reach|P1.point.reach)   printf '(expected as closest match|expected to exist but query returned nothing|query for id [0-9]+ failed)' ;;
		P1.point.shape)            printf '(returned [0-9]+ ids, want|id [0-9]+ returned more than once|id [0-9]+ was returned but is not live|queries failed the shape check|degenerate query at k=[0-9]+ (failed|over))' ;;
		P1.point.floor)            printf 'recall@[0-9]+ = [0-9.]+ at [0-9]+ live, want' ;;
		P1.point.query)            printf 'query [0-9]+ failed' ;;
		# A name with no entry must never quietly match nothing, because that is
		# a silent green. It gets a pattern that cannot occur, and the control in
		# P1.pre is what turns that into a loud failure.
		*)                         printf '__no_pattern_for_this_verdict__' ;;
	esac
}

# ---- output guards -----------------------------------------------------------
#
# Three different things, and the design document treats them as one rule, which
# is a defect this script found by having to implement them.
#
# Counting the sweep. The budget line is a t.Logf, and a loose binary keeps a
# passing test's t.Logf output to itself, so -test.v is not optional. The gate
# demands the line and demands the number in it match what the source declares.
#
# Counting the recall. A -test.run that matches nothing exits zero, so a test
# that never ran and a test that passed produce the same status. The gate demands
# the recall line exist and parse above the floor.
#
# AND THE FOUR RECALL LINES ARE FOUR DIFFERENT FORMATS, which the design calls
# one rule. They are, in the tree as it stands:
#   recall@%d over %d queries = %.3f
#   recall@%d at scale (n=%d, dim=%d, %d queries) = %.3f
#   recall@%d at LARGE scale (n=%d, dim=%d, %d queries) = %.3f
#   P1.point.floor: recall@%d = %.4f over %d queries at %d live, floor %.2f
# recall_value below takes the LAST number on the matched line for the first
# three and the number after the equals for the fourth, rather than pretending
# one pattern covers all four.

sweep_seeds_in_output() {
	sed -n 's/.*all \([0-9][0-9]*\) seeds passed .*/\1/p' "$1" | tail -1
}

recall_value() {
	# $1 file, $2 the anchor that identifies the line
	case "$2" in
		P1.point.floor)
			sed -n 's/.*P1\.point\.floor: recall@[0-9]* = \([0-9.][0-9.]*\) over .*/\1/p' "$1" 2>/dev/null | tail -1
			;;
		*)
			# THE || true IS LOAD BEARING. Without it grep exits 1 when the anchor
			# is absent, pipefail carries that out of the function, and the caller
			# assigns it inside an if BODY where errexit is still armed, so the
			# gate DIES on the one case the guard exists to report: a recall line
			# that never printed.
			{ grep -F "$2" "$1" 2>/dev/null || true; } | sed -n 's/.*= \([0-9.][0-9.]*\)[[:space:]]*$/\1/p' | tail -1
			;;
	esac
}

above_floor() {
	# $1 value, $2 floor. Returns 0 when the value parses and clears the floor.
	[ -n "$1" ] || return 1
	awk -v v="$1" -v f="$2" 'BEGIN { exit !(v + 0 >= f + 0) }'
}

# ---- source anchors ----------------------------------------------------------
#
# The declared budget is read out of the source, never restated here, so the two
# cannot drift. The sweep is anchored BY FUNCTION, which is the rule this house
# fixed after line anchors rotted twice.
#
# The campaign's constants cannot be, and that is a small mismatch with the
# design, which says "anchoring by function" for both. They are package level
# consts in engine/dst/point_test.go, outside any function, so they are anchored
# by NAME inside a bounded const block instead. Written down rather than glossed.
declared_seeds() {
	awk '/^func /{f=0} /^func TestDST_ManySeeds\(/{f=1} f && /^[[:space:]]*numSeeds := [0-9]+$/{print $3; exit}' \
		"${REPO_DIR}/engine/dst/dst_test.go" 2>/dev/null || true
}

declared_const() {
	awk -v want="$1" '$1 == want && $2 == "=" { gsub(/[^0-9.]/, "", $3); print $3; exit }' \
		"${REPO_DIR}/engine/dst/point_test.go" 2>/dev/null || true
}

# ---- P1.pre ------------------------------------------------------------------

phase_pre() {
	note "P1.pre: the door. Nothing here touches a host."
	begin_check

	local var
	for var in ${REFUSED_VARS}; do
		if [ -n "${!var:-}" ]; then
			stop "P1.pre: ${var} is exported as ${!var} and it can decide the size of what this gate seals. Unset it and re-run."
		fi
	done
	pass "P1.pre: none of the sweep variables is set locally (${REFUSED_VARS})"

	local seeds
	seeds="$(declared_seeds)"
	if [ -n "${seeds}" ]; then
		note "P1.pre: the declared budget is ${seeds} seeds, read from the numSeeds assignment inside func TestDST_ManySeeds"
	else
		fail "P1.pre: the seed budget could not be read out of func TestDST_ManySeeds, so this run cannot state the size of the sweep it seals"
	fi

	local built live pdim pk pq
	built="$(declared_const pointBuilt)"; live="$(declared_const pointLive)"
	pdim="$(declared_const pointDim)"; pk="$(declared_const pointK)"; pq="$(declared_const pointQueries)"
	if [ -n "${built}" ] && [ -n "${live}" ] && [ -n "${pdim}" ] && [ -n "${pk}" ] && [ -n "${pq}" ]; then
		note "P1.pre: the campaign builds ${built}, keeps ${live} live, at dim=${pdim} k=${pk} over ${pq} queries, read from the const block of engine/dst/point_test.go"
	else
		fail "P1.pre: the campaign constants could not be read out of engine/dst/point_test.go, so this run cannot state the size of the point it seals"
	fi

	# -test.list over each selector, on the LOCAL binaries, before anything is
	# uploaded. Each must select exactly one.
	local sel bin n
	for sel in "${RUN_SWEEP}:${DST_NATIVE}" "${RUN_POINT}:${DST_NATIVE}" \
		"${RUN_R500}:${HNSW_NATIVE}" "${RUN_R5K}:${HNSW_NATIVE}" "${RUN_R50K}:${HNSW_NATIVE}"; do
		bin="${sel##*:}"
		sel="${sel%:*}"
		n="$(list_local "${bin}" "${sel}")"
		if [ "${n}" = 1 ]; then
			pass "P1.pre: ${sel} selects exactly one test"
		else
			fail "P1.pre: ${sel} selects ${n} tests and must select exactly one"
		fi
	done

	# ---- control of the instrument, before anything is asked of it -----------
	#
	# A COUNT OF ZERO IS AMBIGUOUS AND THAT AMBIGUITY WAS A REAL DEFECT. The five
	# checks below read a count out of list_local, and negative arm 2 expects that
	# count to be zero. When the binary could not execute at all, every call
	# returned zero: the five checks failed and the arm PASSED, so the arm written
	# to prove the check is not vacuous was certifying a dead instrument. The arm
	# cannot catch that on its own, because it runs the same function through the
	# same path and shares its fault by construction.
	#
	# What separates the two is a demand for a NONZERO answer through that same
	# path. A selector matching everything must select many; a dead binary returns
	# zero here as well, and then this line names the instrument instead of
	# leaving five selector failures and one green arm to be read the wrong way.
	local alive
	alive="$(list_local "${DST_NATIVE}" '.')"
	if [ "${alive}" -gt 1 ]; then
		pass "P1.pre: the listing instrument is alive, a selector matching everything picks ${alive} tests"
	else
		fail "P1.pre: the listing instrument returned ${alive} for a selector that matches everything, so it is DEAD and every count below is meaningless, including the zero that negative arm 2 expects"
	fi

	# ---- control of the failure table, against lines that really occurred ----
	#
	# UNIFYING THE PATTERNS CLOSES ONE HOLE AND OPENS A SMALLER ONE, so this is
	# what closes that. With the gate and the red arm reading one table, a wrong
	# entry is wrong in BOTH at once and the arm goes green over it again, which is
	# the same defect one level up. The fixture below is real output: the first
	# three came from mutants run on 168a4b9 on 25 August 2026, the rest are the
	# forms point_test.go emits, and the last three are GREEN lines that must NOT
	# match. The floor pair is the one that matters, since its passing line and its
	# failing line differ only in "over ... floor" against "at ... want".
	#
	# THE file:line PREFIX IS DELIBERATELY ABSENT FROM THESE LINES. The patterns
	# never look at it, so carrying it would pin this control to line numbers that
	# rot the next time anyone edits the test, which is the anchoring this house
	# gave up after line anchors rotted twice. What the fixture holds is what the
	# patterns actually see: the label and the message.
	local line lbl want got bad=0
	while IFS='|' read -r lbl want line; do
		[ -z "${lbl}" ] && continue
		if printf '%s\n' "${line}" | grep -qE "$(failure_re "${lbl}")"; then got=match; else got=no; fi
		if [ "${got}" != "${want}" ]; then
			fail "P1.pre: the failure table is wrong for ${lbl}: expected ${want} and got ${got} on: ${line}"
			bad=1
		fi
	done <<'FIXTURE'
P1.reach|match|    seed 4 failed: step 600: id 67 expected as closest match, got id 36
P1.ledger|match|    seed 1 failed: step 200: count mismatch: engine has 74, oracle expects 55
P1.exact|match|    seed 1 failed: step 200: index set mismatch: the index holds 19 ids the oracle does not expect ([3 15] plus 9 more), the oracle expects 0 ids the index does not hold ([])
P1.point.shape|match|    P1.point.shape: degenerate query at k=1000 over 999 live: returned 1000 ids, want min(k, live) = 999
P1.point.shape|match|    P1.point.shape: query 3 at k=10 over 50000 live: id 7 returned more than once
P1.point.shape|match|    P1.point.shape: query 3 at k=10 over 50000 live: id 7 was returned but is not live
P1.point.shape|match|    P1.point.shape: 12 queries failed the shape check, 5 of them printed above
P1.point.shape|match|    P1.point.shape: degenerate query at k=50001 failed: vector: bad dimension
P1.point.floor|match|    P1.point.floor: recall@10 = 0.4700 at 50000 live, want >= 0.95
P1.point.exact|match|    P1.point.exact: index set mismatch: the index holds 3 ids the oracle does not expect ([1 2 3]), the oracle expects 0 ids the index does not hold ([])
P1.point.ledger|match|    P1.point.ledger: count mismatch: engine has 74, oracle expects 55
P1.point.reach|match|    P1.point.reach: id 5 expected to exist but query returned nothing
P1.point.reach|match|    P1.point.reach: query for id 5 failed: vector: bad dimension
P1.point.query|match|    P1.point.query: query 3 failed: vector: bad dimension
P1.point.floor|no|    P1.point.floor: recall@10 = 0.9900 over 50 queries at 50000 live, floor 0.95
P1.point.shape|no|    P1.point.shape: 50/50 queries returned min(k, live) distinct live ids at k=10, 0.62s with the brute force inside
P1.point.reach|no|    P1.point.reach: swept 50000 live ids, 20.95s
P1.nosuchverdict|no|    anything at all
FIXTURE
	if [ "${bad}" -eq 0 ]; then
		pass "P1.pre: the failure table matches every real failure line of the fixture and none of its green lines"
	fi

	# ---- negative arm 1: the refusal bites ----------------------------------
	# A guard that is never seen to fire is a guard nobody has tested. This runs
	# the same refusal in a subshell with the variable set and demands it stop.
	if ( NAYLAMP_DST_SEEDS=1 bash -c '
		for v in '"${REFUSED_VARS}"'; do
			if [ -n "${!v:-}" ]; then exit 1; fi
		done
		exit 0' ) ; then
		fail "P1.pre: NEGATIVE ARM 1 SURVIVED. With NAYLAMP_DST_SEEDS set, the refusal did not fire, so the only defense this budget has does not work"
	else
		pass "P1.pre: negative arm 1 bites, the refusal fires when NAYLAMP_DST_SEEDS is set"
	fi

	# ---- negative arm 2: -test.list bites -----------------------------------
	# A selector that matches nothing must select nothing. Without this, the
	# check above could be passing because -test.list always prints something.
	n="$(list_local "${DST_NATIVE}" '^TestThisNameDoesNotExistInThisTree$')"
	if [ "${n}" != 0 ]; then
		fail "P1.pre: NEGATIVE ARM 2 SURVIVED. A selector matching no test reported ${n}, so the -test.list check above proves nothing"
	elif [ "${alive}" -gt 1 ]; then
		pass "P1.pre: negative arm 2 bites, a selector that matches nothing selects nothing while one that matches everything selects ${alive}"
	else
		# THE ARM REFUSES TO CLAIM ANYTHING WHEN THE INSTRUMENT IS DEAD, and this
		# is the half that the control above cannot supply on its own. This arm
		# runs the same function through the same path as the checks it certifies,
		# so it shares their faults by construction and cannot detect them. What it
		# CAN do is decline to speak: with a dead instrument its zero means nothing
		# and saying PASS would be the arm confirming the very breakage it exists
		# to rule out. Measured on 25 August 2026, that is exactly what it did.
		fail "P1.pre: negative arm 2 is NOT ATTESTING anything. Its zero is indistinguishable from the zero a dead instrument returns, and the control above says the instrument is dead"
	fi

	end_check P1.pre
	[ "$(verdict_of P1.pre)" = pass ] || stop "P1.pre failed; it gates the whole run and nothing was uploaded"
}

# list_local <binary> <selector>: how many tests that selector picks.
#
# THE BINARY HAS TO BE A NATIVE ONE AND THAT COST A REAL DEFECT. The first
# version of this gate listed against the linux/arm64 binaries it had just cross
# compiled, on a darwin control machine that cannot exec an ELF. The exec failed,
# 2>/dev/null ate the message, grep -c printed 0 and the || true erased the
# status, so every selector reported zero, all five checks failed and P1.pre
# could never open. Worse, negative arm 2 passed through the same fault, so the
# arm that exists to prove the check is not vacuous was itself certifying a
# broken one. Both binaries are therefore built twice, native for the listing and
# cross for the hosts, out of the same source in the same phase.
list_local() {
	local n
	n="$("$1" -test.list "$2" 2>/dev/null | grep -cE '^Test')" || n=0
	printf '%s' "${n}"
}

# list_remote <node> <remote binary> <selector>: the same question asked of the
# binary that is actually going to run. P1.pre asks it of the native build, which
# shares the source and not the bytes; this asks it of the uploaded one, so the
# claim that the selectors are anchored covers the object the gate runs and not
# only its sibling.
list_remote() {
	local n
	n="$(run_on "$1" "cd ~/${REMOTE_DIR} && ./$2 -test.list '$3' 2>/dev/null | grep -cE '^Test'" 2>/dev/null)" || n=0
	printf '%s' "${n}"
}

# ---- P1.provenance -----------------------------------------------------------

phase_provenance() {
	note "P1.provenance: the tree this run is anchored to, and the fleet it ran on"
	begin_check

	# DEFER-041 asks every directed gate to print its own anchor and clock rather
	# than leave it to whoever archives the artifact. This is that line.
	local sha dirty
	sha="$(cd "${REPO_DIR}" && git rev-parse HEAD)"
	dirty="$(cd "${REPO_DIR}" && git status --porcelain | wc -l | tr -d ' ')"
	note "P1.provenance: HEAD ${sha}"
	note "P1.provenance: working tree entries not committed: ${dirty}"
	note "P1.provenance: run id ${RUN_ID}, started $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	if [ "${dirty}" != 0 ]; then
		if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
			note "P1.provenance: the working tree carries ${dirty} uncommitted entries, and the rehearsal runs it ON PURPOSE: its job is to debug the script before it costs VM time, uncommitted work included. The banner is what keeps this from ever reading as a seal"
		else
			fail "P1.provenance: the working tree carries ${dirty} uncommitted entries, so the binaries this run uploads do not correspond to any commit"
		fi
	else
		pass "P1.provenance: the tree is clean at ${sha}"
	fi

	# THE HOST KEY ALARM IS GONE ON THIS MACHINE and the artifact says so rather
	# than letting the fleet anchor read as more than it is. ~/.ssh/known_hosts
	# held the July host keys; it no longer exists, and SSH_OPTS uses
	# StrictHostKeyChecking=accept-new, which accepts an unknown key and only
	# rejects a CHANGED one. With no stored keys, "the address answers but the
	# machine behind it is not the same" cannot fire. What remains is that the
	# private key authenticates, which proves the host carries its public half
	# and is weaker than a matching host key.
	if [ -s "${HOME}/.ssh/known_hosts" ]; then
		note "P1.provenance: ~/.ssh/known_hosts exists, so a changed host key would be rejected"
	else
		note "P1.provenance: NO ~/.ssh/known_hosts on this machine, so a changed host key CANNOT be detected on this run. The fleet identity rests on key authentication alone, which is weaker. Declared, not worked around."
	fi

	local n d first="" same=1
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" "mkdir -p ~/${REMOTE_DIR}" || { fail "P1.provenance: could not create the working directory on node ${n}"; end_check P1.provenance; return; }
		copy_to "$n" "${DST_BIN}" "${REMOTE_DIR}/p1-dst.test" || { fail "P1.provenance: could not upload the dst binary to node ${n}"; end_check P1.provenance; return; }
		copy_to "$n" "${HNSW_BIN}" "${REMOTE_DIR}/p1-hnsw.test" || { fail "P1.provenance: could not upload the hnsw binary to node ${n}"; end_check P1.provenance; return; }
		run_on "$n" "chmod +x ~/${REMOTE_DIR}/p1-dst.test ~/${REMOTE_DIR}/p1-hnsw.test"
		UPLOADED=1
		d="$(run_on "$n" "cd ~/${REMOTE_DIR} && sha256sum p1-dst.test p1-hnsw.test | awk '{print \$1}' | tr '\n' ' '")"
		note "P1.provenance: node ${n} carries ${d}"
		if [ -z "${first}" ]; then first="${d}"; elif [ "${d}" != "${first}" ]; then same=0; fi
	done
	# And the selectors are asked again, of the binaries that are actually going to
	# run. P1.pre asked a native build that shares the source; this asks the
	# uploaded object, so the anchoring claim covers what the gate runs and not
	# only its sibling.
	local k
	for k in "${RUN_SWEEP}:p1-dst.test" "${RUN_POINT}:p1-dst.test" \
		"${RUN_R500}:p1-hnsw.test" "${RUN_R5K}:p1-hnsw.test" "${RUN_R50K}:p1-hnsw.test"; do
		d="$(list_remote "${RED_NODE}" "${k##*:}" "${k%:*}")"
		if [ "${d}" = 1 ]; then
			note "P1.provenance: ${k%:*} selects exactly one test on the uploaded binary too"
		else
			fail "P1.provenance: ${k%:*} selects ${d} tests on the uploaded binary, and P1.pre said one on the native build"
		fi
	done

	if [ "${same}" -eq 1 ]; then
		pass "P1.provenance: the three hosts carry byte identical binaries (${first})"
	else
		fail "P1.provenance: the three hosts do not carry the same binaries, so nothing below compares like with like"
	fi

	# What the three-host agreement can and cannot see, said before any verdict
	# uses it. Three hosts of one SKU running an identical static binary over a
	# seeded, single threaded workload return the same number BY CONSTRUCTION.
	# The agreement can fire on broken hardware or on a different binary, and the
	# second is what the sha256 above already covers. It is not evidence of
	# anything about provisioning.
	note "P1.provenance: the three-host agreement below can only fire on broken hardware or on a differing binary, and the sha256 covers the second. It is not an independence argument."

	end_check P1.provenance
	[ "$(verdict_of P1.provenance)" = pass ] || stop "P1.provenance failed; the run is not anchored"
}

# ---- the sweep: P1.exact, P1.ledger, P1.reach --------------------------------

phase_sweep() {
	note "P1.exact, P1.ledger, P1.reach: the seeded sweep at its declared budget, on all three hosts"
	begin_check
	local seeds n out ok_exact=1 ok_ledger=1 ok_reach=1 got agree=1 first=""
	seeds="$(declared_seeds)"

	for n in "${NODE_IDS[@]}"; do
		out="${OUT_LOCAL}/sweep-node${n}.txt"
		if run_test "$n" p1-dst.test "${RUN_SWEEP}" "${SWEEP_TIMEOUT}" > "${out}"; then
			got="$(sweep_seeds_in_output "${out}")"
			if [ -z "${got}" ]; then
				# The anti-vacuity guard. A green with no budget line is a green
				# that cannot say what it ran.
				fail "P1.exact/ledger/reach: node ${n} passed but printed no 'all N seeds passed' line, so the artifact cannot state what budget ran"
				ok_exact=0; ok_ledger=0; ok_reach=0
			elif [ "${got}" != "${seeds}" ]; then
				fail "P1.exact/ledger/reach: node ${n} ran ${got} seeds and the source declares ${seeds}"
				ok_exact=0; ok_ledger=0; ok_reach=0
			else
				note "P1.*: node ${n} swept ${got} seeds"
				[ -z "${first}" ] && first="${got}"
				[ "${got}" = "${first}" ] || agree=0
			fi
		else
			# Attribution by message, because the three checks share ONE
			# invocation and the harness does not label them. The fourth message
			# of the same loop is named too, rather than left to fall through.
			#
			# AND THE COROLLARY THAT MUST BE PRINTED: the sweep aborts with
			# t.Fatalf on the first seed that violates anything, so when one of
			# the three goes red the OTHER TWO ARE UNRUN over the budget. Unrun
			# is not green.
			if grep -qE "$(failure_re P1.exact)" "${out}"; then
				fail "P1.exact: node ${n} red, clause (i): $(grep -m1 -E "$(failure_re P1.exact)" "${out}")"
				ok_exact=0; ok_ledger=0; ok_reach=0; not_run P1.ledger P1.reach
			elif grep -qE "$(failure_re P1.ledger)" "${out}"; then
				fail "P1.ledger: node ${n} red, harness bookkeeping: $(grep -m1 -E "$(failure_re P1.ledger)" "${out}")"
				ok_ledger=0; ok_exact=0; ok_reach=0; not_run P1.exact P1.reach
			elif grep -qE "$(failure_re P1.reach)" "${out}"; then
				fail "P1.reach: node ${n} red, clause (ii): $(grep -m1 -E "$(failure_re P1.reach)" "${out}")"
				ok_reach=0; ok_exact=0; ok_ledger=0; not_run P1.exact P1.ledger
			elif refused_on_host "${out}"; then
				fail "P1.exact/ledger/reach: node ${n} REFUSED to run: a sweep variable is set in that host's own environment. This gate's guard firing, not a red of any clause"
				not_run P1.exact P1.ledger P1.reach
				ok_exact=0; ok_ledger=0; ok_reach=0
			elif grep -q 'test timed out' "${out}"; then
				fail "P1.exact/ledger/reach: node ${n} TIMED OUT at ${SWEEP_TIMEOUT}. A run that dies on the clock is not a red of any clause"
				ok_exact=0; ok_ledger=0; ok_reach=0
			else
				fail "P1.exact/ledger/reach: node ${n} failed with no message this gate attributes. Full output in ${out}"
				ok_exact=0; ok_ledger=0; ok_reach=0
			fi
			break
		fi
	done

	[ "${agree}" -eq 1 ] || fail "P1.*: the three hosts did not agree on the budget they swept"

	# A VERDICT ALREADY MARKED none IS NOT OVERWRITTEN, and getting this wrong was
	# a false green of the exact kind this gate exists to retire. not_run records
	# none; appending a pass behind it MASKS it under the old precedence, and the
	# artifact would publish as green a check the gate had just printed as NOT RUN.
	# THE GUARD CANNOT ASK verdict_of, and the first rehearsal of this phase, the
	# first time it ever ran, showed why: verdict_of answers none for TWO different
	# states, never recorded and recorded as unrun, so the guard skipped every
	# verdict here and a fully green sweep published three none. The registry is
	# read raw instead, where none exists only when not_run wrote it.
	local id v
	for id in P1.exact P1.ledger P1.reach; do
		case "${VERDICTS}" in *" ${id}=none "*) continue ;; esac
		case "${id}" in
			P1.exact)  v="${ok_exact}" ;;
			P1.ledger) v="${ok_ledger}" ;;
			P1.reach)  v="${ok_reach}" ;;
		esac
		if [ "${v}" -eq 1 ]; then record_verdict "${id}" pass; else record_verdict "${id}" fail; fi
	done
	CHECK_FAILED=0
}

# ---- the three recall points, one verdict each -------------------------------
#
# Three verdicts and not one, because the grading clause requires the audited
# subset be named one by one and never grouped: grouping lets a point that bites
# hide two that do not.

phase_recall() {
	local id sel anchor floor n out v
	for id in \
		"P1.recall.500:${RUN_R500}:recall@10 over:0.95" \
		"P1.recall.5k:${RUN_R5K}:recall@10 at scale:0.95" \
		"P1.recall.50k:${RUN_R50K}:recall@10 at LARGE scale:0.95"; do
		sel="$(echo "${id}" | cut -d: -f2)"
		anchor="$(echo "${id}" | cut -d: -f3)"
		floor="$(echo "${id}" | cut -d: -f4)"
		id="$(echo "${id}" | cut -d: -f1)"
		note "${id}: ${sel} on all three hosts"
		begin_check
		for n in "${NODE_IDS[@]}"; do
			out="${OUT_LOCAL}/$(echo "${id}" | tr . -)-node${n}.txt"
			if run_test "$n" p1-hnsw.test "${sel}" "${RECALL_TIMEOUT}" > "${out}"; then
				v="$(recall_value "${out}" "${anchor}")"
				if above_floor "${v}" "${floor}"; then
					note "${id}: node ${n} = ${v}"
				else
					fail "${id}: node ${n} passed but its recall line is missing or does not parse above ${floor} (read: '${v}'). A test that never ran and a test that passed produce the same status, so the line is the guard"
				fi
			elif refused_on_host "${out}"; then
				fail "${id}: node ${n} REFUSED to run: a sweep variable is set in that host's own environment. This gate's guard firing, not a red of this point"
			elif grep -q 'test timed out' "${out}"; then
				fail "${id}: node ${n} TIMED OUT at ${RECALL_TIMEOUT}"
			else
				fail "${id}: node ${n} red. $(grep -m1 -E 'recall.*want|FAIL' "${out}" || echo 'see '"${out}")"
			fi
		done
		end_check "${id}"
	done
}

# ---- the campaign: the five P1.point verdicts --------------------------------
#
# The five come from one invocation and one collection, which is the whole point
# of the test: clause (iii) is a conjunction, and asserting its shape on one
# collection and its floor on another satisfies it nowhere.
#
# Attribution here is by label and not by message. The campaign writes its own
# prefix on every line it emits, unlike the sweep, whose three checks share an
# invocation and have to be told apart by their text. Same binary, same run, two
# different attribution methods, so it is written down rather than inherited.
#
# And the sweep's corollary does not carry over. The campaign uses t.Errorf on
# all five, on purpose, so one red does not leave the others unrun. The four
# t.Fatalf that abort it belong to no clause: a corpus digest that has drifted
# from the generator in package hnsw, CreateCollection, Upsert and Delete. Those
# four leave all five UNRUN, and unrun is not green.

phase_point() {
	local n out v ok=1
	local ids="P1.point.ledger P1.point.exact P1.point.reach P1.point.shape P1.point.floor"
	note "P1.point.*: the three clauses together, through the API, at the top of the point, on all three hosts"
	for n in "${NODE_IDS[@]}"; do
		out="${OUT_LOCAL}/point-node${n}.txt"
		# THE EXIT STATUS IS READ AND NOT DISCARDED, which the first version got
		# wrong with a bare "|| true" while phase_sweep and phase_recall both read
		# theirs. A campaign that ends in FAIL and whose failure text this gate
		# somehow does not recognise has to be a red, never a green by omission.
		local rc=0
		run_test "$n" p1-dst.test "${RUN_POINT}" "${POINT_TIMEOUT}" > "${out}" || rc=$?

		if grep -q 'test timed out' "${out}"; then
			fail "P1.point.*: node ${n} TIMED OUT at ${POINT_TIMEOUT}. Not a red of any clause"
			ok=0
			continue
		fi
		if refused_on_host "${out}"; then
			fail "P1.point.*: node ${n} REFUSED to run: a sweep variable is set in that host's own environment. This gate's guard firing, not a red of any clause"
			not_run ${ids}
			ok=0
			continue
		fi
		# The four aborts, matched on the bare prefix followed by a space, which
		# is what separates them from the five labelled verdicts.
		if grep -qE 'point_test\.go:[0-9]+: P1\.point: (corpus digest is|CreateCollection|Upsert|Delete)' "${out}"; then
			fail "P1.point.*: node ${n} ABORTED before the clauses ran: $(grep -m1 -E 'P1\.point: (corpus digest is|CreateCollection|Upsert|Delete)' "${out}")"
			not_run ${ids}
			ok=0
			continue
		fi
		local id label
		for id in ${ids}; do
			label="${id}"
			# The pattern comes from failure_re and is the SAME one the red arm
			# scores with. The .* between the label and the pattern is what the
			# first version lacked: the shape checker prefixes its text with
			# "query %d at k=%d over %d live: ", so anchoring the alternatives
			# directly behind the label matched none of its six failure forms.
			if grep -qE "${label}: .*$(failure_re "${label}")" "${out}"; then
				fail "${id}: node ${n} red. $(grep -m1 -E "${label}: " "${out}" | sed 's/^[[:space:]]*//')"
				ok=0
			fi
		done
		# P1.point.query is the sixth label and it is not a clause. It is
		# unreachable through this test, since Query fails only on a wrong dim or
		# a non-positive k and both are constants, so it is reported as a harness
		# failure rather than left to fall through unnamed.
		if grep -qE "P1\.point\.query: .*$(failure_re P1.point.query)" "${out}"; then
			fail "P1.point.*: node ${n} emitted the harness label P1.point.query, which this arrangement makes unreachable: $(grep -m1 -E 'P1\.point\.query: ' "${out}" | sed 's/^[[:space:]]*//')"
			ok=0
		fi
		# The floor line prints on every run, pass or fail, so it is the campaign's
		# anti-vacuity guard exactly as the recall lines are for the three points.
		v="$(recall_value "${out}" P1.point.floor)"
		if above_floor "${v}" "$(declared_const pointFloor)"; then
			note "P1.point.floor: node ${n} = ${v}"
		else
			fail "P1.point.floor: node ${n} has no parsable floor line above the declared floor (read: '${v}')"
			ok=0
		fi
		if [ "${rc}" -ne 0 ] && [ "${ok}" -eq 1 ]; then
			fail "P1.point.*: node ${n} exited ${rc} and none of the five labels carried a failure this gate recognises. That is an unattributed red and it is reported as one rather than published as five greens"
			ok=0
		fi
		if grep -q 'P1.point.reach: swept' "${out}"; then
			note "P1.point.reach: node ${n} $(grep -m1 'P1.point.reach: swept' "${out}" | sed 's/.*P1.point.reach: //')"
		else
			fail "P1.point.reach: node ${n} printed no sweep line, so the artifact cannot state that the reachability sweep ran over every live id"
			ok=0
		fi
	done
	local id
	if [ "${ok}" -eq 1 ]; then
		for id in ${ids}; do record_verdict "${id}" pass; done
		pass "P1.point.*: the five verdicts are green on all three hosts"
	else
		# THE SAME COLLAPSE AS THE SWEEP GUARD, mirror image: a clause red with no
		# abort leaves all five unrecorded, and verdict_of answers none for an
		# unrecorded verdict too, so asking it recorded nothing and a real red
		# published five none. The registry is read raw, where none exists only
		# when not_run wrote it: those stay none and the rest record their fail.
		for id in ${ids}; do
			case "${VERDICTS}" in
				*" ${id}=none "*) ;;
				*) record_verdict "${id}" fail ;;
			esac
		done
	fi
}

# ---- the red arm -------------------------------------------------------------
#
# METHOD, fixed since the DEFER-005 arc and not relaxed here. Each row breaks ONE
# property on a copy OUTSIDE the repository, runs ONLY the check that claims to
# defend it, and expects red. A green row names a check that defends nothing. The
# mutated tree is compiled before it is run and a compile failure is NO-BUILD,
# never a red. TIMEOUT is a fourth outcome, and it exists because a loose test
# binary runs with its timeout disabled.
#
# The fourth outcome is also a declared green. A row may require red in one check
# and green in another, provided both are written down before it runs. Row 4 does
# exactly that: the floor falls in all four places while the sweep survives its
# whole budget.
#
# What the red arm does not do: it attests ONE host, not three.
#
# And one thing it deliberately does not assert, which is how this gate can run
# with DEFER-062 still open. The reachability message names the FIRST id that
# violates, and oracle.ids() walks a map, so which id appears is not deterministic
# even though the run is. This arm therefore asserts the message CLASS and records
# the literal id as an OBSERVATION. Asserting the id would archive a figure that
# another run can change with no defect present, which is the class this gate
# exists to retire.

mutate() {
	# mutate <copy root> <name>. Each edit asserts its own match count, so a
	# mutation whose target has moved fails loudly instead of applying to nothing.
	python3 - "$1" "$2" <<'PYEOF'
import sys, os
root, mut = sys.argv[1], sys.argv[2]
def sub(path, old, new, n=1):
    s = open(path, encoding='utf-8').read()
    assert s.count(old) == n, (path, s.count(old), old[:60])
    open(path, 'w', encoding='utf-8').write(s.replace(old, new))
hnsw = os.path.join(root, 'hnsw')
nay = os.path.join(root, 'naylamp')
if mut == 'sinreparar':
    sub(os.path.join(hnsw, 'delete.go'), '\t\tidx.repairNeighborhood(neighbors, layer)\n', '')
elif mut == 'fuga':
    sub(os.path.join(nay, 'operations.go'),
        '\tif err := c.store.Delete(id); err != nil {\n\t\treturn err\n\t}\n\tc.index.Delete(id)\n\treturn nil',
        '\tc.index.Delete(id)\n\treturn nil')
elif mut == 'fantasma':
    sub(os.path.join(nay, 'operations.go'), '\tc.index.Delete(id)\n', '')
elif mut == 'ef18':
    sub(os.path.join(hnsw, 'hnsw.go'), '\tDefaultEfSearch = 300', '\tDefaultEfSearch = 18')
elif mut == 'relleno':
    sub(os.path.join(hnsw, 'search.go'),
        '\tif k < len(found) {\n\t\tfound = found[:k]\n\t}\n',
        '\tif k < len(found) {\n\t\tfound = found[:k]\n\t}\n'
        '\tfor len(found) > 0 && len(found) < k {\n\t\tfound = append(found, found[len(found)-1])\n\t}\n')
else:
    raise SystemExit('unknown mutation: ' + mut)
print('mutation %s applied under %s' % (mut, root))
PYEOF
}

build_mutant() {
	# build_mutant <name> <package dir> <out binary>. Returns 2 on NO-BUILD.
	local mut="$1" pkg="$2" out="$3"
	# OUTSIDE THE REPOSITORY, and the first version was not. It built under
	# gate/out/, which is inside the working tree and invisible to git status only
	# because .gitignore covers that directory. The method fixed since the
	# DEFER-005 arc says outside, and a copy that lives inside is one bad pattern
	# away from a mutation reaching the tree it is meant to leave alone.
	local root="${MUT_ROOT}/mut-${mut}"
	rm -rf "${MUT_ROOT:?}/mut-${mut:?}"
	mkdir -p "${root}"
	( cd "${REPO_DIR}" && git archive HEAD engine ) | tar -x -C "${root}"
	# THE TOOLCHAIN COMES FROM THE TREE AND NOT FROM THIS FILE. The first version
	# wrote its own go.work with the version spelled out, so the day the repository
	# bumps, every red row would keep building against a pin written inside the
	# gate while the tree named another. The pin lives in the repository, which is
	# the whole point of go.work governing in workspace mode.
	cp "${REPO_DIR}/go.work" "${root}/go.work"
	# The two failures are separated, because they are different causes and this
	# method already separates four outcomes for that same reason. 3 means the
	# mutation did not apply, which is a target that has moved, and 2 means the
	# mutated tree did not compile.
	mutate "${root}/engine" "${mut}" || return 3
	if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
		( cd "${root}" && go test -c -o "${out}" "./engine/${pkg}/" ) || return 2
	else
		( cd "${root}" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o "${out}" "./engine/${pkg}/" ) || return 2
	fi
	return 0
}

# red_row <id> <mutation> <package> <selector> <timeout> <expect-red regex> <green mode> <green regex> <green presence anchor>
#
# THE GREEN HALF COMES IN TWO KINDS AND CONFLATING THEM IS A REAL DEFECT, which
# this script found by running the rows rather than by reading the design. The
# design says of rows 2 and 3 that each "leaves the other green", and over the
# seeded sweep that CANNOT BE OBSERVED: checkInvariants composes the three checks
# and returns on the first failure, so when the leak mutation reddens the count,
# the set check NEVER RUNS. Absence of its message is not a green, it is a check
# that was not reached, and by this house's own rule an unreached check is not a
# passing one.
#
#   cut   the composed checker cuts at the first failure. Absence is reported as
#         NOT REACHED and is not scored as a green.
#   runs  the campaign uses t.Errorf on all five, so every check runs and prints
#         its own line. Absence of the failure text under a label whose line IS
#         present is a genuine green, and the anchor is what proves it ran.
#   none  nothing declared for the other side.
red_row() {
	local id="$1" mut="$2" pkg="$3" sel="$4" tmo="$5" want="$6" gmode="$7" green="${8:-}" ganchor="${9:-}"
	local bin="${OUT_LOCAL}/${mut}.test" remote="p1-${mut}.test" out="${OUT_LOCAL}/red-${mut}.txt"
	note "${id}: mutation ${mut}, on node ${RED_NODE}, expecting red in ${want}"
	begin_check
	local brc=0
	build_mutant "${mut}" "${pkg}" "${bin}" || brc=$?
	if [ "${brc}" -eq 3 ]; then
		fail "${id}: MUTATION STALE. The edit did not apply, so its target has moved in the tree. Nothing ran, and this is neither a red nor a NO-BUILD"
		end_check "${id}"
		return
	elif [ "${brc}" -ne 0 ]; then
		fail "${id}: NO-BUILD. The mutated tree did not compile, which is never a red of its clause"
		end_check "${id}"
		return
	fi
	copy_to "${RED_NODE}" "${bin}" "${REMOTE_DIR}/${remote}" || { fail "${id}: could not upload the mutant"; end_check "${id}"; return; }
	run_on "${RED_NODE}" "chmod +x ~/${REMOTE_DIR}/${remote}"
	run_test "${RED_NODE}" "${remote}" "${sel}" "${tmo}" > "${out}" || true

	if refused_on_host "${out}"; then
		fail "${id}: the host REFUSED to run it, because a sweep variable is set in its own environment. Not a survival and not a red: the row did not run"
		end_check "${id}"
		return
	fi
	if grep -q 'test timed out' "${out}"; then
		fail "${id}: TIMED OUT at ${tmo}. A row that dies on the clock is not a red of its clause"
		end_check "${id}"
		return
	fi
	if ! grep -qE "${want}" "${out}"; then
		fail "${id}: SURVIVED. The mutation ran and the check that claims to defend this clause did not go red, so it defends nothing"
		end_check "${id}"
		return
	fi
	pass "${id}: red as written. $(grep -m1 -E "${want}" "${out}" | sed 's/^[[:space:]]*//')"

	case "${gmode}" in
		none) ;;
		cut)
			if grep -qE "${green}" "${out}"; then
				fail "${id}: the mutation ALSO reddened the check written down as the other side, so the row does not isolate"
			else
				note "${id}: the other check was NOT REACHED, not green. The sweep aborts on the first violation, so this row cannot attest what it leaves standing; that attestation needs an instrument that evaluates all three, and this gate does not carry one"
			fi
			;;
		runs)
			if ! grep -qE "${ganchor}" "${out}"; then
				fail "${id}: the check written down as the other side printed no line, so it cannot be called green"
			elif grep -qE "${green}" "${out}"; then
				fail "${id}: the mutation ALSO reddened the check written down as the other side. The row does not isolate"
			else
				note "${id}: the other side ran and stayed green, as written"
			fi
			;;
	esac
	end_check "${id}"
}

# THE OTHER FOUR TARGETS OF ROW 4, because the design names FIVE and the first
# version of this gate ran one. The three recall points have to fall under the
# same mutation, and the seeded sweep has to SURVIVE it. That survival is the
# fourth outcome of the method, a row requiring red in one check and green in
# another with both written down beforehand, and it is the half that carries the
# isolation argument: clause (iii) drops in all four of its places while clause
# (ii) holds over two million operations.
red_row_floor_rest() {
	local hbin="${OUT_LOCAL}/ef18-hnsw.test" out sel anchor id v brc=0
	build_mutant ef18 hnsw "${hbin}" || brc=$?
	if [ "${brc}" -ne 0 ]; then
		fail "P1.red.floor: the hnsw mutant did not build (${brc}), so the three recall targets of this row did not run"
		return
	fi
	copy_to "${RED_NODE}" "${hbin}" "${REMOTE_DIR}/p1-ef18-hnsw.test" || { fail "P1.red.floor: could not upload the hnsw mutant"; return; }
	run_on "${RED_NODE}" "chmod +x ~/${REMOTE_DIR}/p1-ef18-hnsw.test"

	for id in \
		"recall.500|${RUN_R500}|recall@10 over" \
		"recall.5k|${RUN_R5K}|recall@10 at scale" \
		"recall.50k|${RUN_R50K}|recall@10 at LARGE scale"; do
		sel="$(printf '%s' "${id}" | cut -d'|' -f2)"
		anchor="$(printf '%s' "${id}" | cut -d'|' -f3)"
		id="$(printf '%s' "${id}" | cut -d'|' -f1)"
		out="${OUT_LOCAL}/red-ef18-${id}.txt"
		run_test "${RED_NODE}" p1-ef18-hnsw.test "${sel}" "${RECALL_TIMEOUT}" > "${out}" || true
		v="$(recall_value "${out}" "${anchor}")"
		if refused_on_host "${out}"; then
			fail "P1.red.floor: the host refused the ${id} target, so it did not run"
		elif [ -z "${v}" ]; then
			fail "P1.red.floor: the ${id} target printed no recall line, so this row cannot say whether it fell"
		elif above_floor "${v}" 0.95; then
			fail "P1.red.floor: under efSearch=18 the ${id} target still reads ${v}, above the floor. It SURVIVED the mutation"
		else
			note "P1.red.floor: ${id} falls to ${v} under the mutation, as written"
		fi
	done

	out="${OUT_LOCAL}/red-ef18-sweep.txt"
	if run_test "${RED_NODE}" p1-ef18.test "${RUN_SWEEP}" "${SWEEP_TIMEOUT}" > "${out}"; then
		note "P1.red.floor: the seeded sweep SURVIVES efSearch=18 over its whole budget, as written. That is what lets this row claim it drops clause (iii) without touching clause (ii)"
	elif refused_on_host "${out}"; then
		fail "P1.red.floor: the host refused the sweep target, so the declared green of this row did not run"
	else
		fail "P1.red.floor: the seeded sweep did NOT survive efSearch=18, so this row reddens two clauses and isolates neither"
	fi
}

phase_red() {
	note "the red arm, five rows, on node ${RED_NODE} only"

	# Row 1, clause (ii). Reverts the fix this engine needed: without the repair a
	# node can lose every neighbour and become unreachable, which the comment on
	# deleteLocked records as what the seeded simulation exposed. Measured red at
	# seed 4, step 600, on 168a4b9. The literal id is an observation and never an
	# assertion, for the reason set out above the definition of red_row.
	red_row P1.red.reach sinreparar dst "${RUN_SWEEP}" "${SWEEP_TIMEOUT}" \
		"$(failure_re P1.reach)" none

	# Row 2, the harness bookkeeping and no clause. Skipping the store delete
	# leaves the INDEX set exactly right, so clause (i) read literally holds.
	red_row P1.red.ledger fuga dst "${RUN_SWEEP}" "${SWEEP_TIMEOUT}" \
		"$(failure_re P1.ledger)" cut "$(failure_re P1.exact)"

	# Row 3, clause (i). Skipping the index delete leaves a ghost whose data is
	# cached in the node, so it is a measurable node and not a dangling reference.
	red_row P1.red.ghost fantasma dst "${RUN_SWEEP}" "${SWEEP_TIMEOUT}" \
		"$(failure_re P1.exact)" cut "$(failure_re P1.ledger)"

	# Row 4, clause (iii) in its floor, scored against P1.point.floor. A default
	# nobody can compensate for from the API is a defect the engine could have and
	# not a knob. Measured on 168a4b9 at the top of the point: the floor
	# falls to 0.4700 while the set and the reachability stay green over the same
	# fifty thousand live ids. Both of those DO run and print, so their green is a
	# green and not an absence.
	red_row P1.red.floor ef18 dst "${RUN_POINT}" "${POINT_TIMEOUT}" \
		"P1\.point\.floor: .*$(failure_re P1.point.floor)" \
		runs "P1\.point\.(exact|reach): .*($(failure_re P1.point.exact)|$(failure_re P1.point.reach))" \
		'P1\.point\.reach: swept [0-9]+ live ids'
	red_row_floor_rest

	# Row 5, clause (iii) in its shape, scored against P1.point.shape. The filling
	# mutation CANNOT fire in the normal regime, since fifty queries at k=10 over
	# fifty thousand live never see fewer live than k: measured, fifty of fifty
	# pass. It bites only on the degenerate rung, and that is what makes the rung
	# load bearing. Without it this row would be a GREEN row, which is what row 3
	# already had to be struck for once.
	red_row P1.red.shape relleno dst "${RUN_POINT}" "${POINT_TIMEOUT}" \
		"P1\.point\.shape: .*$(failure_re P1.point.shape)" \
		runs "P1\.point\.floor: .*$(failure_re P1.point.floor)" \
		'P1\.point\.floor: recall@[0-9]+ = [0-9.]+ over'
}

# ---- P1.hygiene --------------------------------------------------------------

phase_hygiene() {
	note "P1.hygiene: nothing left behind on any host"
	begin_check

	# Nothing this gate runs writes a file, and that is checked rather than
	# assumed. The only three tests in the tree that leave files behind are
	# TestHNSW_ScaleRecallSweep, TestHNSW_BuildScale and TestHNSW_SIFTScale, all
	# three behind -short and none of them in this gate's selection. That holds
	# only while the selectors stay anchored, which P1.pre proved.
	# ABSENCE OF AN ANSWER IS NOT ABSENCE OF THE DIRECTORY, and the first version
	# of both loops below could not tell the two apart. The second one asked with
	# "if run_on ... test -e", so an ssh that failed made the condition false and
	# the host was reported CLEAN: a host nobody could reach passed as tidy. Both
	# loops now make the far side SAY which of the three it is, and a missing
	# answer is its own outcome.
	local n left=0 listing probe
	for n in "${NODE_IDS[@]}"; do
		listing="$(run_on "$n" "ls -A ~/${REMOTE_DIR} 2>/dev/null | grep -v -E '^p1-.*\.test$' || true; echo __ANSWERED__" 2>/dev/null || true)"
		case "${listing}" in
			*__ANSWERED__*) ;;
			*)
				fail "P1.hygiene: node ${n} did not answer the listing, so this gate cannot say whether anything was written there"
				left=1
				continue
				;;
		esac
		listing="${listing%__ANSWERED__*}"
		listing="$(printf '%s' "${listing}" | tr -d '[:space:]')"
		if [ -n "${listing}" ]; then
			fail "P1.hygiene: node ${n} holds files this gate did not upload, so something wrote to the working directory"
			left=1
		fi
	done

	# THE DELETION IS WRITTEN WITH THE PREFIX LITERAL AND THE RUN ID APPENDED
	# INLINE, never as a bare variable, and pwd -P runs first. The pattern of an
	# rm with a path in a variable admits a day when the variable arrives empty.
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" "cd ~ && pwd -P && rm -rf ~/naylamp-p1-${RUN_ID}" >/dev/null || fail "P1.hygiene: the removal failed on node ${n}"
	done

	# And it checks that the removal happened, which is the half DEFER-042 records
	# as missing from cluster.sh stop: there the kill -0 runs AFTER the TERM and
	# only looks for absence, never that the pid existed first.
	for n in "${NODE_IDS[@]}"; do
		probe="$(run_on "$n" "if [ -e ~/naylamp-p1-${RUN_ID} ]; then echo PRESENT; else echo ABSENT; fi" 2>/dev/null || true)"
		case "${probe}" in
			ABSENT)  note "P1.hygiene: node ${n} answered and the directory is gone" ;;
			PRESENT)
				fail "P1.hygiene: node ${n} still holds the working directory after the removal"
				left=1
				;;
			*)
				fail "P1.hygiene: node ${n} gave no answer, so this gate cannot claim its material was retired. Not answering is not the same as being clean"
				left=1
				;;
		esac
	done
	# AND THE LOCAL SIDE, which the first version left out entirely. The red arm
	# copies the whole engine once per mutation under the system temp directory,
	# OUTSIDE the repository on purpose, and outside is exactly where make clean
	# and .gitignore cannot reach. Six copies per run, kept for ever, is the kind
	# of accumulation this house does not leave behind. Removed with the prefix
	# literal and the run id appended inline, the same shape as the host side.
	if [ -d "${TMPDIR:-/tmp}/naylamp-p1-mut-${RUN_ID}" ]; then
		rm -rf "${TMPDIR:-/tmp}/naylamp-p1-mut-${RUN_ID}"
		if [ -d "${TMPDIR:-/tmp}/naylamp-p1-mut-${RUN_ID}" ]; then
			fail "P1.hygiene: the red arm's mutated copies are still under ${TMPDIR:-/tmp}"
			left=1
		else
			note "P1.hygiene: the red arm's mutated copies are gone from this machine"
		fi
	fi

	# AND THE REHEARSAL'S OWN FLEET, which is three directories under gate/out and
	# leaves nothing behind either. Literal prefix with the run id appended inline,
	# the same shape as the host side.
	if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
		if [ -d "${OUT_DIR}/p1-local-fleet-${RUN_ID}" ]; then
			rm -rf "${OUT_DIR}/p1-local-fleet-${RUN_ID}"
			if [ -d "${OUT_DIR}/p1-local-fleet-${RUN_ID}" ]; then
				fail "P1.hygiene: the rehearsal fleet is still under gate/out"
				left=1
			else
				note "P1.hygiene: the rehearsal fleet is gone from gate/out"
			fi
		fi
	fi

	if [ "${left}" -eq 0 ]; then
		pass "P1.hygiene: the working directory is gone from all three hosts, the mutated copies are gone from this machine, and nothing else was written"
		# ONLY HERE. The first version cleared this unconditionally, so a removal
		# that failed on a node suppressed the trap's warning and its by-hand
		# command in exactly the case they were written for.
		UPLOADED=0
	fi
	end_check P1.hygiene
}

# ---- build -------------------------------------------------------------------

phase_build() {
	mkdir -p "${OUT_DIR}" "${OUT_LOCAL}"
	if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
		note "rehearsal: building the two test binaries NATIVE, because the cross pair cannot exec on this machine; on iron this build is linux/arm64 static"
		( cd "${REPO_DIR}/engine" && go test -c -o "${DST_BIN}" ./dst/ ) \
			|| stop "the dst test binary did not build"
		( cd "${REPO_DIR}/engine" && go test -c -o "${HNSW_BIN}" ./hnsw/ ) \
			|| stop "the hnsw test binary did not build"
		# The native pair is byte identical to the upload pair here, so the
		# rehearsal cannot drift the two builds apart: one build, two names.
		cp "${DST_BIN}" "${DST_NATIVE}"
		cp "${HNSW_BIN}" "${HNSW_NATIVE}"
	else
		note "cross compiling the two test binaries to linux/arm64, static"
		( cd "${REPO_DIR}/engine" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o "${DST_BIN}" ./dst/ ) \
			|| stop "the dst test binary did not cross compile"
		( cd "${REPO_DIR}/engine" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o "${HNSW_BIN}" ./hnsw/ ) \
			|| stop "the hnsw test binary did not cross compile"
		# And the native pair, whose only job is to answer -test.list on this machine.
		# The cross compiled pair cannot: it is an ELF and the control host is not
		# Linux. Same source, same command, same phase, so the two cannot drift.
		( cd "${REPO_DIR}/engine" && go test -c -o "${DST_NATIVE}" ./dst/ ) \
			|| stop "the native dst test binary did not build, so P1.pre cannot list its selectors"
		( cd "${REPO_DIR}/engine" && go test -c -o "${HNSW_NATIVE}" ./hnsw/ ) \
			|| stop "the native hnsw test binary did not build, so P1.pre cannot list its selectors"
	fi
	note "built $(basename "${DST_BIN}") $(stat -f%z "${DST_BIN}" 2>/dev/null || stat -c%s "${DST_BIN}") bytes and $(basename "${HNSW_BIN}") $(stat -f%z "${HNSW_BIN}" 2>/dev/null || stat -c%s "${HNSW_BIN}") bytes"
	if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
		note "no -race in the rehearsal either: the binaries build exactly as P1.pre's native pair, and on the concurrency axis this gate stays WEAKER than CI"
	else
		note "no -race: CGO_ENABLED=0 forbids it, so on the concurrency axis this gate is WEAKER than CI, which keeps that duty whole"
	fi
}

# ---- dispatch ----------------------------------------------------------------
#
# NO DEFAULT. A bare invocation prints the usage and exits 2, the shape
# checkquorum.sh and omnibus.sh use. This gate uploads to three machines and
# spends the better part of two hours; a mistyped or argument-less invocation
# must never be the one that starts it.

usage() {
	cat >&2 <<'USAGE'
usage: p1.sh <all|pre|provenance|sweep|recall|point|red|hygiene>

  all         every phase below, in the only order in which they mean something
  pre         the door. Refuses the sweep variables, reads the declared budget
              and the campaign constants out of the source, proves each selector
              picks exactly one test, and runs two negative arms. Touches no host
  provenance  the commit anchor, and the two binaries uploaded with their sha256
              compared across the three hosts
  sweep       the seeded sweep at its declared budget: P1.exact, P1.ledger and
              P1.reach, attributed by message out of one invocation
  recall      the three recall points, one verdict each and never grouped
  point       the campaign: the three clauses together, through the API, at the
              top of the point. Five verdicts from one collection
  red         five mutations, on ONE host, each expecting red in the check that
              claims to defend its clause
  hygiene     removes what was uploaded AND checks that it is gone. Takes an
              optional run id: without one it cleans THIS invocation's directory,
              which is what "all" wants and which on its own would clean nothing,
              since every invocation mints a new id

ORDER MATTERS AND ONLY IN ONE DIRECTION. hygiene runs AFTER red and never before:
red is what uploads mutated binaries, and a hygiene that ran first would declare
the hosts clean with a mutant still on them.

pre is the one subcommand that needs no host, so it is the one that can run with
the machines deallocated.

NAYLAMP_P1_LOCAL=1 runs the REHEARSAL: the three hosts must be loopback, the
transport is three directories on this machine and the binaries native, and the
run banners both streams and names its artifact p1-local-<run id>, so nothing it
prints can later read as gate evidence. It exists to debug this script before
the script costs VM time.

BEFORE A SEALING RUN, take the full-length probe on one host. The per-VM budgets
in this file are a house rule of 3 to 5 times the laptop and not a measurement,
and the SKU is a burst VM: a short probe on a host with credits underestimates.
USAGE
}

cmd="${1:-}"
# A STANDALONE hygiene NEEDS THE RUN ID OF THE RUN IT IS CLEANING. Without this
# it minted a fresh id, then listed, removed and verified a directory that had
# never existed, and went green having retired nothing, which is the only case in
# which anyone invokes it by itself.
if [ "${cmd}" = hygiene ] && [ -n "${2:-}" ]; then
	case "$2" in
		[0-9]*Z-[0-9]*) RUN_ID="$2"; REMOTE_DIR="naylamp-p1-${RUN_ID}"
			# The local shapes must follow the overridden id too. Setting OUT_LOCAL's
			# iron shape unconditionally made a standalone rehearsal hygiene write an
			# artifact directory named p1-<run id>, the one name the rehearsal guard
			# swears never to create, and rehearsal_setup built a fleet under this
			# invocation's own minted id that the cleaning then never retired.
			if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then local_paths; else OUT_LOCAL="${OUT_DIR}/p1-${RUN_ID}"; fi ;;
		*) echo "gate: ${2} is not the shape of a run id this script writes" >&2; exit 2 ;;
	esac
fi
case "${cmd}" in
	pre|provenance|sweep|recall|point|red|hygiene|all) ;;
	*) usage; exit 2 ;;
esac
RUN_STARTED=1

# The rehearsal's fleet is set up only once the run id is final: a standalone
# hygiene rewrites it from its argument, and the fleet and the artifact must
# follow that id and not the one this invocation minted.
if [ "${NAYLAMP_P1_LOCAL:-}" = 1 ]; then
	rehearsal_setup
fi

echo "=== NAYLAMP PHASE 1 IRON GATE, $(date -u) ==="
echo "subcommand: ${cmd}"
echo "run id: ${RUN_ID}"
echo "hosts (pub): ${NAYLAMP_GATE_HOSTS}"
echo "red arm host: node ${RED_NODE}"
echo "budgets: sweep=${SWEEP_TIMEOUT} recall=${RECALL_TIMEOUT} point=${POINT_TIMEOUT}, all three ceilings and none of them estimates"
# The list is the twenty three live exclusions of G3, counted against that
# section and not summarised: 1 to 12, 15, 16 and 18 to 26. Thirteen, fourteen and
# seventeen are struck there and are not repeated here. Clause (d) forbids raising
# a phase without naming what is not verified, so a short version of this line
# would be the one thing the gate cannot afford to abbreviate.
echo "not claimed (23, the live exclusions of G3): 1 result order; 2 speed, latency and throughput; 3 durability; 4 concurrency, where this gate is WEAKER than CI; 5 the corpus/efSearch axis; 6 that the result is THE exact one; 7 the API surface 1.4 promised; 8 isolation between collections; 9 memory and index size; 10 build determinism under seed; 11 every metric but cosine; 12 degenerate vectors and ties; 15 coverage of the dim interval, which is sampled at two values; 16 that the recall floor is a sample over fixed query seeds and not a bound; 18 that the red arm attests ONE VM and not three; 19 that this is a deployed service; 20 ARM64 arithmetic as a contribution, which measurement retired; 21 what the three-host agreement can see, which is little by construction; 22 the reupsert regime above the layer-0 cap; 23 the concurrent falsifier of clause (i); 24 that the degenerate rung runs with layer 0 unpruned; 25 that reachability at the top of the point has no red arm; 26 that no row of this red arm can notice its own metric has stopped measuring"

mkdir -p "${OUT_LOCAL}"

if [ "${cmd}" != pre ]; then
	require_hosts_reachable
fi

case "${cmd}" in
	pre)
		EXPECTED="P1.pre"
		phase_build
		phase_pre
		;;
	provenance)
		EXPECTED="P1.pre P1.provenance"
		phase_build
		phase_pre
		phase_provenance
		;;
	sweep)
		EXPECTED="P1.pre P1.exact P1.ledger P1.reach"
		phase_build; phase_pre; phase_provenance; phase_sweep
		;;
	recall)
		EXPECTED="P1.pre P1.recall.500 P1.recall.5k P1.recall.50k"
		phase_build; phase_pre; phase_provenance; phase_recall
		;;
	point)
		EXPECTED="P1.pre P1.point.ledger P1.point.exact P1.point.reach P1.point.shape P1.point.floor"
		phase_build; phase_pre; phase_provenance; phase_point
		;;
	red)
		EXPECTED="P1.pre P1.red.reach P1.red.ledger P1.red.ghost P1.red.floor P1.red.shape"
		phase_build; phase_pre; phase_provenance; phase_red
		;;
	hygiene)
		EXPECTED="P1.hygiene"
		phase_hygiene
		;;
	all)
		EXPECTED="P1.pre P1.provenance P1.exact P1.ledger P1.reach P1.recall.500 P1.recall.5k P1.recall.50k P1.point.ledger P1.point.exact P1.point.reach P1.point.shape P1.point.floor P1.red.reach P1.red.ledger P1.red.ghost P1.red.floor P1.red.shape P1.hygiene"
		phase_build
		phase_pre
		phase_provenance
		phase_sweep
		phase_recall
		phase_point
		phase_red
		phase_hygiene
		;;
esac

COMPLETED=1
note "artifacts for this run are under ${OUT_LOCAL}"
