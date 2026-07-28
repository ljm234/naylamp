#!/usr/bin/env bash
# servicehealth.sh: prove on the three real hosts that the service-health signal
# recovers a leader that still holds quorum with its peers but has gone mute
# toward the client (Subphase 4.1). The leader keeps its heartbeats and
# stays leader while only its ack to the client is dropped, the case CheckQuorum
# cannot see. With the feature on, the leader steps down at its own term, a peer
# takes over, and the client is served WITHOUT the muted edge ever being healed;
# with it off, the leader holds the term forever and the operation is never
# served. This gate is styled on retry.sh (the same verdict registry, teardown
# trap, leader helpers, and the mute of partition.sh) and lives among the gate
# scripts so it can source common.sh and call cluster.sh, partition.sh, build.sh,
# and deploy.sh as siblings.
#
# The feature is one thing enabled in two places at once: the node's
# -service-health arms the step-down, and the client's -service-health drives a
# continuous load over one long-lived router with timeout rotation on. Rotation
# without the signal reopens the mute-leader hint bounce, and the signal without
# rotation deadlocks the recovery, so the gate turns both on together (the node
# flags through cluster.sh, the client flags through its own wrapper) and never
# only one.
#
# Only the answers-only arm (leader->client dropped, client->leader open) is built
# on hardware: the client shares host 1's ip with node 1, so a rule toward the
# client ip cannot cut the client->node path without also cutting Raft to node 1.
# That co-location is why the arm that cuts ONE node off in both directions is not
# constructible here; it stays a simulation-only result, and so do the two regimes
# that touch every node at once. The answers-only arm is the one the simulation
# measured ceding and recovering, over two seeds, asserting safety and logging the
# outcome rather than requiring it.
#
# Budgets are derived from the tick cadence and the sealed constants, never
# trimmed to run faster:
#   tick        10ms per logical tick (the node -tick and the client -tick match)
#   window W    ElectionTicks = 10 ticks = 0.10s (the leader's reach evaluation)
#   hysteresis  H = 2 windows = 20 ticks = 0.20s the step-down must be sustained
#   rotate K    2 silent timeouts before the client abandons a target
#   R_rot       50 ticks = 0.50s retransmit timeout (probe 10 ticks, cooldown 50)
#   op budget   3 x group = 9 attempts, so a single op retires in about 4.5s,
#               before the step-down closes, which is why the load is continuous
# Over 500 seeds the simulation measured a worst cede at 609 ticks (6.09s, seed
# 203) and a worst serve at 1847 ticks (18.47s, seed 263) after seven re-wins, both
# inside an 80s hard budget; the median cede is 119 ticks and the median serve 156.
# The round-equals-tick equivalence is exact only in the simulation; a live daemon
# adds real network and fsync latency per wall tick, so these are floors and the
# service budget is set to 170s, above twice the 80s simulation floor. Recovery is
# EVENTUAL, not bounded-fast: the aggregate signal lets a muted leader re-win the
# election it released and drag the pre-vote metastable tail, so the positive is
# served-within the budget with a reconverging tail, never a tight bound.
#
# Every check registers a verdict; the final report, from the exit trap, calls the
# run a success only when every expected check passed and a check that never ran
# counts as not passed, exactly as retry.sh does. Each verdict phase wipes
# naylamp/data and naylamp/logs on all three hosts and relands leadership on node 2
# or 3 first, so a phase is read off a pristine cluster and a stale role line never
# contaminates a count. Meant to run under one tee with build and deploy chained:
#
#   ./servicehealth.sh all 2>&1 | tee ~/Desktop/Naylamp_workspace/NAYLAMP_SERVICEHEALTH_GATE_$(date +%F).txt
#
# Usage: servicehealth.sh <all|heal>
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

# ---- derived budgets --------------------------------------------------------
# The sealed constants, named so the derivation above is auditable in one place.
TICK_MS=10
ELECTION_TICKS=10       # window W
HYST_WINDOWS=2          # H, the node default -service-health-windows falls to
ROTATE_TIMEOUTS=2       # K
RETRANSMIT_TICKS=50     # R_rot, and the derived cooldown

