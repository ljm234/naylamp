#!/usr/bin/env bash
# checkquorum.sh: prove on the three real hosts the red/green pair of the leader
# quorum check. It isolates the leader from its two peers with partition.sh apply
# and reads the outcome from each node's role log:
#
#   red    with the old binary (pre-quorum-check, commit d19bb19) an isolated
#          leader stays a mute leader: its last role line stays role=leader and no
#          new role transition appears, so it holds its term with no way to recover.
#          That standing phenomenon is the verdict CQ.red.
#   green  with the new binary (HEAD 8f01feb) the same isolation makes the old
#          leader step down to role=follower leader=0 within the bound (CQ.demote),
#          the majority elects a new leader while the partition is still live
#          (CQ.elect), and after heal the old leader rejoins as a follower of that
#          new leader (CQ.rejoin). A healthy cluster with no partition never
#          degrades (CQ.negative), the negative control that keeps the instrument
#          honest.
#
# Usage: checkquorum.sh <red|green>
#
# The two subcommands are separate on purpose: red runs against the old binary and
# green against the new one, so an operator deploys the old binary, runs red, then
# deploys the new binary and runs green. This script never builds or deploys; it
# assumes cluster.sh start has run and a leader has been elected, the same
# precondition tls.sh carries.
#
# TERM NOTE. Whether a term field is in the log depends on the build, so this
# script never reads one. The daemon began printing role=, leader= and term=
# together in dca7e2b; both binaries this gate is pointed at are older than that,
# the red arm's d19bb19 and the green arm's 8f01feb, so neither prints a term at
# all. And even on a current daemon a term is only ever visible AT a role or
# leader transition, because node.go deliberately does not log a term that
# advances on its own (see the comment on that condition). So a term-keyed check
# would read nothing on the pinned builds and, on a newer one, would still be
# reading transitions with extra steps.
#
# Term equality and term growth are therefore derived from the role and leader
# transitions, which name both facts unambiguously:
#   same term    the isolated leader drops to role=follower leader=0. It is cut
#                off from both peers, so it cannot have heard a higher term; the
#                only path from leader to follower under isolation is the quorum
#                check calling becomeFollower at the same term with leader None.
#                Adopting a higher-term leader would instead read leader=<id>.
#   higher term  a new role=leader appears on a different node. A node becomes
#                leader only by winning an election, which increments the term, so
#                a new leader is at a term above the old leader's.
# A literal term field is worth having in the evidence and is not what these
# verdicts read. A run against a daemon at dca7e2b or later prints one on every
# role line; the verdicts are unchanged by its presence or absence, which is what
# lets the same assertions grade an old binary and a new one.
#
# BOUND. The nodes tick every 10ms (cluster.sh launches naylampd with -tick 10ms;
# the flag default is also 10ms). With ElectionTicks=10 a window is 100ms, and the
# two-window hysteresis plus the boundary window degrades in about 30 ticks, near
# 300ms; the simulation measured about 22 ticks. SETTLE_S waits well above three
# times that bound, widened for ssh and log-flush latency on real hosts.
#
# It adds no engine code and no wire surface. Any isolation this run installs is
# healed from the exit trap on every path.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

# Timing. BOUND_MS is the expected degrade time from the tick period and the
# election window; the waits are derived from it so the numbers are explicit.
TICK_MS=10
ELECTION_TICKS=10
HYST_WINDOWS=2
BOUND_TICKS=$(( (HYST_WINDOWS + 1) * ELECTION_TICKS ))
BOUND_MS=$(( BOUND_TICKS * TICK_MS ))
SETTLE_S=10            # about 33x the 300ms bound; the red hold and the negative control
DEMOTE_TIMEOUT_S=15    # poll budget for the green step-down (true bound is sub-second)
ELECT_TIMEOUT_S=15     # poll budget for the majority to elect a new leader
CONVERGE_TIMEOUT_S=30  # poll budget for reconvergence after heal
POLL_S=1

# Verdict registry, the same mechanism tls.sh uses. record_verdict is called once
# per check. EXPECTED is the set the subcommand must pass; COMPLETED is set only
# after the last check; CHECK_FAILED is the per-check flag fail() raises.
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0
WAITED=0

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
# trap owns the exit code and the local demonstration can exercise it.
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
# teardown only: a delete of a rule that is not there is not an error.
run_on_ok() {
	run_on "$@" || true
	return 0
}

