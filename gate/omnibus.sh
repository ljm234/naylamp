#!/usr/bin/env bash
# omnibus.sh: the Subphase 4.5 gate, widened with the consensus-invariant audit of
# Arc 4.8. ONE run closes both, because they grade different things off the same
# hardware: 4.5 grades Phase 4 on operability and non-regression, and Arc 4.8
# grades Phase 3 by auditing the state that operability leaves behind. Running
# them apart would audit a cluster that never suffered a failure, which attests
# very little.
#
# Styled on servicehealth.sh: the same verdict registry, teardown trap, leader
# helpers, and the partition of partition.sh. It lives among the gate scripts so
# it can source common.sh and call build.sh, deploy.sh, cluster.sh and
# partition.sh as siblings.
#
# THE PHASES, and why the wipes fall where they do:
#   F0  off-cloud: govulncheck and the sealed cluster DST. If the logic regressed,
#       no host work is done finding that out. It is the one phase that runs with
#       the machines switched off, which is why "omnibus.sh pre" skips the
#       reachability probe entirely.
#   F1  build, deploy, homogeneous sha256, and the GIT SHA written into this file.
#       The July artifact carried no commit and that is precisely why its evidence
#       could not be tied to any tree; a run that cannot be anchored is not
#       evidence, so this is a hard precondition and not a courtesy.
#   F2  wipe, then the three operability arms. NO WIPE BETWEEN THEM: the evidence
#       is the same datum surviving each failure in turn, and a wipe would destroy
#       the very thing under test.
#   F3  NO WIPE. Quiesce the cluster and audit the state F2 produced. The acks
#       oracle is the record of F2's own client operations, so a wipe here would
#       orphan it.
#   F4  wipe, then the real-infrastructure benchmark on a clean cluster, so the
#       numbers are not shaped by the damage of F2.
#   F5  hygiene: no rule left behind, one binary on all three. It is a CHECK, so
#       nothing tears down before it; doing so would erase what it looks for.
#
# ORDER OF THE CHEAP THINGS. A reachability probe runs before every subcommand
# that needs a host, one short ssh each, because everything after it is expensive
# and none of it can succeed against hosts that do not answer. "pre" is the
# exception and skips it, being entirely local. Teardown, twelve ssh round trips,
# never precedes the off-cloud phase: under "all" it falls between that phase and
# the first one that touches a host, and under a single-phase run it follows the
# probe directly.
#
# THE ACK ORACLE HAS THREE STANDINGS, and two rules govern how this gate writes
# it. They are not style; breaking either reintroduces the defect the three-valued
# manifest was built to kill.
#   R1  ANY operation the client put on the wire is at minimum UNCERTAIN. Never
#       emitted is reserved for ids the workload never touched, which is what
#       makes phantom detection mean anything. Recording a timed-out operation as
#       never emitted would make its presence in the log a phantom, and the gate
#       would go red for the wrong reason. That is exactly what happened on the
#       15th of July: the client reported a timeout under a partition while the
#       write had in fact committed.
#   R2  UNCERTAIN operations go on ids of THEIR OWN, never on an id that already
#       carries a confirmed one. Once an unanswered operation touches an id, the
#       checker stops verifying that id's value in both directions, which is the
#       declared blind spot of the tool. The id ranges below keep them apart by
#       construction: every id is written exactly once, so no id can carry both.
#
# BUDGETS ARE DERIVED FROM THE CONSTANTS THE CODE SETS, never trimmed to make a
# run finish sooner. Each is stated with the constant it comes from:
#   tick            10ms, the node -tick this gate launches with (cluster.sh)
#   ElectionTicks   10 ticks = 0.10s, the raft election window
#   election floor  a fresh election needs a randomized multiple of the window;
#                   ELECT_TIMEOUT_S below is 150x the window, wide enough that a
#                   slow election is not read as a dead cluster
#   reemit          400ms, the client's re-emission interval (reemitInterval)
#   op budget       3 x group = 9 attempts, so one client operation retires in
#                   about 4.5s; every client deadline below is set above that so a
#                   deadline never fires before the client has spent its own
#                   retries
#   failover watch  FAILOVER_S is 20x the election window plus the client budget,
#                   so a failover that is merely slow is not recorded as a failure
#
# WHAT THIS GATE DOES NOT CLAIM. Leader Completeness and State Machine Safety are
# properties of the EXECUTION, not of the final state, and a restart replay
# rebuilds the corrected state, so no hardware gate can falsify them. They are
# declared here by name as bounded impossibilities, which is what the grading rule
# requires, and they remain the seeded simulation's to judge.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"

# ---- budgets, all derived above ---------------------------------------------
TICK_MS=10
ELECTION_TICKS=10
WINDOW_MS=$(( ELECTION_TICKS * TICK_MS ))
POLL_S=1
ELECT_TIMEOUT_S=15          # 150x the election window
RELOCATE_SETTLE_S=5
RESTART_TRIES=8             # bounded redraws to land leadership off node 1
OP_DEADLINE=8s              # above the 4.5s the client spends on its own retries
FAILOVER_S=25               # 20x the window plus the client budget
HEAL_SETTLE_S=15            # time for the healed node to rejoin as a follower
QUIESCE_SETTLE_S=5          # let the last commits land before stopping
REACH_TIMEOUT_S=5           # per-host liveness probe, short on purpose: see below
BENCH_SAMPLES=20            # write-ack samples for the latency table
DIM=3

# ---- workload id ranges, kept disjoint so R2 holds by construction ----------
# Each id is written exactly once by the whole run. BASE ids are written on a
# healthy cluster and are expected to be answered. KILL and PART ids are written
# while a failure is in flight, so they may or may not be answered; whichever way
# they land, they are recorded under their own id and never share one with a
# BASE write.
BASE_IDS=(7 8 9)
KILL_IDS=(21 22)
PART_IDS=(31 32)
SURVIVOR_ID=7               # the datum every arm must keep serving