# The tick budgets in milliseconds, echoed at the run head so the numbers are
# explicit in the evidence, the way checkquorum.sh prints its bound.
WINDOW_MS=$(( ELECTION_TICKS * TICK_MS ))
HYST_MS=$(( HYST_WINDOWS * ELECTION_TICKS * TICK_MS ))
ROTATE_MS=$(( ROTATE_TIMEOUTS * RETRANSMIT_TICKS * TICK_MS ))

# Poll and relocation budgets, the same shape as checkquorum.sh and readindex.sh.
POLL_S=1
ELECT_TIMEOUT_S=15      # poll budget for a leader to appear after a start
RELOCATE_SETTLE_S=5     # let a redraw settle before reading the role line
RESTART_TRIES=8         # bounded redraws until leadership lands off node 1

# Verdict windows, all floors, none trimmed to run faster.
BITE_DL=3s              # several re-emissions so the DROP counter is unambiguous
NEG_LOAD_S=40           # healthy continuous load, tens of seconds (400 windows)
RETAIN_S=80            # the off-signal hold, the same order as the on budget
SERVICE_BUDGET_S=170    # the eventual service budget, above 2x the 80s DST floor
LOAD_COUNT=100000       # a high op cap; the deadline is the real bound

# MARKER_ID is the idempotent write id the load re-issues; VEC is its vector. The
# same id every time is a fresh router operation each time (a fresh op id) and an
# idempotent commit, mirroring the sealed DST re-issue.
MARKER_ID=411
VEC=1,0,0

# ---- verdict registry (shape shared with retry.sh) --------------------------
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0

# Homogeneity evidence, filled by record_binary_digests and read by the guard.
FIRST_DIGEST=""
SAME_BINARY=0

pass() { echo "gate: PASS $*"; }
note() { echo "gate: $*"; }
fail() { echo "gate: FAIL $*" >&2; CHECK_FAILED=1; }
stop() { echo "gate: STOP $*" >&2; exit 1; }

record_verdict() { VERDICTS="${VERDICTS}$1=$2 "; }
verdict_of() {
	case "${VERDICTS}" in
		*" $1=fail "*) printf fail ;;
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

# emit_final_verdict prints one line per expected check and returns 0 only when the
# run completed and every expected check registered pass. Side effect free, so the
# trap owns the exit code.
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

# run_on_ok runs a remote command whose failure must not abort the gate, for
# teardown only; a delete of a rule that is not there is not an error.
run_on_ok() {
	run_on "$@" || true
	return 0
}

# teardown removes any client-ack mute rule this run may have left on nodes 2 or 3,
# looping the delete so it clears even a rule left by an earlier aborted run. It
# runs at start and from the exit trap, so a run killed midway never leaves a
# leader muted.
teardown() {
	local n
	for n in 2 3; do
		run_on_ok "$n" "while sudo iptables -D OUTPUT -d ${PRIV[1]} -p tcp --dport ${CLIENT_PORT} -j DROP 2>/dev/null; do :; done"
	done
}

# cleanup runs on every exit path: it unmutes, then emits the final verdict, and
# forces a non-zero exit whenever the run did not end all-pass, so a run that died
# partway or left a check without a verdict can never print success.
cleanup() {
	local rc=$?
	set +e
	teardown
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# ---- observation helpers (shape shared with retry.sh and checkquorum.sh) -----

# leader_role prints a node's last role line, empty if none yet.
leader_role() {
	run_on "$1" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1' 2>/dev/null || true
}

# role_line_count prints how many role lines a node has logged. The daemon logs a
# role line only on a change, so a count that does not move proves the node never
# changed role, which is what tells a held leader apart from one that flapped.
role_line_count() {
	local c
	c="$(run_on "$1" 'grep -cE "role=" naylamp/logs/node.log 2>/dev/null' 2>/dev/null || true)"
	printf '%s' "${c}" | tr -dc '0-9'
}

# find_leader prints the id of the node whose last role line reports leader, empty
# if none. A follower's last line is role=follower, so only a current leader
# matches. Every launch truncates the log, so within a phase this reads a live
# node's fresh line, never a stale one.
find_leader() {
	local n
	for n in "${NODE_IDS[@]}"; do
		case "$(leader_role "$n")" in *role=leader*) printf '%s' "$n"; return 0 ;; esac
	done
	return 1
}