# teardown removes any peer isolation this run may have left on any node, looping
# the delete so it clears even duplicate rules from an earlier aborted run. It runs
# at start and from the exit trap, so a run killed mid-partition never leaves a
# node isolated.
teardown() {
	local n x
	for n in "${NODE_IDS[@]}"; do
		for x in "${NODE_IDS[@]}"; do
			if [ "$x" != "$n" ]; then
				run_on_ok "$n" "while sudo iptables -D INPUT -s ${PRIV[$x]} -j DROP 2>/dev/null; do :; done; while sudo iptables -D OUTPUT -d ${PRIV[$x]} -j DROP 2>/dev/null; do :; done"
			fi
		done
	done
}

# cleanup runs on every exit path: it heals, then emits the final verdict, and
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

# leader_role prints a node's last role line, empty if none yet. It returns 2
# when the read cannot be made whole; polls ignore that and treat it as "not
# yet", which costs them a timeout at worst, while verdicts check the status.
leader_role() {
	local out
	out="$(read_on "$1" "0 1" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1')" || return 2
	printf '%s' "${out}"
}

# role_of prints the role word (follower, candidate, or leader) of a node's last
# role line; leaderfield_of prints the leader= id of that same line. Both reduce
# to the exact field so ssh noise cannot masquerade as a value.
role_of() { leader_role "$1" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true; }
leaderfield_of() { leader_role "$1" | grep -oE 'leader=[0-9]+' | tail -1 | cut -d= -f2 || true; }

# role_line_count prints how many role lines a node has logged. The daemon logs a
# role line only on a change, so a count that does not move across the wait proves
# the node never changed role. That is what rules out a leadership flap (leader
# lost and regained), not just a final still-leader. It returns 2 when the count
# cannot be read: the old form collapsed an unanswered ssh to the empty string,
# and two empty strings compare equal, which passed the no-flap check on data
# nobody read (DEFER-072). grep exits 1 when the log has no role line yet, a
# valid 0; any other read failure is not.
role_line_count() {
	local c
	c="$(read_on "$1" "0 1" 'grep -cE "role=" naylamp/logs/node.log 2>/dev/null')" || return 2
	printf '%s' "${c}" | tr -dc '0-9'
}

# find_leader answers with THREE values, and the third is the point: 0 it prints
# the id of the node whose last role line reports leader, 1 no node reports it
# and every host was read, 2 no node reports it AND at least one host could not
# be read. A follower's last line is role=follower, so only a current leader
# matches. The contract is written here and not only inside the body, because a
# header that describes a return contract wrongly is what aligns a caller
# against something that is not there.
find_leader() {
	local n rl unread=0
	for n in "${NODE_IDS[@]}"; do
		# THE ROLE LINE IS READ WITH ITS THIRD VALUE. leader_role here has gone
		# through read_on since before the others did, so it has been returning 2
		# for an unreadable host all along, and this loop was throwing that 2 away
		# in a command substitution: an unreadable node and a follower produced the
		# same answer. This file was cited as the model the other four copied, and
		# it carried the defect the copy was meant to close.
		if ! rl="$(leader_role "$n")"; then
			echo "gate: find_leader: node ${n} could not be read and is skipped; that is not the same as not being leader" >&2
			unread=1
			continue
		fi
		case "${rl}" in *role=leader*) printf '%s' "$n"; return 0 ;; esac
	done
	# AND THE THIRD VALUE IS CARRIED OUT, not just announced. A loop that skipped
	# an unreadable node and then returned the same 1 as a loop that read all
	# three left the caller unable to tell "there is no leader" from "one of the
	# three could not be looked at", which is the DEFER-072 collapse one floor up
	# from the one this function already closed.
	if [ "${unread}" -eq 1 ]; then
		return 2
	fi
	return 1
}

# Liveness is alive_on from common.sh, the three-valued form; the local
# node_alive is gone. Its reason stands: this is what tells a mute leader apart
# from a crash, because a healthy mute leader changes no role and a crashed
# process leaves the same static signature; only a live pid separates the two.
# The old probe also returned the ssh 255 of a dead transport as "dead", the
# DEFER-072 collapse in the closed direction, and unreadable now gets named.