# EVERY ID GETS A DISTINCT VECTOR, and that is a correctness requirement of the
# probe rather than a nicety. The index ranks purely by distance and breaks no tie
# by id, so if every id carried the same vector they would all sit at distance
# zero and a top-k would return an arbitrary k of them. The survivor would drop
# out of the result the moment the run wrote more ids than k, and the gate would
# report a datum lost on a perfectly healthy cluster. Distinct vectors make the
# survivor the unique nearest neighbour of its own vector, so a search that fails
# to return it is a real failure and nothing else.
vec_for() {
	case "$1" in
		7)  printf '1,0,0' ;;
		8)  printf '0,1,0' ;;
		9)  printf '0,0,1' ;;
		21) printf '1,1,0' ;;
		22) printf '1,0,1' ;;
		31) printf '0,1,1' ;;
		32) printf '1,1,1' ;;
		*)  printf '0.5,0.5,0.5' ;;
	esac
}

MANIFEST_LOCAL="${OUT_DIR}/omnibus-manifest.txt"
MANIFEST_REMOTE="gate-omnibus-manifest.txt"
COLD_LOCAL="${OUT_DIR}/omnibus-cold"
LOGS_LOCAL="${OUT_DIR}/omnibus-logs"
GIT_SHA=""
GIT_DIRTY=""
# HOSTS_REACHABLE is set only once every host has answered. The exit trap reads
# it so a run that stopped BECAUSE the hosts are unreachable does not then spend
# another twelve connect timeouts trying to clean rules off them.
HOSTS_REACHABLE=0
# RUN_STARTED separates a usage error from a run that began and then stopped. A
# rejected subcommand has nothing to report about cleaning up; a run that stopped
# on the reachability probe does.
RUN_STARTED=0

# ---- verdict registry (shape shared with servicehealth.sh) -------------------
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0
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

run_on_ok() {
	run_on "$@" || true
	return 0
}

# copy_from <node id> <remote path relative to home> <local dst>: scp a path down.
# common.sh carries copy_to only, and this gate has to pull cold copies and node
# logs back to compare them in one place.
copy_from() {
	local n="$1" src="$2" dst="$3"
	scp -r "${SSH_OPTS[@]}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:${src}" "${dst}"
}

# copy_dir_to <node id> <local dir> <remote dst>: push a DIRECTORY up. common.sh
# copy_to is scp without -r, which refuses a directory outright, and the sibling
# gates only ever push single files through it, so the recursive form lives here
# rather than changing a helper they share. The destination is cleared first: scp
# -r onto an existing directory nests the copy one level down instead of
# replacing it, and a stale nested copy would be compared as if it were current.
copy_dir_to() {
	local n="$1" src="$2" dst="$3"
	run_on "$n" "rm -rf '${dst}'" || return 1
	scp -r "${SSH_OPTS[@]}" "${src}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:${dst}"
}

# teardown removes any partition rule this run may have left, looping the delete
# so it clears a rule left by an earlier aborted run too. It runs from the exit
# trap, whenever a host was confirmed reachable, so a run killed midway never
# leaves one cut off. It also runs from the dispatch ahead of the arms that
# INSTALL rules or need a clean slate, which is provenance, operability and
# bench; audit does not need it and hygiene must not have it, since hygiene
# exists to find exactly the rules teardown deletes. It is twelve ssh round
# trips, which is why it never runs before the off-cloud phase: there is no
# reason to reach for a host ahead of the phase that exists to avoid paying for
# one.
teardown() {
	local n x
	for n in "${NODE_IDS[@]}"; do
		for x in "${NODE_IDS[@]}"; do
			[ "$x" = "$n" ] && continue
			run_on_ok "$n" "while sudo iptables -D INPUT -s ${PRIV[$x]} -j DROP 2>/dev/null; do :; done"
			run_on_ok "$n" "while sudo iptables -D OUTPUT -d ${PRIV[$x]} -j DROP 2>/dev/null; do :; done"
		done
	done
}

# require_hosts_reachable answers one question before anything else spends time:
# do the three hosts respond at all. It runs its own ssh rather than run_on so it
# can use a short connect timeout, and BatchMode so a host that would prompt for
# a credential fails fast instead of hanging.
#
# It exists because of what the ordering used to cost. A bare run against dead
# hosts paid twelve connect timeouts in teardown, then the whole off-cloud phase,
# 476 seconds on the run that prompted this, and only then reached the deploy
# that finally noticed. Worse is the case where the hosts are UP: the same bare
# run would have gone on to build, deploy, and then wipe data on all three
# machines, roughly ten minutes after the operator started it. So the cheapest
# possible question has to be the first one asked.
require_hosts_reachable() {
	local n unreachable=""
	for n in "${NODE_IDS[@]}"; do
		# The probe's own options come FIRST and the shared ones are inherited
		# after: ssh takes the first value it is given for an option, so this
		# shortens the connect timeout while still picking up whatever else
		# SSH_OPTS carries. Writing it the other way round would silently keep
		# the ten second timeout, and duplicating the shared options here would
		# drift the day one of them changes.
		if ssh -o BatchMode=yes -o ConnectTimeout="${REACH_TIMEOUT_S}" "${SSH_OPTS[@]}" \
			"${NAYLAMP_GATE_USER}@${HOSTS[$n]}" true >/dev/null 2>&1; then
			note "reach: node ${n} (${HOSTS[$n]}) answers"
		else
			unreachable="${unreachable} ${n}(${HOSTS[$n]})"
		fi
	done
	if [ -n "${unreachable}" ]; then
		stop "unreachable host(s):${unreachable}. Check the instances are started and that NAYLAMP_GATE_HOSTS holds their current public addresses, which change on restart."
	fi
	HOSTS_REACHABLE=1
	note "reach: all three hosts answer within ${REACH_TIMEOUT_S}s"
}