# node_alive reports whether a node's daemon process is still running, read from
# the pidfile cluster.sh wrote. A healthy muted leader changes no role, so its log
# is static and a crashed process leaves the same static signature; only a live pid
# separates the two.
node_alive() {
	run_on "$1" 'pid=$(cat naylamp/naylampd.pid 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null'
}

# ceded_count prints how many role=follower leader=0 lines a node has logged. Every
# node logs one at boot (it starts a follower with no leader), so this reads one on
# a leader that never ceded and two or more once the muted leader steps down at its
# own term, the CheckQuorum step-down signature (leader=0 because an isolated egress
# heard no higher term). Each re-win and re-cede adds another, so a count above one
# is the proof of a step-down that the lone boot line cannot fake.
ceded_count() {
	local c
	c="$(run_on "$1" 'grep -cE "role=follower leader=0" naylamp/logs/node.log 2>/dev/null' 2>/dev/null || true)"
	printf '%s' "${c}" | tr -dc '0-9'
}

# leader_count prints how many role=leader lines a node has logged. A peer that
# takes the term after the muted leader steps down raises this above its pre-mute
# baseline, which is how the positive names the new leader without mistaking a peer
# that only led transiently during the relocation election for it.
leader_count() {
	local c
	c="$(run_on "$1" 'grep -cE "role=leader" naylamp/logs/node.log 2>/dev/null' 2>/dev/null || true)"
	printf '%s' "${c}" | tr -dc '0-9'
}

# wait_for_leader polls until some node reports leader, within the elect budget.
wait_for_leader() {
	local t=0
	while [ "${t}" -lt "${ELECT_TIMEOUT_S}" ]; do
		[ -n "$(find_leader || true)" ] && return 0
		sleep "${POLL_S}"; t=$((t + POLL_S))
	done
	return 1
}

# mute_installed confirms the client-ack DROP rule is present on a node, so no
# verdict is read off a mute that silently did not take.
mute_installed() {
	run_on "$1" "sudo iptables -C OUTPUT -d ${PRIV[1]} -p tcp --dport ${CLIENT_PORT} -j DROP 2>/dev/null"
}

# mute_pkts prints the packet counter of the client-ack DROP rule on a node, 0 if
# the rule is absent. -x prints exact counts, the hardware analog of the
# simulation's DroppedByEdge: a counter above zero proves the mute dropped real
# frames rather than merely being installed.
mute_pkts() {
	run_on "$1" "sudo iptables -L OUTPUT -v -n -x 2>/dev/null | awk '/DROP/ && /dpt:${CLIENT_PORT}/ {print \$1; exit}'" 2>/dev/null | tr -dc '0-9'
}

# field extracts the integer value of a key=NNN line from captured client output.
field() {
	printf '%s\n' "$2" | grep -oE "$1=[0-9]+" | tail -1 | cut -d= -f2
}

# ---- client wrappers --------------------------------------------------------

# group_natural prints the -group string in id order 1,2,3. With leadership on node
# 2 or 3, group[0] is node 1, a follower and the client's co-located host, so every
# fresh operation's first attempt is a healthy first contact that redirects, the
# same shape the simulation drives.
group_natural() {
	local g="" x
	for x in "${NODE_IDS[@]}"; do
		[ -n "$g" ] && g="${g},"
		g="${g}${x}=${PRIV[$x]}:${NODE_PORT}"
	done
	printf '%s' "$g"
}

# group_leader_first prints the -group string with the given leader listed first,
# so generation 0 of the single-operation client targets it directly.
group_leader_first() {
	local L="$1" g x
	g="${L}=${PRIV[$L]}:${NODE_PORT}"
	for x in "${NODE_IDS[@]}"; do
		if [ "$x" != "$L" ]; then
			g="${g},${x}=${PRIV[$x]}:${NODE_PORT}"
		fi
	done
	printf '%s' "$g"
}

# client_reach runs the service-health load on host 1 as id 90: one long-lived
# router with rotation on, ticked at the node cadence, re-issuing the write up to
# count times within the deadline. It prints the client output and appends exit=N.
client_reach() {
	local dl="$1" cnt="$2" group
	group="$(group_natural)"
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '${group}' -op put -id ${MARKER_ID} -vec ${VEC} -service-health -count ${cnt} -tick ${TICK_MS}ms -deadline ${dl}; echo exit=\$?" 2>&1
}