# partition_installed confirms the DROP rules toward BOTH peers are present on a
# node in BOTH directions, so a red or a demote is never read off an apply that
# silently did not take.
partition_installed() {
	local n="$1" x
	for x in "${NODE_IDS[@]}"; do
		[ "$x" = "$n" ] && continue
		run_on "$n" "sudo iptables -C INPUT -s ${PRIV[$x]} -j DROP 2>/dev/null" || return 1
		run_on "$n" "sudo iptables -C OUTPUT -d ${PRIV[$x]} -j DROP 2>/dev/null" || return 1
	done
	return 0
}

# cluster_converged reports whether exactly one node is leader and every node's
# leader field names it, the shape of a settled cluster.
# cluster_converged answers with THREE values, and the third is why this was
# rewritten: 0 exactly one node reports leader and all three name it, 1 that is
# not what the fleet reports, and 2 a host could not be read so the question was
# not answered. It used to go through role_of and leaderfield_of, which flatten
# an unreadable host to the empty string, so an unreadable node made this return
# 1, "not converged", about a fleet that may well be converged. That 1 travelled
# up through wait_converged into a note that ASSERTS the cluster did not
# reconverge, in a run whose only verdict is registered before it: a false line
# inside a green artifact, which is the shape DEFER-072 is about. The reads go
# through leader_role, which carries the third value, and each node is read ONCE
# for both fields rather than twice.
cluster_converged() {
	local n L="" leadcount=0 rl role lf
	local -a lines=()
	for n in "${NODE_IDS[@]}"; do
		rl="$(leader_role "$n")" || return 2
		lines[n]="${rl}"
		role="$(printf '%s' "${rl}" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true)"
		if [ "${role}" = leader ]; then
			leadcount=$((leadcount + 1))
			L="$n"
		fi
	done
	[ "${leadcount}" -eq 1 ] || return 1
	for n in "${NODE_IDS[@]}"; do
		lf="$(printf '%s' "${lines[n]}" | grep -oE 'leader=[0-9]+' | tail -1 | cut -d= -f2 || true)"
		[ "${lf}" = "${L}" ] || return 1
	done
	return 0
}

# wait_converged polls cluster_converged until it holds or the budget runs out.
# wait_converged carries cluster_converged's third value out to its callers, and
# it does NOT give up on the first unreadable answer: it keeps polling to the
# budget, because a host that is unreadable now may answer on the next turn, and
# only reports 2 if the budget ran out with a read still missing. So 1 means the
# fleet said it is not converged and 2 means nobody could tell.
wait_converged() {
	local timeout="$1" start now rc unread=0
	start=$(date +%s)
	while :; do
		rc=0
		cluster_converged || rc=$?
		if [ "${rc}" -eq 0 ]; then
			return 0
		fi
		# EL PESTILLO DESCRIBE LA ULTIMA LECTURA Y NO EL HISTORIAL. Dejandolo
		# pegado, una sola lectura ilegible en la primera vuelta tenia el
		# veredicto de todo el presupuesto aunque las siguientes leyeran los
		# tres hosts y dijeran que no converge, y eso es esta misma clase del
		# reves: decir que no se pudo saber cuando si se pudo.
		if [ "${rc}" -eq 2 ]; then
			unread=1
		else
			unread=0
		fi
		now=$(date +%s)
		if [ $(( now - start )) -ge "${timeout}" ]; then
			if [ "${unread}" -eq 1 ]; then
				return 2
			fi
			return 1
		fi
		sleep "${POLL_S}"
	done
}

# wait_role_leader polls a node until its last role line reports the wanted role
# and, when a leader field is given, that exact leader id. It sets WAITED to the
# elapsed seconds so a caller can report how long the transition took.
wait_role_leader() {
	local node="$1" want_role="$2" want_lf="$3" timeout="$4" start now
	start=$(date +%s)
	while :; do
		if [ "$(role_of "${node}")" = "${want_role}" ] && { [ -z "${want_lf}" ] || [ "$(leaderfield_of "${node}")" = "${want_lf}" ]; }; then
			WAITED=$(( $(date +%s) - start ))
			return 0
		fi
		now=$(date +%s)
		if [ $(( now - start )) -ge "${timeout}" ]; then WAITED=$(( now - start )); return 1; fi
		sleep "${POLL_S}"
	done
}