cleanup() {
	local rc=$?
	set +e
	# Only clean the hosts if they were ever known to answer. Without this, a run
	# that stopped precisely because a host is unreachable pays the whole teardown
	# in connect timeouts on the way out, which is the same waste twice.
	if [ "${HOSTS_REACHABLE}" -eq 1 ]; then
		teardown
	elif [ "${RUN_STARTED}" -eq 1 ]; then
		# Worth saying once a run has begun, and not on a usage error, which
		# never reached for a host and has nothing to clean.
		echo "gate: skipping teardown; no host was ever confirmed reachable, so there is nothing to clean and nothing to wait for" >&2
	fi
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# ---- observation helpers -----------------------------------------------------

leader_role() {
	run_on "$1" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1' 2>/dev/null || true
}

role_of() { leader_role "$1" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true; }

find_leader() {
	local n
	for n in "${NODE_IDS[@]}"; do
		node_alive "$n" || continue
		case "$(leader_role "$n")" in *role=leader*) printf '%s' "$n"; return 0 ;; esac
	done
	return 1
}

# count_leaders prints how many nodes currently report the leader role. find_leader
# stops at the first one, which is enough to name a leader but says nothing about
# whether a second node also believes it leads. Reconvergence is a claim about the
# whole cluster, so it is read from the count and not from the first match.
count_leaders() {
	local n c=0
	for n in "${NODE_IDS[@]}"; do
		# Liveness first. The log is appended to, so a node whose relaunch failed
		# keeps its last role line forever, and if that line said leader it would
		# be counted as a second one. That would report a two-leader consensus
		# violation that never happened, on a cluster whose real fault is a daemon
		# that did not come up. A dead node holds no office.
		node_alive "$n" || continue
		[ "$(role_of "$n")" = leader ] && c=$((c + 1))
	done
	printf '%s' "${c}"
}

wait_for_leader() {
	local waited=0
	while [ "${waited}" -lt "${ELECT_TIMEOUT_S}" ]; do
		[ -n "$(find_leader || true)" ] && return 0
		sleep "${POLL_S}"
		waited=$((waited + POLL_S))
	done
	return 1
}

node_alive() {
	run_on "$1" 'if [ -f naylamp/naylampd.pid ] && kill -0 "$(cat naylamp/naylampd.pid)" 2>/dev/null; then echo yes; fi' 2>/dev/null | grep -q yes
}

# ---- client wrappers ---------------------------------------------------------

group_natural() {
	local g="" x
	for x in "${NODE_IDS[@]}"; do
		[ -n "$g" ] && g="${g},"
		g="${g}${x}=${PRIV[$x]}:${NODE_PORT}"
	done
	printf '%s' "$g"
}

# client_op runs one client operation on host 1 and echoes its output followed by
# exit=<code>, so a caller reads the outcome from the text.
client_op() {
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '$(group_natural)' $* ; echo exit=\$?" 2>&1
}

answered() { printf '%s' "$1" | grep -q 'exit=0$'; }

# manifest_put runs a put and records it under the standing its outcome earns.
# This is where R1 lives: the line is appended EITHER WAY. An answered write is
# confirmed and its absence from the log is a lost acknowledged write; an
# unanswered one is uncertain and neither its presence nor its absence is a
# verdict. Nothing the client emitted is ever left out of the manifest, because an
# omitted id that committed would be read as a phantom.
manifest_put() {
	local id="$1" vec="$2" out
	out="$(client_op -op put -id "${id}" -vec "${vec}" -deadline "${OP_DEADLINE}")"
	printf '%s\n' "${out}"
	if answered "${out}"; then
		echo "put ${id} ${vec} confirmed" >> "${MANIFEST_LOCAL}"
		return 0
	fi
	echo "put ${id} ${vec} uncertain" >> "${MANIFEST_LOCAL}"
	return 1
}

# search_ok reports whether a search returns the wanted id.
search_ok() {
	local want="$1" out
	out="$(client_op -op search -vec "$(vec_for "${want}")" -k 3 -deadline "${OP_DEADLINE}")"
	printf '%s\n' "${out}"
	printf '%s' "${out}" | grep -q "id=${want}"
}


# ---- cluster lifecycle -------------------------------------------------------

wipe_hosts() {
	local n
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" 'cd naylamp && rm -rf data logs data.cold data.cold.* && mkdir -p data logs' \
			|| stop "the wipe of node ${n} failed; a host that kept a previous run's data would carry ids this run never emitted, and the audit would report them as phantoms"
	done
}

# ensure_leader_off_1 lands leadership on node 2 or 3, bounded, re-reading the role
# line after every redraw. Node 1 co-locates the client, so partitioning it would
# cut the client off from the cluster and measure the harness instead of the
# system. A relocation that never lands aborts with a message that says what to do,
# rather than proceeding to partition the client's own host.
ensure_leader_off_1() {
	local tries=0 L
	L="$(find_leader || true)"
	while [ -z "${L}" ] || [ "${L}" = 1 ]; do
		tries=$((tries + 1))
		[ "${tries}" -le "${RESTART_TRIES}" ] || return 1
		note "leader is on node ${L:-none}; redrawing (attempt ${tries} of ${RESTART_TRIES}) to land it on node 2 or 3"
		"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
		"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
		wait_for_leader || return 1
		sleep "${RELOCATE_SETTLE_S}"
		L="$(find_leader || true)"
	done
	return 0
}

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

