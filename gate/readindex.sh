#!/usr/bin/env bash
# readindex.sh: prove on the three real hosts that a linearizable read is served
# only after the leader confirms its leadership with a majority read-index round,
# and is withheld when that round cannot complete. This is Subphase 4.3, the read
# path of the engine.
#
# THE PROPERTY. A client search is a linearizable read. The node registers it
# with RequestRead, which captures the current commit as the read index and sends
# an append round carrying a read context to the followers; confirmRead delivers
# the read only after a majority answers that round, and the node serves the
# search only once the applied state has reached the read index (see
# engine/naylamp/node.go beginClientSearch and the parked-search serving loop, and
# engine/raft/raft.go RequestRead and confirmRead).
#
# THE DIRECT SIGNAL. A read confirms only after a majority answered its round, so
# the daemon logs "readindex ctx=<c> index=<i>" the moment a confirmed read's
# context rises (see the ticker in engine/cmd/naylampd/node.go). A new readindex
# line is therefore direct evidence that the majority round completed. The gate
# reads it, not just the served-or-not consequence, so the verdict is tied to the
# read-index round itself and not to the wider loss of majority.
#
#   green     with the majority intact, a client search is served (exit 0) AND a
#             new readindex line appears: the majority round confirmed and the
#             read was answered. That pairing is the verdict RI.green.
#   red       with the leader cut off from its majority, the same search is NOT
#             served (exit 1) AND no new readindex line appears: the read-index
#             round never confirmed, so the read was withheld for the specific
#             reason 4.3 promises. That absence is the verdict RI.red.
#   negative  a healthy cluster with no partition serves the read (exit 0) and
#             logs its readindex line, the control that keeps the instrument honest.
#
# Usage: readindex.sh
#
# This script never builds or deploys; it assumes cluster.sh start has run. It
# ensures the leader sits on node 1 first, because the client is co-located with
# node 1 on host 1 (see gate/README.md): only a node-1 leader can be cut from its
# peers while the co-located client still reaches it. Any isolation this run
# installs is healed from the exit trap on every path.
#
# WHY THE READINDEX LINE, NOT A SHORTER DEADLINE. On a three node cluster the
# majority the read-index round needs is the same majority CheckQuorum watches, so
# cutting the leader from both peers stalls the read round at once and demotes the
# leader about two windows later. Racing a short read deadline to catch the round
# stall before the demotion is not reliable at ssh and second resolution. The
# readindex line removes the race: it is emitted only on a confirmed majority
# round, so its ABSENCE during the isolation witnesses that the round never
# confirmed, whether or not the node has demoted yet. The red is tied to the round,
# not to the demotion, so the deadline stays generous.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

# Timing, derived like checkquorum.sh from the tick period and the election
# window so the numbers are explicit. The CheckQuorum demote bound is about three
# election windows; the settle waits sit well above it.
TICK_MS=10
ELECTION_TICKS=10
DEMOTE_BOUND_MS=$(( 3 * ELECTION_TICKS * TICK_MS ))
ELECT_TIMEOUT_S=15     # poll budget for a leader to appear after a restart
SETTLE_S=5             # let a role change and its readindex line settle in the log
READ_DEADLINE=8s       # the client's own budget for one linearizable read
RESTART_TRIES=8        # bounded redraws of leadership until node 1 wins

# Verdict registry, the same mechanism tls.sh and checkquorum.sh use.
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0

note() { echo "gate: $*"; }
pass() { echo "gate: PASS $*"; }
stop() { echo "gate: STOP $*" >&2; exit 1; }
fail() { echo "gate: FAIL $*" >&2; CHECK_FAILED=1; }
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
# run completed and every expected check registered pass.
emit_final_verdict() {
	local id v bad=""
	for id in ${EXPECTED}; do
		v="$(verdict_of "${id}")"
		printf 'gate: verdict %s = %s\n' "${id}" "${v}" >&2
		if [ "${v}" != pass ]; then bad="${bad} ${id}"; fi
	done
	if [ "${COMPLETED}" -ne 1 ]; then
		echo "gate: NOT A SUCCESS; the run did not reach a clean completion" >&2
		return 1
	fi
	if [ -n "${bad}" ]; then
		echo "gate: NOT A SUCCESS; checks without a passing verdict:${bad}" >&2
		return 1
	fi
	echo "gate: SUCCESS; every expected check passed" >&2
	return 0
}