# assert_stays_leader waits over a settle window and passes only if the node is
# still leader with no new role line, the shared no-degrade check of red and the
# negative control. Every read it makes is three-valued now: an unread count, an
# unread role or an unreadable host is named as unreadable, and none of them can
# pass, because two empty strings comparing equal is the DEFER-072 collapse and
# not evidence of a quiet leader.
assert_stays_leader() {
	local node="$1" seconds="$2" id="$3" why="$4" before after counts_ok=1
	before="$(role_line_count "${node}")" || counts_ok=0
	note "waiting ${seconds}s (at least 3x the ~${BOUND_MS}ms bound) to watch node ${node} for a degradation"
	sleep "${seconds}"
	after="$(role_line_count "${node}")" || counts_ok=0
	local roleline role="" role_ok=1
	roleline="$(leader_role "${node}")" || role_ok=0
	role="$(printf '%s' "${roleline}" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true)"
	note "node ${node} last role line: ${roleline}"
	note "node ${node} role-line count before=${before:-unread} after=${after:-unread}"
	begin_check
	local alive_rc=0
	alive_on "${node}" || alive_rc=$?
	if [ "${counts_ok}" -ne 1 ]; then
		fail "${id}: the role-line count on node ${node} could not be read; a no-degradation claim cannot be attested on an unread count"
	elif [ "${alive_rc}" -eq 2 ]; then
		fail "${id}: liveness on node ${node} could not be read; a node nobody can reach is not the phenomenon and is not a pass"
	elif [ "${alive_rc}" -eq 1 ]; then
		fail "${id}: the daemon on node ${node} is not running; a crashed process leaves the same static role log as a mute leader, so liveness is checked explicitly and a dead node is not the phenomenon"
	elif [ "${role_ok}" -ne 1 ]; then
		fail "${id}: the role of node ${node} could not be read; a still-leader claim cannot be attested either way"
	elif [ "${role}" = leader ] && [ "${after}" = "${before}" ]; then
		pass "${id}: ${why}"
	else
		fail "${id}: node ${node} changed role or emitted new role lines (role=${role:-none}, count ${before} -> ${after})"
	fi
	end_check "${id}"
}

# LEADER and BASE_COUNT are the F0 baseline: the leader id and its role-line count.
LEADER=""
BASE_COUNT=0

# precondition (F0) requires a converged cluster of three with one leader, and
# captures the baseline. The baseline is the leader id and its role-line count
# rather than a term, because the term is not read from the log at all; see the
# header for why, and for how equality and growth come from the transitions.
precondition() {
	note "F0 precondition: cluster of three healthy, one leader elected, baseline captured"
	local n
	for n in "${NODE_IDS[@]}"; do
		# Liveness is asserted alongside the role line, not inferred from it. The
		# node log is appended to rather than truncated at launch, so a host whose
		# daemon failed to come up still carries the role line of an earlier run
		# and would satisfy a check that only asks whether a line exists. Reading
		# the pid says whether the process is there now.
		local alive_rc=0
		alive_on "$n" || alive_rc=$?
		if [ "${alive_rc}" -eq 2 ]; then
			stop "F0: node ${n} could not be read; an unreadable node is not a dead one, and the run stops here either way"
		fi
		if [ "${alive_rc}" -eq 1 ]; then
			stop "F0: node ${n} is not running; run cluster.sh start and wait until cluster.sh status shows a leader"
		fi
		# AND THE ROLE LINE IS READ WITH ITS THIRD VALUE TOO, which is what made
		# the branch further down nearly unreachable: role_of flattens an
		# unreadable host to the empty string, so a host that is ALIVE with an
		# unreadable log stopped the run HERE, saying it has no role line yet,
		# about a node nobody could read. alive_on above already separates dead
		# from unreadable; this line did not, one probe later.
		local rl0 rl0rc=0
		rl0="$(leader_role "$n")" || rl0rc=$?
		if [ "${rl0rc}" -ne 0 ]; then
			stop "F0: node ${n} answers alive but its role line could not be read, so whether it has one is not known; make the three hosts readable before this gate"
		fi
		[ -n "${rl0}" ] || stop "F0: node ${n} has no role line yet; run cluster.sh start and wait until cluster.sh status shows a leader"
	done
	local f0wc=0
	wait_converged "${CONVERGE_TIMEOUT_S}" || f0wc=$?
	if [ "${f0wc}" -eq 2 ]; then
		stop "F0: whether the cluster converged on a single leader could not be told within ${CONVERGE_TIMEOUT_S}s because a host could not be read; run cluster.sh status and make the three hosts readable before this gate"
	elif [ "${f0wc}" -ne 0 ]; then
		stop "F0: cluster did not converge on a single leader within ${CONVERGE_TIMEOUT_S}s"
	fi
	LEADER="$(find_leader || true)"
	[ -n "${LEADER}" ] || stop "F0: no leader found after convergence"
	BASE_COUNT="$(role_line_count "${LEADER}")" || stop "F0: the role-line count on the leader could not be read; the baseline cannot be taken"
	note "F0: leader is node ${LEADER}; baseline role-line count on the leader is ${BASE_COUNT}"
	note "F0: no verdict here reads a term field; a term is printed only by a daemon at dca7e2b or later, and only at a role or leader transition, so term equality and growth are read from the transitions themselves, which grades an old binary and a new one alike, see the header"
}