peers_of() {
	local self="$1" g="" x
	for x in "${NODE_IDS[@]}"; do
		if [ "$x" != "${self}" ]; then
			[ -n "$g" ] && g="${g},"
			g="${g}${x}=${PRIV[$x]}:${NODE_PORT}"
		fi
	done
	printf '%s' "$g"
}

# ---- F0: off-cloud ------------------------------------------------------------

phase_pre() {
	note "OM.pre: off-cloud preconditions, before any host work is done"
	begin_check

	note "OM.pre: govulncheck over the whole engine (item 4.5.6)"
	if ( cd "${REPO_DIR}/engine" && go run golang.org/x/vuln/cmd/govulncheck@latest ./... ); then
		pass "OM.pre: govulncheck is clean over the engine"
	else
		fail "OM.pre: govulncheck reported a finding; the gate does not run against a vulnerable tree"
	fi

	note "OM.pre: the sealed distributed DST of 3.5 must still be green (item 4.5.5)"
	if ( cd "${REPO_DIR}/engine" && go test ./naylamp/ -run '^TestClusterDST_Seeded$' -count=1 -timeout 60m ); then
		pass "OM.pre: the sealed cluster DST is green, so the logic did not regress"
	else
		fail "OM.pre: the sealed cluster DST is red; the logic regressed and no hardware result would mean anything"
	fi

	end_check OM.pre
	[ "$(verdict_of OM.pre)" = pass ] || stop "OM.pre failed; the off-cloud preconditions gate the whole run"
}

# ---- F1: provenance ------------------------------------------------------------

phase_provenance() {
	note "OM.provenance: build, deploy, homogeneous fleet, and the commit this run is anchored to"
	begin_check

	GIT_SHA="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
	if [ -n "$(git -C "${REPO_DIR}" status --porcelain 2>/dev/null)" ]; then
		GIT_DIRTY=" plus uncommitted changes"
	fi
	if [ -z "${GIT_SHA}" ]; then
		fail "OM.provenance: the repository HEAD could not be read; a run that cannot name its tree is not evidence"
	else
		note "OM.provenance: head: ${GIT_SHA}${GIT_DIRTY}"
		pass "OM.provenance: this run is anchored to ${GIT_SHA}${GIT_DIRTY}"
	fi

	"${GATE_DIR}/build.sh" || stop "OM.provenance: build.sh failed; cannot run the gate"
	"${GATE_DIR}/deploy.sh" || stop "OM.provenance: deploy.sh failed; cannot run the gate"

	record_binary_digests
	if [ "${SAME_BINARY}" -eq 1 ] && [ -n "${FIRST_DIGEST}" ]; then
		pass "OM.provenance: all three hosts carry the same naylampd (sha256 ${FIRST_DIGEST})"
	else
		fail "OM.provenance: the three hosts do not carry the same naylampd; a mixed fleet invalidates every later verdict"
	fi

	end_check OM.provenance
	[ "$(verdict_of OM.provenance)" = pass ] || stop "OM.provenance failed; the run cannot be anchored or the fleet is mixed"
}

# ---- F2: operability, one continuous state, no wipe between arms ---------------

phase_serve() {
	note "OM.serve: a wiped three-host cluster forms quorum and serves the public API (item 4.5.1)"
	begin_check

	: > "${MANIFEST_LOCAL}"
	"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
	wipe_hosts
	"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
	if ! wait_for_leader; then
		fail "OM.serve: no leader appeared within ${ELECT_TIMEOUT_S}s on a healthy fresh cluster"
		end_check OM.serve
		return
	fi
	if ! ensure_leader_off_1; then
		stop "OM.serve: no leader landed on node 2 or 3 within ${RESTART_TRIES} redraws. Node 1 co-locates the client and must never be the partitioned host, so relocate leadership by hand and re-run rather than partitioning the client's own host."
	fi
	note "OM.serve: leader is node $(find_leader)"

	local id ok=1
	for id in "${BASE_IDS[@]}"; do
		manifest_put "${id}" "$(vec_for "${id}")" || ok=0
	done
	if [ "${ok}" -ne 1 ]; then
		fail "OM.serve: a write to a healthy cluster was not answered; the baseline must commit before any failure is injected"
	fi
	if search_ok "${SURVIVOR_ID}"; then
		pass "OM.serve: the cluster formed quorum across three hosts and the public API served a read of id=${SURVIVOR_ID}"
	else
		fail "OM.serve: the public API did not return id=${SURVIVOR_ID} on a healthy cluster"
	fi

	end_check OM.serve
}