# client_single runs today's single-operation client (the feature off) on host 1,
# with the leader listed first and a deadline, and appends exit=N. This is the
# byte-identical default binary path the attribution and bite verdicts measure.
client_single() {
	local L="$1" dl="$2" group
	group="$(group_leader_first "$L")"
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '${group}' -op put -id ${MARKER_ID} -vec ${VEC} -deadline ${dl}; echo exit=\$?" 2>&1
}

# ---- cluster lifecycle ------------------------------------------------------

# wipe_hosts clears data and logs on all three hosts and recreates the empty dirs,
# so each phase reads a pristine cluster. The binary and certificates under
# naylamp/bin and naylamp/certs are left in place.
wipe_hosts() {
	local n
	for n in "${NODE_IDS[@]}"; do
		run_on_ok "$n" 'cd naylamp && rm -rf data logs && mkdir -p data logs'
	done
}

# ensure_leader_off_1 lands leadership on node 2 or 3 by redrawing the whole
# cluster, bounded, because the election is randomized and node 1 wins about one
# start in three. Node 1 co-locates the client and cannot be muted, so the muteable
# leader must be node 2 or 3. Node 1 re-winning a redraw is not assumed away: every
# redraw re-reads the fresh role line and redraws again until it lands or the bound
# is spent.
ensure_leader_off_1() {
	local tries=0 L
	L="$(find_leader || true)"
	while [ -z "${L}" ] || [ "${L}" = 1 ]; do
		tries=$((tries + 1))
		[ "${tries}" -le "${RESTART_TRIES}" ] || return 1
		note "leader is on node ${L:-none}; redrawing (attempt ${tries}) to land it on node 2 or 3"
		"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
		"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
		wait_for_leader || return 1
		sleep "${RELOCATE_SETTLE_S}"
		L="$(find_leader || true)"
	done
	return 0
}

# prepare_phase brings up a pristine cluster for one phase with the given extra node
# flags (empty for the default off, -service-health for on), then relocates
# leadership onto node 2 or 3. The flags reach the nodes through cluster.sh, which
# reads NAYLAMP_GATE_NODE_FLAGS. Returns non-zero if no leader lands off node 1.
prepare_phase() {
	local flags="$1"
	export NAYLAMP_GATE_NODE_FLAGS="${flags}"
	"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
	wipe_hosts
	"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
	wait_for_leader || return 1
	ensure_leader_off_1 || return 1
	return 0
}

# record_binary_digests reads the sha256 of the deployed naylampd on each host, so
# the hygiene guard can prove the fleet is homogeneous, the standing requirement of
# the wire bit that a prior build would reject.
record_binary_digests() {
	local n d
	SAME_BINARY=1
	FIRST_DIGEST=""
	for n in "${NODE_IDS[@]}"; do
		d="$(run_on "$n" 'sha256sum naylamp/bin/naylampd 2>/dev/null | cut -d" " -f1' 2>/dev/null | tr -dc '0-9a-f')"
		note "node ${n} naylampd sha256 ${d:-unknown}"
		if [ -z "${FIRST_DIGEST}" ]; then
			FIRST_DIGEST="${d}"
		fi
		if [ -z "${d}" ] || [ "${d}" != "${FIRST_DIGEST}" ]; then
			SAME_BINARY=0
		fi
	done
}

# ---- phases -----------------------------------------------------------------

# pre builds and deploys one binary to all three hosts, records its digest, and
# brings up a cluster with leadership relocated off node 1. A relocation that never
# lands aborts the whole run with a clear message rather than muting node 1.
pre() {
	note "SH.pre: homogeneous build and deploy, fresh cluster, leadership on node 2 or 3"
	"${GATE_DIR}/build.sh" || stop "SH.pre: build.sh failed; cannot run the gate"
	"${GATE_DIR}/deploy.sh" || stop "SH.pre: deploy.sh failed; cannot run the gate"
	record_binary_digests
	if [ "${SAME_BINARY}" -ne 1 ]; then
		stop "SH.pre: the three hosts do not carry the same naylampd; the fleet must be homogeneous before any verdict"
	fi
	if ! prepare_phase ""; then
		stop "SH.pre: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws; node 1 kept winning, so relocate leadership by hand and re-run"
	fi
	note "SH.pre: ready, leader is node $(find_leader)"
}