# f1_red (old binary): isolate the leader, hold for the settle window, and require
# it to still be a mute leader; then heal and note reconvergence.
f1_red() {
	local L="${LEADER}"
	note "F1 red: isolating leader node ${L} from its two peers with the OLD binary (pre-quorum-check d19bb19)"
	"${GATE_DIR}/partition.sh" apply "${L}"
	partition_installed "${L}" || stop "F1: the isolation rules are not installed on node ${L}; apply did not take, so no verdict can be trusted"
	note "F1: isolation confirmed on node ${L}"
	assert_stays_leader "${L}" "${SETTLE_S}" CQ.red "node ${L} is still role=leader with no new role transition after ${SETTLE_S}s of isolation; without the quorum check the isolated leader holds its term as a mute leader, the phenomenon the fix removes"
	note "F1: healing node ${L}"
	"${GATE_DIR}/partition.sh" heal "${L}"
	# AND THE ELSE OF THIS IF WAS THE WIDE PATH, not the narrow one: with a host
	# unreadable, wait_converged always answers something other than 0, so the
	# branch a reader lands in is the one below and not the one just above. The
	# first version of this fix rewrote only the then, which left the lie exactly
	# where it was and moved a comment on top of it.
	local wc=0
	wait_converged "${CONVERGE_TIMEOUT_S}" || wc=$?
	if [ "${wc}" -eq 0 ]; then
		# THE WORD none WAS A LIE WAITING FOR AN UNREADABLE HOST, and this note is
		# the clearest case of the class because it decides no verdict at all:
		# CQ.red is already registered by assert_stays_leader above, so a run that
		# ends GREEN carries this sentence into its artifact, and an artifact line
		# gets quoted on its own. "leader is node none" read alone says there is no
		# leader when there is one nobody could read.
		local nl nlrc=0
		nl="$(find_leader)" || nlrc=$?
		if [ "${nlrc}" -eq 0 ]; then
			note "F1: cluster reconverged after heal, leader is node ${nl}"
		elif [ "${nlrc}" -eq 2 ]; then
			note "F1: cluster reconverged after heal, and the leader could NOT BE NAMED because a node's role line could not be read; that is not the same as there being none"
		else
			note "F1: cluster reconverged after heal, and no node reports the leader role"
		fi
	elif [ "${wc}" -eq 2 ]; then
		note "F1: whether the cluster reconverged after heal could NOT BE TOLD within ${CONVERGE_TIMEOUT_S}s, because a host could not be read; that is not the same as it having failed to reconverge"
	else
		note "F1: cluster did not reconverge within ${CONVERGE_TIMEOUT_S}s after heal; inspect the node logs"
	fi
}