phase_kill() {
	note "OM.kill: kill -9 the leader; a survivor takes office and the API serves the same datum (item 4.5.2)"
	begin_check

	local L newl waited
	L="$(find_leader || true)"
	if [ -z "${L}" ]; then
		fail "OM.kill: no leader to kill"
		end_check OM.kill
		return
	fi
	note "OM.kill: leader before the kill is node ${L}"

	run_on "${L}" 'kill -9 "$(cat naylamp/naylampd.pid)" 2>/dev/null; echo killed' || true
	if node_alive "${L}"; then
		fail "OM.kill: node ${L} is still running after the kill; the failure was not injected"
		end_check OM.kill
		return
	fi

	waited=0
	newl=""
	while [ "${waited}" -lt "${FAILOVER_S}" ]; do
		local c
		for c in "${NODE_IDS[@]}"; do
			[ "$c" = "${L}" ] && continue
			if [ "$(role_of "$c")" = leader ]; then newl="$c"; break; fi
		done
		[ -n "${newl}" ] && break
		sleep "${POLL_S}"
		waited=$((waited + POLL_S))
	done

	if [ -z "${newl}" ]; then
		fail "OM.kill: no survivor took office within ${FAILOVER_S}s of the leader being killed"
		end_check OM.kill
		return
	fi
	note "OM.kill: node ${newl} took office ${waited}s after the kill"

	# The ids written here may or may not be answered while the cluster is
	# recovering, and they carry their own range for that reason.
	local id
	for id in "${KILL_IDS[@]}"; do
		manifest_put "${id}" "$(vec_for "${id}")" || note "OM.kill: id=${id} was not answered during the failover; recorded as uncertain"
	done

	if search_ok "${SURVIVOR_ID}"; then
		pass "OM.kill: node ${newl} took office after the leader was killed and the API still served id=${SURVIVOR_ID}, the same datum written before the failure"
	else
		fail "OM.kill: the API did not serve id=${SURVIVOR_ID} after the failover; a datum acknowledged before the kill was lost to the caller"
	fi

	note "OM.kill: reintegrating node ${L}"
	"${GATE_DIR}/cluster.sh" start-node "${L}" >/dev/null 2>&1 || true
	sleep "${HEAL_SETTLE_S}"
	if [ "$(role_of "${L}")" = leader ]; then
		note "OM.kill: node ${L} came back and won office again; that is legal and the run continues"
	else
		note "OM.kill: node ${L} rejoined as $(role_of "${L}")"
	fi

	end_check OM.kill
}

phase_partition() {
	note "OM.partition: a real firewall partition of the leader is inherited and then heals (item 4.5.3)"
	begin_check

	if ! ensure_leader_off_1; then
		stop "OM.partition: leadership could not be landed on node 2 or 3 within ${RESTART_TRIES} redraws, and node 1 must never be the partitioned host because the client shares its address."
	fi
	local L newl waited
	L="$(find_leader || true)"
	note "OM.partition: partitioning the leader, node ${L}"

	"${GATE_DIR}/partition.sh" apply "${L}" || { fail "OM.partition: the partition rules did not apply"; end_check OM.partition; return; }

	waited=0
	newl=""
	while [ "${waited}" -lt "${FAILOVER_S}" ]; do
		local c
		for c in "${NODE_IDS[@]}"; do
			[ "$c" = "${L}" ] && continue
			if [ "$(role_of "$c")" = leader ]; then newl="$c"; break; fi
		done
		[ -n "${newl}" ] && break
		sleep "${POLL_S}"
		waited=$((waited + POLL_S))
	done

	if [ -z "${newl}" ]; then
		fail "OM.partition: the majority elected no leader within ${FAILOVER_S}s while node ${L} was isolated"
	else
		note "OM.partition: the majority elected node ${newl} while node ${L} stayed isolated"
	fi

	local id
	for id in "${PART_IDS[@]}"; do
		manifest_put "${id}" "$(vec_for "${id}")" || note "OM.partition: id=${id} was not answered under the partition; recorded as uncertain"
	done

	if search_ok "${SURVIVOR_ID}"; then
		note "OM.partition: the majority served id=${SURVIVOR_ID} while the partition was still installed"
	else
		fail "OM.partition: the majority did not serve id=${SURVIVOR_ID} while node ${L} was isolated"
	fi

	"${GATE_DIR}/partition.sh" heal "${L}" || fail "OM.partition: the partition rules did not clear"
	sleep "${HEAL_SETTLE_S}"

	# Reconvergence is read from the COUNT of nodes reporting the leader role, not
	# from the first one found. Exactly one is the property; zero means the cluster
	# never settled, and two means the healed node never accepted that it had lost
	# the term, which is the failure this arm exists to catch and which naming only
	# the first leader would hide.
	local lead_after n_leaders
	lead_after="$(find_leader || true)"
	n_leaders="$(count_leaders)"
	if [ "${n_leaders}" -eq 1 ] && [ -n "${lead_after}" ]; then
		pass "OM.partition: the partition was inherited while the rules were installed, and after the heal exactly one node reports the leader role, node ${lead_after}"
	elif [ "${n_leaders}" -eq 0 ]; then
		fail "OM.partition: no node reports the leader role after the heal; the cluster did not reconverge"
	else
		fail "OM.partition: ${n_leaders} nodes report the leader role after the heal; the healed node did not accept that it lost the term"
	fi

	end_check OM.partition
}

# ---- F3: the Arc 4.8 audit, on the state F2 left, with no wipe -----------------

# quiesce_and_copy stops every node and takes a cold copy of each data directory.
# The tools open storage read-write and truncate a torn tail, so they must never be
# pointed at an original. Stopping first is what makes the comparison meaningful:
# replicas caught while running sit at different commit indexes, and a shared
# prefix read then would measure how far apart they happened to be.
quiesce_and_copy() {
	sleep "${QUIESCE_SETTLE_S}"
	"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
	local n
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" 'cd naylamp && rm -rf data.cold && cp -R data data.cold' || return 1
	done
	return 0
}