# bite proves the client-ack mute drops real traffic before any later verdict
# trusts it, reusing the red control of retry.sh: a write to the muted leader must
# fail and the DROP rule must count packets, which also settles that the TCP
# re-dial does not slip past the rule.
bite() {
	note "SH.bite: the client-ack mute must bite before any later verdict is trusted"
	if ! prepare_phase ""; then
		stop "SH.bite: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws"
	fi
	local L
	L="$(find_leader || true)"
	{ [ -n "$L" ] && [ "$L" != 1 ]; } || stop "SH.bite: no leader on node 2 or 3 to mute"
	note "SH.bite: leader is node ${L}; muting its ack path to the client"
	"${GATE_DIR}/partition.sh" mute "$L" >/dev/null
	if ! mute_installed "$L"; then
		stop "SH.bite: the mute rule is not present on node ${L} after applying it; the instrument failed to install"
	fi
	note "SH.bite: mute rule confirmed on node ${L}"

	begin_check
	local out ex pkts
	out="$(client_single "$L" "${BITE_DL}")"
	printf '%s\n' "${out}"
	ex="$(field exit "${out}")"
	pkts="$(mute_pkts "$L")"
	if [ "${ex:-}" = 1 ] && [ "${pkts:-0}" -gt 0 ]; then
		pass "SH.bite: a write to the muted leader ${L} gave exit ${ex} and the DROP rule counted ${pkts} packets, so the mute drops real client-ack traffic and a TCP re-dial does not slip past it"
	else
		fail "SH.bite: expected exit 1 with DROP packets above 0 (got exit=${ex:-none} pkts=${pkts:-0}); the mute did not bite, so no later verdict can be trusted"
	fi
	end_check SH.bite
	"${GATE_DIR}/partition.sh" unmute "$L" >/dev/null 2>&1 || true
}

# negative is the on-signal control on hardware: a healthy cluster, the feature on,
# no mute, a continuous load whose first contact lands on a follower at group[0].
# The leader must never cede over the load window and every operation must be
# served, the first-contact hysteresis holding as the simulation's negative control
# requires.
negative() {
	note "SH.negative: healthy cluster, feature on, no mute; the leader must never cede and every op is served"
	if ! prepare_phase "-service-health"; then
		stop "SH.negative: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws with the feature on"
	fi
	local L
	L="$(find_leader || true)"
	{ [ -n "$L" ] && [ "$L" != 1 ]; } || stop "SH.negative: no leader on node 2 or 3"
	local rc_before
	rc_before="$(role_line_count "$L")"
	note "SH.negative: leader is node ${L} (role lines ${rc_before:-0}); driving ${NEG_LOAD_S}s of continuous load"

	begin_check
	local out ex served attempted rc_after
	out="$(client_reach "${NEG_LOAD_S}s" "${LOAD_COUNT}")"
	printf '%s\n' "${out}"
	ex="$(field exit "${out}")"
	served="$(field served "${out}")"
	attempted="$(field attempted "${out}")"
	rc_after="$(role_line_count "$L")"
	# The load is deadline bound, so its last emitted operation is cut off before it
	# can resolve: served is attempted or attempted minus that one truncated op, never
	# fewer on a healthy cluster. Tolerate exactly that one, and require the rest served.
	if [ "${ex:-}" = 0 ] &&
		[ -n "${served}" ] && [ -n "${attempted}" ] && [ "${served}" -gt 0 ] && [ "$((attempted - served))" -le 1 ] &&
		[ "${rc_after:-0}" = "${rc_before:-0}" ] && node_alive "$L"; then
		pass "SH.negative: over ${NEG_LOAD_S}s the leader ${L} served every completed operation (${served}/${attempted}, at most one deadline-truncated) and never changed role (role lines held at ${rc_after}), so a healthy served leader is not unseated by the signal"
	else
		local alive
		alive="$(node_alive "$L" && echo yes || echo no)"
		fail "SH.negative: expected exit 0, served above 0 within one of attempted, and an unchanged role line count (got exit=${ex:-none} served=${served:-none} attempted=${attempted:-none} role lines ${rc_before:-0} to ${rc_after:-0} alive=${alive})"
	fi
	end_check SH.negative
}