# heal_node1 removes any peer isolation on node 1, looping each delete with the
# error suppressed so an absent or duplicated rule never aborts. It matches the
# shape checkquorum.sh teardown uses, and it does NOT delegate to partition.sh
# heal, whose bare iptables -D under set -e would stop on the first absent rule
# and leave a partially installed apply in place. Used at start, in the red, and
# from the exit trap, so a partial apply can never leave a lingering DROP.
heal_node1() {
	local x
	for x in 2 3; do
		run_on 1 "while sudo iptables -D INPUT -s ${PRIV[$x]} -j DROP 2>/dev/null; do :; done; while sudo iptables -D OUTPUT -d ${PRIV[$x]} -j DROP 2>/dev/null; do :; done" >/dev/null 2>&1 || true
	done
	return 0
}

# cleanup runs on every exit path: heal any peer isolation, then emit the verdict
# and force a non-zero exit if the run did not end all-pass.
cleanup() {
	local rc=$?
	set +e
	heal_node1
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# leader_role prints a node's last role line, empty if none yet.
leader_role() {
	run_on "$1" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1' 2>/dev/null || true
}
role_of() { leader_role "$1" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true; }

# readindex_count prints how many readindex lines a node has logged, reduced to
# digits so ssh noise cannot masquerade as a count. A count that rises across a
# read means a majority round confirmed; a count that holds means none did.
readindex_count() {
	local c
	c="$(run_on "$1" 'grep -cE "readindex " naylamp/logs/node.log 2>/dev/null' 2>/dev/null || true)"
	printf '%s' "${c}" | tr -dc '0-9'
}

# find_leader prints the id of the node whose last role line reports leader, empty
# if none.
find_leader() {
	local n
	for n in "${NODE_IDS[@]}"; do
		case "$(leader_role "$n")" in *role=leader*) printf '%s' "$n"; return 0 ;; esac
	done
	return 1
}

# wait_for_leader polls until some node reports leader, within the elect budget.
wait_for_leader() {
	local t=0
	while [ "${t}" -lt "${ELECT_TIMEOUT_S}" ]; do
		[ -n "$(find_leader || true)" ] && return 0
		sleep 1; t=$((t + 1))
	done
	return 1
}

# ensure_leader_1 lands leadership on node 1 by redrawing it with a full cluster
# restart, bounded, because the election is randomized and node 1 wins about one
# start in three. A node-1 leader is the only one the co-located client can still
# reach once its peers are cut, which is what the red needs.
ensure_leader_1() {
	local tries=0 L
	L="$(find_leader || true)"
	while [ "${L}" != 1 ]; do
		tries=$((tries + 1))
		[ "${tries}" -le "${RESTART_TRIES}" ] || return 1
		note "leader is on node ${L:-none}; redrawing (attempt ${tries}) to land it on node 1"
		"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
		"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
		wait_for_leader || return 1
		sleep "${SETTLE_S}"
		L="$(find_leader || true)"
	done
	return 0
}

# client_op runs one one-shot client operation on host 1, dialing the group, and
# appends exit=<code>. It mirrors the wrapper tls.sh uses. The client exits 0 only
# when the operation returned StatusOK, and 1 on any refusal or timeout, so the
# exit code alone is the served-or-not signal.
client_op() {
	local group="1=${PRIV[1]}:${NODE_PORT},2=${PRIV[2]}:${NODE_PORT},3=${PRIV[3]}:${NODE_PORT}"
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '${group}' $* ; echo exit=\$?" 2>&1
}

# served reports whether a client op output ended in exit=0.
served() { printf '%s' "$1" | grep -q 'exit=0$'; }
# refused reports whether it ended in exit=1, a clean no-result, not a load error.
refused() { printf '%s' "$1" | grep -q 'exit=1$'; }

# ---- precondition -----------------------------------------------------------

precondition() {
	note "RI.pre: cluster of three healthy, leader relocated onto node 1, seed written, one linearizable read served"
	begin_check
	wait_for_leader || stop "RI.pre: no leader; run cluster.sh start and wait until cluster.sh status shows a leader"
	if ! ensure_leader_1; then
		stop "RI.pre: could not land leadership on node 1 within ${RESTART_TRIES} redraws; the co-located client can only reach a node-1 leader once its peers are cut, so the red cannot run"
	fi
	note "RI.pre: leader is node $(find_leader)"
	local put_out
	put_out="$(client_op -op put -id 1 -vec 1,0,0 -deadline 20s)"
	printf '%s\n' "${put_out}"
	served "${put_out}" || stop "RI.pre: the seed write did not commit (no exit=0); the cluster is not serving, so a read test would mean nothing"
	local base_out
	base_out="$(client_op -op search -vec 1,0,0 -k 1 -deadline "${READ_DEADLINE}")"
	printf '%s\n' "${base_out}"
	if served "${base_out}"; then
		pass "RI.pre: a linearizable read was served on the healthy cluster; the read path is live"
	else
		fail "RI.pre: a linearizable read was not served on the healthy cluster; the instrument is not ready"
	fi
	end_check RI.pre
}