phase_faithful() {
	note "OM.faithful: every replica's committed log is a faithful record of the acknowledged workload"
	begin_check

	note "OM.faithful: the manifest this run wrote is"
	cat "${MANIFEST_LOCAL}" || true
	local nconf nunc
	nconf="$(grep -c ' confirmed$' "${MANIFEST_LOCAL}" || true)"
	nunc="$(grep -c ' uncertain$' "${MANIFEST_LOCAL}" || true)"
	note "OM.faithful: ${nconf} answered and ${nunc} unanswered operations; unanswered ones carry their own ids, so no id's value is both required and unpredictable"

	local n
	for n in "${NODE_IDS[@]}"; do
		copy_to "$n" "${MANIFEST_LOCAL}" "naylamp/${MANIFEST_REMOTE}" || { fail "OM.faithful: could not place the manifest on node ${n}"; end_check OM.faithful; return; }
	done

	local out
	for n in "${NODE_IDS[@]}"; do
		out="$(run_on "$n" "cd naylamp && ./bin/naylampd verify-log -dir data.cold -id ${n} -peers '$(peers_of "$n")' -dim ${DIM} -manifest '${MANIFEST_REMOTE}' ; echo exit=\$?" 2>&1)"
		printf '%s\n' "${out}"
		if printf '%s' "${out}" | grep -q 'exit=0$'; then
			pass "OM.faithful: node ${n} committed log is faithful"
		else
			fail "OM.faithful: node ${n} committed log is not faithful; an acknowledged write is missing or an id nobody emitted is present"
		fi
	done

	end_check OM.faithful
}

phase_digest() {
	note "OM.digest: the three replicas hold the same committed data"
	begin_check

	local n out d first="" same=1
	for n in "${NODE_IDS[@]}"; do
		out="$(run_on "$n" "cd naylamp && ./bin/naylampd state-hash -dir data.cold -id ${n} -peers '$(peers_of "$n")' -dim ${DIM} ; echo exit=\$?" 2>&1)"
		printf '%s\n' "${out}"
		if ! printf '%s' "${out}" | grep -q 'exit=0$'; then
			fail "OM.digest: node ${n} could not be digested"
			same=0
			continue
		fi
		d="$(printf '%s' "${out}" | grep -oE 'digest=[0-9a-f]+' | tail -1 | cut -d= -f2)"
		[ -z "${first}" ] && first="${d}"
		if [ -z "${d}" ] || [ "${d}" != "${first}" ]; then
			same=0
		fi
	done

	if [ "${same}" -eq 1 ] && [ -n "${first}" ]; then
		pass "OM.digest: all three replicas report the same committed-data digest ${first}. This CATCHES a divergence that survived to the final state; it does not prove state machine safety, because a divergent value whose id a later committed write overwrote converges to the same digest"
	else
		fail "OM.digest: the replicas do not agree on the committed-data digest; a divergence survived to the end of the run"
	fi

	end_check OM.digest
}

phase_logmatch() {
	note "OM.logmatch: the replicas agree over the span of committed commands they share"
	begin_check

	rm -rf "${COLD_LOCAL}"
	mkdir -p "${COLD_LOCAL}"
	local n
	for n in 2 3; do
		copy_from "$n" "naylamp/data.cold" "${COLD_LOCAL}/c${n}" || { fail "OM.logmatch: could not pull the cold copy of node ${n}"; end_check OM.logmatch; return; }
		copy_dir_to 1 "${COLD_LOCAL}/c${n}" "naylamp/data.cold.${n}" || { fail "OM.logmatch: could not place the cold copy of node ${n} on host 1"; end_check OM.logmatch; return; }
	done

	local out
	out="$(run_on 1 "cd naylamp && ./bin/naylampd compare-logs -replica 1=data.cold -replica 2=data.cold.2 -replica 3=data.cold.3 -peers '$(peers_of 1)' -dim ${DIM} ; echo exit=\$?" 2>&1)"
	printf '%s\n' "${out}"
	if printf '%s' "${out}" | grep -q 'exit=0$'; then
		pass "OM.logmatch: every replica carries the same command at every position of the shared prefix. Scope: this compares the decoded client command stream, not the raft log, so it falsifies a disagreement in what the replicas will apply and cannot falsify log matching in the formal sense"
	else
		fail "OM.logmatch: two replicas disagree inside the span they share, which lag does not explain"
	fi

	end_check OM.logmatch
}

phase_election() {
	note "OM.election: at most one leader per term, read from the terms the three hosts logged"
	begin_check

	rm -rf "${LOGS_LOCAL}"
	mkdir -p "${LOGS_LOCAL}"
	local n
	for n in "${NODE_IDS[@]}"; do
		run_on_ok "$n" "cd naylamp && cat logs/node.log 2>/dev/null" > "${LOGS_LOCAL}/node${n}.txt"
	done

	# One line per (node, term) the node claimed office at. The node log is
	# appended to across restarts, so a leader that was killed and reintegrated,
	# and every redraw before it, are all still in the one file.
	local claims dup
	claims="${LOGS_LOCAL}/claims.txt"
	: > "${claims}"
	for n in "${NODE_IDS[@]}"; do
		# A node that never took office produces no match, and grep exits 1 for
		# that. Under pipefail that would end the run, so the pipeline is guarded:
		# a node that never led contributes nothing, which is a fact about the run
		# and not an error in reading it.
		grep -h 'role=leader' "${LOGS_LOCAL}/node${n}.txt" 2>/dev/null \
			| grep -oE 'term=[0-9]+' | cut -d= -f2 | sort -u \
			| while read -r t; do printf '%s %s\n' "${t}" "${n}" >> "${claims}"; done || true
	done

	if [ ! -s "${claims}" ]; then
		fail "OM.election: no node ever logged taking office with a term; the check has nothing to read and cannot attest anything"
		end_check OM.election
		return
	fi

	note "OM.election: office claims as term/node pairs"
	sort -n "${claims}" | sed 's/^/gate:   term=/;s/ / node=/'

	dup="$(cut -d' ' -f1 "${claims}" | sort | uniq -d || true)"
	if [ -z "${dup}" ]; then
		pass "OM.election: $(wc -l < "${claims}" | tr -d ' ') office claims and no term was claimed by two nodes. Scope: this is a MONITOR, not a proof; it catches the violations the logs happened to record, and a leader that died before its ticker emitted a line leaves none"
	else
		local t
		for t in ${dup}; do
			fail "OM.election: term ${t} was claimed by more than one node: $(grep "^${t} " "${claims}" | cut -d' ' -f2 | tr '\n' ' ')"
		done
	fi

	end_check OM.election
}