# attribution is the off-signal measurement: the deployed default binary, under
# mute, no heal. The muted leader holds office for a generous window of the same
# order as the on-signal budget and the operation is never served, the status quo
# the positive is measured against.
attribution() {
	note "SH.attribution: feature off (the deployed default), under mute, no heal; the leader holds and the op is never served"
	if ! prepare_phase ""; then
		stop "SH.attribution: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws"
	fi
	local L
	L="$(find_leader || true)"
	{ [ -n "$L" ] && [ "$L" != 1 ]; } || stop "SH.attribution: no leader on node 2 or 3 to mute"
	local rc_before
	rc_before="$(role_line_count "$L")"
	note "SH.attribution: leader is node ${L} (role lines ${rc_before:-0}); muting its ack path"
	"${GATE_DIR}/partition.sh" mute "$L" >/dev/null
	if ! mute_installed "$L"; then
		stop "SH.attribution: the mute rule is not present on node ${L} after applying it"
	fi

	begin_check
	note "SH.attribution: holding one write against the muted leader for ${RETAIN_S}s with the feature off"
	local out ex rc_after pkts alive
	out="$(client_single "$L" "${RETAIN_S}s")"
	printf '%s\n' "${out}"
	ex="$(field exit "${out}")"
	rc_after="$(role_line_count "$L")"
	pkts="$(mute_pkts "$L")"
	alive="$(node_alive "$L" && echo yes || echo no)"
	if [ "${ex:-}" = 1 ] && [ "${rc_after:-0}" = "${rc_before:-0}" ] && [ "${alive}" = yes ] && [ "${pkts:-0}" -gt 0 ]; then
		pass "SH.attribution: with the feature off the muted leader ${L} held office for ${RETAIN_S}s (role lines unchanged at ${rc_after}, pid alive, DROP counted ${pkts} packets) and the write was never served (exit ${ex}), the measured status quo"
	else
		fail "SH.attribution: expected exit 1, an unchanged role line count, a live pid, and DROP packets above 0 (got exit=${ex:-none} role lines ${rc_before:-0} to ${rc_after:-0} alive=${alive} pkts=${pkts:-0})"
	fi
	end_check SH.attribution
	"${GATE_DIR}/partition.sh" unmute "$L" >/dev/null 2>&1 || true
}