# ---- green ------------------------------------------------------------------

green() {
	note "RI.green: with the majority intact, a linearizable read is served and a new readindex line appears, so the majority round confirmed before the answer"
	begin_check
	local ri_before ri_after out
	ri_before="$(readindex_count 1)"
	out="$(client_op -op search -vec 1,0,0 -k 1 -deadline "${READ_DEADLINE}")"
	printf '%s\n' "${out}"
	sleep "${SETTLE_S}"
	ri_after="$(readindex_count 1)"
	if served "${out}" && [ "${ri_after:-0}" -gt "${ri_before:-0}" ]; then
		pass "RI.green: the read was served (exit=0) and node 1 logged a new readindex line (${ri_before} -> ${ri_after}); the majority read-index round confirmed and only then was the read answered"
	elif ! served "${out}"; then
		fail "RI.green: the read was not served on a healthy majority (no exit=0); either the cluster lost its leader or the read path is broken"
	else
		fail "RI.green: the read was served but no new readindex line appeared (${ri_before} -> ${ri_after}); the served read is not witnessed by a confirmed majority round, so the instrument cannot attest the property"
	fi
	end_check RI.green
}

# ---- red --------------------------------------------------------------------

red() {
	note "RI.red: with node 1 cut from its majority, the read is withheld AND no new readindex line appears, so the round never confirmed"
	begin_check
	local L
	L="$(find_leader || true)"
	if [ "${L}" != 1 ]; then
		fail "RI.red: leadership left node 1 before the cut (leader ${L:-none}); rerun so the client can reach the isolated leader"
		end_check RI.red
		return
	fi
	local before after ri_before ri_after out
	before="$(role_of 1)"
	"${GATE_DIR}/partition.sh" apply 1
	ri_before="$(readindex_count 1)"
	note "RI.red: node 1 isolated from nodes 2 and 3; issuing the read while it still holds office (demote bound about ${DEMOTE_BOUND_MS}ms)"
	out="$(client_op -op search -vec 1,0,0 -k 1 -deadline "${READ_DEADLINE}")"
	printf '%s\n' "${out}"
	sleep "${SETTLE_S}"
	ri_after="$(readindex_count 1)"
	after="$(role_of 1)"
	if refused "${out}" && [ "${ri_after:-0}" -eq "${ri_before:-0}" ]; then
		pass "RI.red: the read was withheld (exit=1) and node 1 logged NO new readindex line (${ri_before} -> ${ri_after}), so the read-index round never confirmed. Node 1 role before=${before}, after=${after}: the absence of a confirmed round is the verdict, independent of whether the node has demoted"
	elif [ "${ri_after:-0}" -gt "${ri_before:-0}" ]; then
		fail "RI.red: a readindex line appeared while node 1 was cut from its majority (${ri_before} -> ${ri_after}); a read-index round confirmed without a reachable majority, which is a linearizability regression"
	elif served "${out}"; then
		fail "RI.red: the read was SERVED while node 1 was cut from its majority (exit=0); a linearizable read was answered without a confirmable quorum, which is a linearizability regression"
	else
		fail "RI.red: the read attempt exited neither 0 nor 1; a load or argument error, not a clean refusal, inspect the output"
	fi
	heal_node1
	end_check RI.red
}

# ---- negative control -------------------------------------------------------

negative() {
	note "RI.negative: after heal, a healthy cluster serves the read and logs its readindex line again, so the red came from the partition and not from a broken read path"
	begin_check
	wait_for_leader || { fail "RI.negative: no leader after heal within ${ELECT_TIMEOUT_S}s"; end_check RI.negative; return; }
	sleep "${SETTLE_S}"
	local ri_before ri_after out lead
	lead="$(find_leader || true)"
	ri_before="$(readindex_count "${lead}")"
	out="$(client_op -op search -vec 1,0,0 -k 1 -deadline "${READ_DEADLINE}")"
	printf '%s\n' "${out}"
	sleep "${SETTLE_S}"
	ri_after="$(readindex_count "${lead}")"
	if served "${out}" && [ "${ri_after:-0}" -gt "${ri_before:-0}" ]; then
		pass "RI.negative: the healed cluster served the read again (exit=0) and leader node ${lead} logged a new readindex line (${ri_before} -> ${ri_after}); the withholding was the partition, not the instrument"
	else
		fail "RI.negative: the healed cluster did not serve the read with a fresh readindex line (exit served=$(served "${out}" && echo yes || echo no), ${ri_before} -> ${ri_after}); the red is not attributable to the partition alone"
	fi
	end_check RI.negative
}

# ---- main -------------------------------------------------------------------

EXPECTED="RI.pre RI.green RI.red RI.negative"
heal_node1
precondition
green
red
negative
COMPLETED=1