# ---- F4: the real-infrastructure benchmark -------------------------------------

phase_bench() {
	note "OM.bench: real-infrastructure benchmark on a wiped cluster (items 4.5.4 and 4.5.7)"
	begin_check

	"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
	wipe_hosts
	"${GATE_DIR}/cluster.sh" start >/dev/null 2>&1 || true
	if ! wait_for_leader; then
		fail "OM.bench: no leader on the benchmark cluster"
		end_check OM.bench
		return
	fi

	local samples="${OUT_DIR}/omnibus-timing.txt"
	: > "${samples}"
	local i out bid
	i=0
	while [ "${i}" -lt "${BENCH_SAMPLES}" ]; do
		i=$((i + 1))
		bid=$((1000 + i))
		out="$(client_op -op put -id "${bid}" -vec "$(vec_for "${bid}")" -deadline "${OP_DEADLINE}" -timing)"
		# R1 applies here too. These ids go on the wire, so they are recorded, and
		# as uncertain because the benchmark reads no verdict from them. Nothing
		# audits them today, but a wipe that silently failed would leave them
		# committed for a later run, and an id on the wire that the manifest never
		# names is exactly the phantom the three standings exist to prevent.
		echo "put ${bid} $(vec_for "${bid}") uncertain" >> "${MANIFEST_LOCAL}"
		printf '%s\n' "${out}" | grep '^timing ' >> "${samples}" || true
	done

	local n_ok
	n_ok="$(grep -c 'status=ok' "${samples}" || true)"
	if [ "${n_ok}" -lt 1 ]; then
		fail "OM.bench: no timed write-ack sample completed; there is nothing to report"
		end_check OM.bench
		return
	fi

	note "OM.bench: raw samples"
	cat "${samples}"

	# Only first-attempt samples are comparable. An operation that spent
	# re-emission windows measured the client's targeting policy, not the write,
	# so the two populations are reported apart rather than averaged together.
	local first_us all_us n_first
	first_us="$(awk '/status=ok/ && /attempts=1/ {gsub(/elapsed_us=/,"",$4); s+=$4; c++} END{if(c>0) printf "%d", s/c}' "${samples}" || true)"
	n_first="$(grep -c 'attempts=1' "${samples}" || true)"
	all_us="$(awk '/status=ok/ {gsub(/elapsed_us=/,"",$4); s+=$4; c++} END{if(c>0) printf "%d", s/c}' "${samples}" || true)"

	note ""
	note "OM.bench: real infrastructure against the simulated numbers of Subphase 3.5"
	note "  quantity                  simulated (3.5)        real (this run)         comparable"
	note "  write-ack, 3 replicas     about 41ms             ${first_us:-none} us mean over ${n_first:-0} first-attempt samples   YES, both are wall clock on the same operation"
	note "  write-ack, all samples    not measured           ${all_us:-none} us mean over ${n_ok} samples                  NO, includes re-emission windows that belong to the client's targeting"
	note "  failover                  14.64 rounds           measured in seconds by this gate                              NO, and it is not converted; a round is one tick for every participant inside the simulator only"
	note "  scatter-gather vs K       K1 about 62us          OUT OF SCOPE                                                  NO, the harness fixes three nodes and one shard, and the simulated baseline does not separate K1 from K2"
	note ""

	if [ -n "${first_us}" ]; then
		pass "OM.bench: the real-infrastructure table exists with ${n_first} first-attempt write-ack samples, and it declares which rows are commensurable with 3.5 and which are not"
	else
		fail "OM.bench: no first-attempt sample completed, so the one commensurable row cannot be filled"
	fi

	end_check OM.bench
}

# ---- F5: hygiene ----------------------------------------------------------------

phase_hygiene() {
	note "OM.hygiene: nothing left behind on the hosts"
	begin_check

	local n x left=0
	for n in "${NODE_IDS[@]}"; do
		for x in "${NODE_IDS[@]}"; do
			[ "$x" = "$n" ] && continue
			if run_on "$n" "sudo iptables -C INPUT -s ${PRIV[$x]} -j DROP" >/dev/null 2>&1; then
				fail "OM.hygiene: node ${n} still drops input from node ${x}"
				left=1
			fi
			if run_on "$n" "sudo iptables -C OUTPUT -d ${PRIV[$x]} -j DROP" >/dev/null 2>&1; then
				fail "OM.hygiene: node ${n} still drops output to node ${x}"
				left=1
			fi
		done
	done

	record_binary_digests
	if [ "${SAME_BINARY}" -ne 1 ]; then
		fail "OM.hygiene: the three hosts no longer carry the same naylampd"
	fi

	if [ "${left}" -eq 0 ] && [ "${SAME_BINARY}" -eq 1 ]; then
		pass "OM.hygiene: no partition rule remains on any host and all three still run the same naylampd (sha256 ${FIRST_DIGEST})"
	fi

	end_check OM.hygiene
}