# positive is the recovery verdict: the feature on, under mute, no heal, a
# continuous load. The muted leader cedes at its own term, a peer takes over, and
# the client is served within the eventual budget while the DROP rule stays
# installed and counts packets, the edge never healed. The mute is applied to the
# original leader and never lifted during the verdict; if it re-wins the election
# it released, it is muted again and cedes again, the eventual tail the budget
# covers.
positive() {
	note "SH.positive: feature on, under mute, no heal; the leader cedes, a peer serves the client, the edge never heals"
	if ! prepare_phase "-service-health"; then
		stop "SH.positive: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws with the feature on"
	fi
	local L n
	L="$(find_leader || true)"
	{ [ -n "$L" ] && [ "$L" != 1 ]; } || stop "SH.positive: no leader on node 2 or 3 to mute"
	local rc_before cede_before
	rc_before="$(role_line_count "$L")"
	cede_before="$(ceded_count "$L")"
	# Baseline the peers' leadership so a peer that only led during the relocation
	# election is not later mistaken for the new leader.
	local -a lead_base
	for n in "${NODE_IDS[@]}"; do
		lead_base[n]="$(leader_count "$n")"
	done
	note "SH.positive: leader is node ${L} (role lines ${rc_before:-0}, cedes ${cede_before:-0}); muting its ack path, then driving up to ${SERVICE_BUDGET_S}s of continuous load"
	"${GATE_DIR}/partition.sh" mute "$L" >/dev/null
	if ! mute_installed "$L"; then
		stop "SH.positive: the mute rule is not present on node ${L} after applying it"
	fi

	begin_check
	local out ex served rc_after cede_after newl="" pkts ok=1
	out="$(client_reach "${SERVICE_BUDGET_S}s" "${LOAD_COUNT}")"
	printf '%s\n' "${out}"
	ex="$(field exit "${out}")"
	served="$(field served "${out}")"
	rc_after="$(role_line_count "$L")"
	cede_after="$(ceded_count "$L")"
	pkts="$(mute_pkts "$L")"
	for n in "${NODE_IDS[@]}"; do
		[ "$n" = "$L" ] && continue
		if [ "$(leader_count "$n")" -gt "${lead_base[n]:-0}" ]; then
			newl="$n"
			break
		fi
	done
	[ "${ex:-}" = 0 ] || { fail "SH.positive: the client was never served (exit ${ex:-none}); no operation completed within ${SERVICE_BUDGET_S}s"; ok=0; }
	[ "${cede_after:-0}" -gt "${cede_before:-0}" ] || { fail "SH.positive: node ${L} logged no new role=follower leader=0 (cedes ${cede_before:-0} to ${cede_after:-0}); the muted leader did not step down"; ok=0; }
	[ "${rc_after:-0}" -gt "${rc_before:-0}" ] || { fail "SH.positive: node ${L} role line count did not move (${rc_before:-0} to ${rc_after:-0}); no role change observed"; ok=0; }
	[ -n "${newl}" ] || { fail "SH.positive: no peer other than ${L} took the term after the step-down"; ok=0; }
	mute_installed "$L" || { fail "SH.positive: the DROP rule on ${L} was gone at ack time; the edge was healed during the verdict"; ok=0; }
	[ "${pkts:-0}" -gt 0 ] || { fail "SH.positive: the DROP rule on ${L} counted 0 packets; the mute did not bite during the verdict"; ok=0; }
	if [ "${ok}" -eq 1 ]; then
		pass "SH.positive: the muted leader ${L} ceded to role=follower leader=0 (cedes ${cede_before:-0} to ${cede_after:-0}), node ${newl} took the term, and the client was served (exit ${ex}, ${served}) within ${SERVICE_BUDGET_S}s while the DROP rule stayed installed and counted ${pkts} packets, the edge never healed"
	fi
	end_check SH.positive
	"${GATE_DIR}/partition.sh" unmute "$L" >/dev/null 2>&1 || true
}

# hygiene is the closing guard: the mute rules are removed, iptables is clean on
# the muteable nodes, and the three hosts ran one binary.
hygiene() {
	note "SH.hygiene: rules removed, iptables clean on nodes 2 and 3, one binary across the fleet"
	begin_check
	teardown
	local n clean=1 leftover=""
	for n in 2 3; do
		if mute_installed "$n"; then
			clean=0
			leftover="${leftover} ${n}"
		fi
	done
	if [ "${clean}" -eq 1 ] && [ "${SAME_BINARY}" = 1 ] && [ -n "${FIRST_DIGEST}" ]; then
		pass "SH.hygiene: no client-ack DROP rule remains on nodes 2 or 3, and all three hosts ran the same naylampd (sha256 ${FIRST_DIGEST})"
	else
		fail "SH.hygiene: a mute rule remained on node(s)${leftover:- none}, or the fleet was not homogeneous (same_binary=${SAME_BINARY} digest=${FIRST_DIGEST:-none})"
	fi
	end_check SH.hygiene
}

# ---- dispatch ---------------------------------------------------------------

teardown

cmd="${1:-all}"
case "$cmd" in
	all)
		note "budgets: tick=${TICK_MS}ms window=${ELECTION_TICKS}t/${WINDOW_MS}ms hysteresis=${HYST_WINDOWS}win/${HYST_MS}ms rotate=${ROTATE_TIMEOUTS}x${RETRANSMIT_TICKS}t/${ROTATE_MS}ms; bite=${BITE_DL} negative=${NEG_LOAD_S}s retain=${RETAIN_S}s service=${SERVICE_BUDGET_S}s"
		EXPECTED="SH.bite SH.negative SH.attribution SH.positive SH.hygiene"
		pre
		bite
		negative
		attribution
		positive
		hygiene
		COMPLETED=1
		;;
	heal)
		note "removed any client-ack mute rule left on nodes 2 and 3"
		;;
	*)
		echo "usage: servicehealth.sh <all|heal>" >&2
		exit 2
		;;
esac