# f3_green (new binary): isolate the leader and read the three green signatures off
# the logs with the partition still live for (a) and (b), then heal for (c).
f3_green() {
	local L="${LEADER}" newl="" newleader="" t0 now
	note "F3 green: isolating leader node ${L} from its two peers with the NEW binary (quorum check on)"
	"${GATE_DIR}/partition.sh" apply "${L}"
	partition_installed "${L}" || stop "F3: the isolation rules are not installed on node ${L}; apply did not take"
	note "F3: isolation confirmed on node ${L}"

	# (a) CQ.demote: the isolated leader self-degrades to follower leader=0.
	begin_check
	if wait_role_leader "${L}" follower 0 "${DEMOTE_TIMEOUT_S}"; then
		pass "CQ.demote: node ${L} self-degraded to role=follower leader=0 within ${WAITED}s of isolation (mechanism bound about ${BOUND_MS}ms; the observed number is bounded by ssh and the ${POLL_S}s poll). Isolated it could not hear a higher term and it dropped to leader=0, so this is the same-term quorum-check step-down"
		note "CQ.demote evidence, last role lines on node ${L}:"
		run_on_ok "${L}" "grep -E 'role=' naylamp/logs/node.log 2>/dev/null | tail -3"
	else
		fail "CQ.demote: node ${L} did not reach role=follower leader=0 within ${DEMOTE_TIMEOUT_S}s of isolation; the new binary should self-degrade at the same term"
	fi
	end_check CQ.demote

	# (b) CQ.elect: the majority elects a new leader with the partition still live.
	t0=$(date +%s)
	while :; do
		newl="$(find_leader || true)"
		[ -n "${newl}" ] && [ "${newl}" != "${L}" ] && { newleader="${newl}"; break; }
		now=$(date +%s); [ $(( now - t0 )) -ge "${ELECT_TIMEOUT_S}" ] && break
		sleep "${POLL_S}"
	done
	begin_check
	if [ -n "${newleader}" ] && partition_installed "${L}"; then
		pass "CQ.elect: node ${newleader} is a new role=leader elected by the majority while node ${L} is still isolated, no heal. A new leader wins by campaigning at a higher term, so its term is above the old leader's"
		note "CQ.elect evidence, last role line on node ${newleader}: $(leader_role "${newleader}")"
	else
		fail "CQ.elect: no new leader distinct from ${L} appeared on the majority side within ${ELECT_TIMEOUT_S}s with the partition live (found '${newl}')"
	fi
	end_check CQ.elect

	# (c) CQ.rejoin: after heal the old leader rejoins as a follower of the new one.
	note "F3: healing node ${L}"
	"${GATE_DIR}/partition.sh" heal "${L}"
	begin_check
	# THE THIRD LAMP GETS READ HERE TOO. Collapsed into the && chain, a 2 from
	# wait_converged came out as this fail, which ASSERTS the node did not
	# reintegrate when the only thing that happened is that a host went unread.
	# The run is red either way and a red seals nothing, so this does not block;
	# it is fixed because a verdict line gets quoted on its own and this one
	# pointed at the cluster instead of at the silent host. assert_stays_leader,
	# three functions up, already had the right shape.
	local rj=1
	if [ -n "${newleader}" ] && wait_role_leader "${L}" follower "${newleader}" "${CONVERGE_TIMEOUT_S}"; then
		rj=0
		wait_converged "${CONVERGE_TIMEOUT_S}" || rj=$?
	fi
	if [ "${rj}" -eq 0 ]; then
		pass "CQ.rejoin: after heal node ${L} is role=follower leader=${newleader} and the cluster converged on leader ${newleader}; the old leader rejoined as a follower at the new term"
		note "CQ.rejoin evidence, last role line on node ${L}: $(leader_role "${L}")"
	elif [ "${rj}" -eq 2 ]; then
		fail "CQ.rejoin: whether node ${L} reintegrated as a follower of ${newleader} and the cluster converged could NOT BE TOLD within ${CONVERGE_TIMEOUT_S}s, because a host could not be read"
	else
		fail "CQ.rejoin: node ${L} did not reintegrate as a follower of ${newleader:-the new leader} and converge within ${CONVERGE_TIMEOUT_S}s"
	fi
	end_check CQ.rejoin
}

# f4_negative (new binary, healthy cluster): the current leader must not degrade
# with no partition, the instrument's validity check.
f4_negative() {
	local hl
	note "F4 negative control: healthy cluster, no partition; the leader must not degrade"
	hl="$(find_leader || true)"
	[ -n "${hl}" ] || { begin_check; fail "CQ.negative: no healthy leader to observe"; end_check CQ.negative; return; }
	assert_stays_leader "${hl}" "${SETTLE_S}" CQ.negative "node ${hl} stayed role=leader with no new role transition over ${SETTLE_S}s on a healthy cluster; the quorum check does not fire while a majority is reachable"
}

cmd="${1:-}"
case "$cmd" in
	red)
		teardown
		EXPECTED="CQ.red"
		precondition
		f1_red
		COMPLETED=1
		;;
	green)
		teardown
		EXPECTED="CQ.demote CQ.elect CQ.rejoin CQ.negative"
		precondition
		f3_green
		f4_negative
		COMPLETED=1
		;;
	*)
		echo "usage: checkquorum.sh <red|green>" >&2
		echo "  red    run against the OLD binary (d19bb19): isolated leader stays a mute leader (CQ.red)" >&2
		echo "  green  run against the NEW binary (8f01feb): self-degrade, majority elects, rejoin, negative control" >&2
		exit 2
		;;
esac