# ---- dispatch ---------------------------------------------------------------
#
# There is no default. Running this script bare prints the usage and exits 2,
# the shape checkquorum.sh uses, and deliberately NOT the shape servicehealth.sh
# and tls.sh use, which default to all. This gate wipes the data directories on
# three machines, so a mistyped or argument-less invocation must never be the one
# that starts a destructive run. servicehealth.sh wipes too and does default to
# all; the difference here is that a bare run of this gate spends the whole
# off-cloud phase first, so the wipe arrives long after the operator has stopped
# watching.
usage() {
	cat >&2 <<'USAGE'
usage: omnibus.sh <all|pre|provenance|operability|audit|bench|hygiene>

  all           every phase below, in the order they are listed
  pre           off-cloud only: govulncheck and the sealed cluster DST.
                The one subcommand that needs no hosts at all
  provenance    build, deploy, homogeneous sha256, and the commit anchor
  operability   WIPES, then serves, kills a leader, and partitions one.
                The three arms share one cluster state on purpose
  audit         the Arc 4.8 invariant audit over the state operability left
  bench         WIPES, then the real-infrastructure benchmark
  hygiene       no rule left behind, one binary on all three

THE SUBCOMMANDS ARE NOT INDEPENDENT. The order in "all" is the only order in
which they all mean something:

  audit READS THE STATE operability LEFT. Run on a freshly wiped cluster it
  attests nothing, because the acks oracle is the record of the client
  operations operability itself issued. It refuses to run without that
  manifest rather than produce an empty green.

  bench WIPES BEFORE IT RUNS. Running it before audit destroys exactly what
  audit needs. Two of the three orderings are caught: audit refuses a manifest
  with no acknowledged write, and an operability-then-bench-then-audit run reds
  in verify-log on the confirmed ids the wipe removed. Stated here because the
  ordering is still the operator's to get right.

  operability WIPES BEFORE IT RUNS, so it discards whatever a previous phase
  left. It is the intended start of a fresh run and the wrong thing to re-run
  in the middle of one.
USAGE
}

cmd="${1:-}"

# The name is validated here, before any banner prints, so an invalid one is
# rejected without a wall of context. The dispatch below carries its own catch-all
# for the same names; the two lists are deliberately redundant and both fail
# CLOSED, so a name added to one and not the other exits 2 rather than falling
# through the dispatch with an empty verdict set and reporting success.
case "${cmd}" in
	pre|provenance|operability|audit|bench|hygiene|all) ;;
	*) usage; exit 2 ;;
esac
RUN_STARTED=1

echo "=== NAYLAMP PHASE 4 OMNIBUS GATE, with the Arc 4.8 invariant audit, $(date -u) ==="
echo "subcommand: ${cmd}"
echo "hosts (pub): ${NAYLAMP_GATE_HOSTS}"
echo "hosts (priv): ${NAYLAMP_GATE_PRIVATE}"
echo "budgets: tick=${TICK_MS}ms window=${ELECTION_TICKS}t/${WINDOW_MS}ms elect=${ELECT_TIMEOUT_S}s failover=${FAILOVER_S}s heal=${HEAL_SETTLE_S}s client-deadline=${OP_DEADLINE} bench-samples=${BENCH_SAMPLES} reach=${REACH_TIMEOUT_S}s"
echo "grading: Subphase 4.5 grades Phase 4 on operability; Arc 4.8 grades Phase 3 on the invariants this same state admits"
echo "not claimed: leader completeness and state machine safety are properties of the execution, and a restart replay rebuilds the corrected state, so no hardware gate falsifies them; they remain the seeded simulation's"

# Reachability comes before everything that costs anything, and teardown comes
# after the off-cloud phase rather than before it. pre touches no host, so it is
# the one subcommand that runs with the machines switched off.
if [ "${cmd}" != pre ]; then
	require_hosts_reachable
fi

# require_operability_state refuses an audit that has nothing to audit. The
# manifest is written by operability and read by the faithfulness check, so its
# absence means either operability never ran or it ran against a different
# working directory. Cheap to check, and the alternative is a green verdict over
# an empty comparison.
require_operability_state() {
	# The predicate is a CONFIRMED line, not merely a non-empty file. The benchmark
	# appends its own ids as uncertain, so a file that exists proves nothing: a
	# bench run followed by an audit would pass an emptiness check and then go
	# green over the cluster bench had just wiped, with every step green for a bad
	# reason. No confirmed write means no operability workload, whatever else the
	# file holds.
	grep -q " confirmed$" "${MANIFEST_LOCAL}" 2>/dev/null || stop "audit: ${MANIFEST_LOCAL} holds no acknowledged write, so the operability phase did not run in this working directory. The audit reads the state operability leaves and the acks it recorded; over a wiped cluster it would attest nothing. Run 'omnibus.sh all', or run operability first."
}

run_audit() {
	require_operability_state
	quiesce_and_copy || stop "the cluster could not be quiesced and copied; the invariant audit reads cold copies only"
	phase_faithful
	phase_digest
	phase_logmatch
	phase_election
}

case "${cmd}" in
	pre)
		EXPECTED="OM.pre"
		phase_pre
		;;
	provenance)
		EXPECTED="OM.provenance"
		teardown
		phase_provenance
		;;
	operability)
		EXPECTED="OM.serve OM.kill OM.partition"
		teardown
		phase_serve
		phase_kill
		phase_partition
		;;
	audit)
		EXPECTED="OM.faithful OM.digest OM.logmatch OM.election"
		run_audit
		;;
	bench)
		EXPECTED="OM.bench"
		teardown
		phase_bench
		;;
	hygiene)
		EXPECTED="OM.hygiene"
		phase_hygiene
		;;
	all)
		EXPECTED="OM.pre OM.provenance OM.serve OM.kill OM.partition OM.faithful OM.digest OM.logmatch OM.election OM.bench OM.hygiene"
		phase_pre
		teardown
		phase_provenance
		phase_serve
		phase_kill
		phase_partition
		run_audit
		phase_bench
		phase_hygiene
		;;
	*)
		usage
		exit 2
		;;
esac

COMPLETED=1
echo "=== OMNIBUS GATE COMPLETE (${cmd}) $(date -u) ==="
