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
#   F3  NO WIPE, but NOT NO RESTART. The linearizable read goes first, because it
#       is the one audited property that needs a cluster still answering, and
#       quiescing is what makes the other four readable. It needs office on node 1
#       and the election is a coin, so it stops and starts all three until the coin
#       lands: up to twelve times, though one or two is the usual bill. The data
#       survives a restart and that is why this is not a wipe, but a reader of the
#       log should not be surprised by the restarts. Then quiesce and audit the
#       state F2 produced. The acks oracle is the record of F2's own client
#       operations, so a wipe here would orphan it.
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
# The redraw budget handed to the read arm, wider than the 8 gate/readindex.sh
# defaults to on its own. Landing office on node 1 is about a one in three coin
# per redraw, so 8 gives up on roughly one run in twenty five; standalone that
# costs a few minutes, here it would throw away everything spent since the
# off-cloud phase. Twelve puts it under one in a hundred, and the redraws happen
# only until the coin lands.
READINDEX_TRIES=12

# ---- workload id ranges, kept disjoint so R2 holds by construction ----------
# Each id is written exactly once by the whole run. BASE ids are written on a
# healthy cluster and are expected to be answered. KILL and PART ids are written
# while a failure is in flight, so they may or may not be answered; whichever way
# they land, they are recorded under their own id and never share one with a
# BASE write.
#
# THE READINDEX ID IS ALLOCATED HERE TOO even though another script writes it.
# The linearizable-read arm delegates to gate/readindex.sh, which seeds one write
# of its own, and that write lands in the same committed log the audit reads. An
# id space with two owners is how a phantom gets written by accident, so this
# table stays the only owner and the id is handed down.
BASE_IDS=(7 8 9)
KILL_IDS=(21 22)
PART_IDS=(31 32)
READINDEX_ID=41             # the seed of the linearizable-read arm, on an id of its own
SURVIVOR_ID=7               # the datum every arm must keep serving

# EVERY ID GETS A DISTINCT DIRECTION, and that is a correctness requirement of the
# probe rather than a nicety. The index ranks purely by distance and breaks no tie
# by id, so if two ids sat at distance zero from each other a top-k would return an
# arbitrary one of them. The survivor would drop out of the result the moment the
# run wrote more ids than k, and the gate would report a datum lost on a perfectly
# healthy cluster. Separated vectors make an id the unique nearest neighbour of its
# own vector, so a search that fails to return it is a real failure and nothing
# else.
#
# DIRECTION, NOT VALUE, AND THE DISTINCTION HAS TEETH. The index is built with
# vector.CosineDistance (engine/naylamp/node.go), which measures angle and ignores
# magnitude, so 2,0,0 and 1,0,0 are two different vectors at distance EXACTLY zero
# and would collide as surely as writing the same one twice. Picking a new vector
# here means picking a new direction.
#
# THE NAMED IDS ARE SEPARATED; THE CATCH-ALL IS NOT, and the difference is the
# point. Every id with an arm of its own gets a direction no other named id
# occupies. The catch-all returns 0.5,0.5,0.5 to all twenty benchmark ids, which
# puts them at distance zero from each other and from id 32. That is tolerable for
# exactly one reason, and it is not the wipe: nothing ever searches for them. They
# exist to be written and timed. Give the benchmark a search and this stops being
# tolerable.
vec_for() {
	case "$1" in
		7)  printf '1,0,0' ;;
		8)  printf '0,1,0' ;;
		9)  printf '0,0,1' ;;
		21) printf '1,1,0' ;;
		22) printf '1,0,1' ;;
		31) printf '0,1,1' ;;
		32) printf '1,1,1' ;;
		41) printf '1,2,3' ;;
		*)  printf '0.5,0.5,0.5' ;;
	esac
}

MANIFEST_LOCAL="${OUT_DIR}/omnibus-manifest.txt"
MANIFEST_REMOTE="gate-omnibus-manifest.txt"
COLD_LOCAL="${OUT_DIR}/omnibus-cold"
LOGS_LOCAL="${OUT_DIR}/omnibus-logs"
READINDEX_LOCAL="${OUT_DIR}/omnibus-readindex.txt"
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

# THE EMPTY LIST RETURNS FAILURE ONCE THE RUN HAS BEGUN, and the polarity is the
# whole point. This guard used to return 0 for an empty EXPECTED, which is right
# for a usage error (a rejected subcommand has no verdicts and must not print
# NOT A SUCCESS) and wrong for everything else: EXPECTED is empty from the
# registry block at the top of this file until the dispatch assigns it, and the
# banner and require_hosts_reachable run in between. A trapped signal landing in
# that window entered cleanup with an empty list, this line returned 0, and the
# gate exited 0 having run no phase at all.
#
# Measured on this file, unmodified, with a stub ssh and a TERM to the script's
# own pid: rc=0, not one "verdict" line, neither "all checks passed" nor "NOT A
# SUCCESS". A signal to the process GROUP came out non-zero because ssh dies
# with it, which is why the hole stayed invisible; a supervisor that signals the
# pid alone does not.
#
# RUN_STARTED is exactly the distinction this needs and it already existed for
# it: the comment that declares it says it separates a usage error from a run
# that began and then stopped. What this adds is a count against a length like
# any other, only here the length is zero and the loop below is the one that
# never runs.
#
# It also closes the maintenance road the dispatch guard cannot. That guard
# validates the subcommand name against two lists so an unknown name exits 2
# rather than falling through "with an empty verdict set and reporting success",
# in its own words; but nothing obliges a KNOWN arm to assign EXPECTED, and a
# new arm that forgets lands right here.
emit_final_verdict() {
	if [ -z "${EXPECTED}" ]; then
		[ "${RUN_STARTED}" -eq 0 ] && return 0
		echo "gate: NOT A SUCCESS; the run began and ended with no verdict set, so nothing was checked and nothing can be attested" >&2
		return 1
	fi
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
# INSTALL rules or need a clean slate, which is provenance, operability, audit
# and bench; hygiene must not have it, since hygiene exists to find exactly the
# rules teardown deletes. It is twelve ssh round trips, which is why it never
# runs before the off-cloud phase: there is no reason to reach for a host ahead
# of the phase that exists to avoid paying for one.
#
# AUDIT IS ON THAT LIST NOW, and it did not use to be. Its read arm cuts node 1
# from both peers and heals it again, so a stale rule anywhere on the fleet would
# burn every redraw that arm has before it gave up. The dispatch entry covers an
# audit run on its own. Inside a full run the arm probes the fleet itself, because
# the teardown near the top only ever cleared a PREVIOUS run, and the operability
# phase before it can leave a rule of its own when a heal gives up partway.
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
	local n ar
	for n in "${NODE_IDS[@]}"; do
		ar=0
		alive_on "$n" || ar=$?
		if [ "${ar}" -eq 2 ]; then
			echo "gate: find_leader: node ${n} could not be read and is skipped, which is not the same as dead" >&2
			continue
		fi
		[ "${ar}" -eq 1 ] && continue
		case "$(leader_role "$n")" in *role=leader*) printf '%s' "$n"; return 0 ;; esac
	done
	return 1
}

# count_leaders prints two lines: how many nodes currently report the leader
# role, then any node it could not read. It returns 2 when the second line is
# not empty. find_leader stops at the first leader, which is enough to name one
# but says nothing about whether a second node also believes it leads.
# Reconvergence is a claim about the whole cluster, so it is read from the
# count and not from the first match. A node that cannot be read is neither
# skipped nor counted as dead, because a leader nobody could read is exactly
# the second leader this count exists to catch (DEFER-072).
count_leaders() {
	local n c=0 ar log role unreadable=""
	for n in "${NODE_IDS[@]}"; do
		# Liveness first. The log is appended to, so a node whose relaunch failed
		# keeps its last role line forever, and if that line said leader it would
		# be counted as a second one. That would report a two-leader consensus
		# violation that never happened, on a cluster whose real fault is a daemon
		# that did not come up. A dead node holds no office.
		ar=0
		alive_on "$n" || ar=$?
		if [ "${ar}" -eq 2 ]; then
			unreadable="${unreadable} ${n}(liveness)"
			continue
		fi
		[ "${ar}" -eq 1 ] && continue
		if log="$(read_on "$n" 0 'cat naylamp/logs/node.log')"; then
			role="$(printf '%s' "${log}" | grep -oE 'role=(follower|candidate|leader)' | tail -1 | cut -d= -f2 || true)"
			[ "${role}" = leader ] && c=$((c + 1))
		else
			unreadable="${unreadable} ${n}(log)"
		fi
	done
	# The count goes over stdout because the caller captures it in a subshell,
	# and a variable set inside a subshell dies with it; the unreadable list
	# rides the second line.
	printf '%s\n%s\n' "${c}" "${unreadable}"
	if [ -n "${unreadable}" ]; then
		return 2
	fi
	return 0
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

# node_alive is gone: liveness is alive_on from common.sh, the three-valued
# form. The old two-valued probe read an unanswered ssh as a dead node, which
# is the collapse DEFER-072 counts for OM.kill and OM.partition.

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
	# The || true keeps R1 true even when ssh is what failed, since client_op puts
	# the operation's own outcome in the text and a non-zero status here is the
	# transport. Every call site today happens to sit in a || list, which already
	# suppresses errexit for the whole of this function, so the guard buys nothing
	# right now; it is here so that a bare call site added later cannot silently
	# reintroduce the omission that turns a committed write into a phantom.
	out="$(client_op -op put -id "${id}" -vec "${vec}" -deadline "${OP_DEADLINE}" || true)"
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

	# THE ENVIRONMENT IS SANITIZED HERE, and the sealed sweep asked for it by name.
	# TestClusterDST_Seeded already refuses NAYLAMP_CLUSTER_SEED with a t.Fatalf, so
	# that one is caught either way and catching it here only names the cause in a
	# line instead of inside a wall of test output. NAYLAMP_CLUSTER_SEEDS is the one
	# nothing catches: it replaces the compiled budget outright, and the invocation
	# below passes no -v, so Go throws away a passing test's output entirely,
	# t.Logf, os.Stdout and os.Stderr alike. A forty-seed sweep prints `ok` and
	# passes, and the artifact of a run that sealed two phases would carry no trace
	# of the substitution.
	#
	# GOFLAGS IS ON THE LIST BECAUSE -short IS A SECOND WAY IN. go test honours test
	# flags from that variable, and a probe test run under GOFLAGS=-short does see
	# testing.Short() true, which takes the 40 of the short branch while the line
	# below still reads 500 out of the source and states it. That is worse than a
	# silent substitution: it is a false number in a sealed artifact, put there by
	# the check written to prevent one. The header of this file says budgets are
	# never trimmed to make a run finish sooner, so the refusal belongs at the start
	# of the run and not in the prose.
	local var
	for var in NAYLAMP_CLUSTER_SEED NAYLAMP_CLUSTER_SEEDS GOFLAGS; do
		if [ -n "${!var:-}" ]; then
			stop "OM.pre: ${var} is exported as ${!var}, and it can decide the size of the sealed sweep. This gate runs the budget the code sets, never a trimmed one; unset it and re-run"
		fi
	done

	# THE BUDGET ITSELF GOES INTO THE ARTIFACT, because the refusals above are only
	# half an answer: they say nothing was overridden, and the number is still
	# nowhere in the file. It is read out of the test's own source rather than
	# restated here, so the two cannot drift apart, and it is anchored to the
	# function rather than to a line number, because that file holds three
	# `seeds :=` assignments and line anchors in this repository have already rotted
	# twice. The awk clears its flag on every func line before setting it on the one
	# it wants, so the search is bounded by the function body: delete that
	# assignment and this reads empty and fails, rather than walking on and printing
	# the 40 that belongs to the next test.
	local seedsrc seedbudget
	seedsrc="${REPO_DIR}/engine/naylamp/cluster_dst_test.go"
	seedbudget="$(awk '/^func /{f=0} /^func TestClusterDST_Seeded\(/{f=1} f && /^[[:space:]]*seeds := [0-9]+$/{print $3; exit}' "${seedsrc}" 2>/dev/null || true)"
	if [ -n "${seedbudget}" ]; then
		note "OM.pre: the sealed sweep is ${seedbudget} seeds, read from the seeds assignment inside func TestClusterDST_Seeded in engine/naylamp/cluster_dst_test.go. The invocation below passes no -short and GOFLAGS was refused above, so the short budget in that same function does not apply"
	else
		fail "OM.pre: the seed budget could not be read out of func TestClusterDST_Seeded in engine/naylamp/cluster_dst_test.go, so this run cannot state the size of the sweep it seals"
	fi

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

	# THE FLEET IS STOPPED HERE, before deploy.sh, and the reason cost half an hour
	# to diagnose on the 29th of July. A finished run leaves all three daemons
	# UP: hygiene tears nothing down on purpose, and teardown only deletes iptables
	# rules. So the next run reaches deploy.sh, which scp's the new binary over
	# naylamp/bin/naylampd while that exact file is still executing, and the kernel
	# refuses the write with ETXTBSY, "Text file busy". That is the real error.
	#
	# It is not the error the operator reads. sftp-server has no portable status
	# code for ETXTBSY, so it collapses to the generic SSH_FX_FAILURE and scp
	# prints its message for that code:
	#
	#   scp: dest open "naylamp/bin/naylampd": Failure
	#
	# "Failure" reads like a permission problem or a full disk, and sends the
	# operator to check both. Neither was the cause. The wasted time is not
	# the minute of scp either: in an `all` run OM.pre has already spent the sealed
	# cluster DST before reaching here, so every re-diagnosis pays those seven
	# minutes again before hitting the same wall.
	#
	# Stopping costs nothing that was not already spent. In `all`, phase_serve
	# follows immediately and opens with cluster.sh stop, wipe_hosts and
	# cluster.sh start, so every node stopped here was going to be stopped, wiped
	# and relaunched a few steps later regardless. The one ordering where the
	# behavior does change is a standalone `omnibus.sh provenance`, which now
	# leaves the fleet down rather than up; that is the honest state after a
	# redeploy, since the binary underneath those processes has just been replaced,
	# and the operability phase starts its own cluster whenever it runs next.
	#
	# What this does NOT cover: cluster.sh stop works from the pidfile and sends
	# TERM, so a daemon with no pidfile or one that ignores TERM still holds the
	# text segment and deploy.sh still fails the old way.
	"${GATE_DIR}/cluster.sh" stop >/dev/null 2>&1 || true
	note "OM.provenance: the fleet is stopped before deploy, so scp is not writing over a running naylampd"

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
	local alive_rc=0
	alive_on "${L}" || alive_rc=$?
	if [ "${alive_rc}" -eq 0 ]; then
		fail "OM.kill: node ${L} is still running after the kill; the failure was not injected"
		end_check OM.kill
		return
	fi
	if [ "${alive_rc}" -eq 2 ]; then
		fail "OM.kill: node ${L} could not be read after the kill, so the kill cannot be attested either way; an unreadable node is not a dead one"
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
	local lead_after n_leaders cl_out cl_rc=0
	lead_after="$(find_leader || true)"
	cl_out="$(count_leaders)" || cl_rc=$?
	n_leaders="$(printf '%s\n' "${cl_out}" | sed -n '1p')"
	if [ "${cl_rc}" -eq 2 ]; then
		fail "OM.partition: the leader count cannot be attested; unreadable:$(printf '%s\n' "${cl_out}" | sed -n '2p'); a leader nobody could read is not counted and is not absent"
		end_check OM.partition
		return
	fi
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

# phase_readindex delegates to gate/readindex.sh instead of restating its property
# here. That script already carries the whole instrument: it lands office where
# the red needs it, reads the daemon's "readindex ctx=" line as the direct witness
# that a majority round confirmed, and grades four checks against it: the
# precondition, the green, the red and the negative control. A second definition
# of a linearizable read living in this file could only drift away from that one,
# and drift is not the problem this arm was added to fix. The problem is
# anchoring: the standalone artifact of the 22nd of July carries no commit
# anywhere in it, and a run that cannot name its tree is not evidence, which is
# the same test this gate's own F1 applies to itself. Running the script INSIDE
# the run puts its verdict under the same sha as the other four.
#
# IT RUNS BEFORE THE QUIESCE, and it is the only audit arm that does. The other
# four read cold copies of a stopped cluster, for the reason quiesce_and_copy
# gives below. A linearizable read needs a cluster that is still answering, so the
# quiesce does not merely blur this arm, it removes it. First is the only place it
# can go.
#
# WHAT IT NEEDS IS A LIVE CLUSTER OVER THIS RUN'S DATA, not the exact cluster F2
# left standing, and the difference is worth stating because the log shows it. The
# red needs office on node 1 and the election is a coin, so the delegated gate
# stops and starts all three until it lands there. The data is on disk and a
# restart replays it, so nothing the audit reads is lost; what is lost is the
# damage history, since the arm ends up probing a freshly elected cluster plus its
# own fresh cut rather than the one F2 beat up. Read-index safety is not a claim
# about post-damage state, so that is no loss to this verdict. It would have been
# a stronger claim as a fourth arm of F2, and F2 cannot host it: every arm there
# needs the client to keep reaching the MAJORITY, which is the one thing this arm
# must deny it.
#
# IT PARTITIONS NODE 1, which every other arm of this gate refuses to do, and the
# two rules do not contradict each other. F2 claims the MAJORITY keeps serving, so
# its client must be able to reach that majority and the cut node must not be the
# client's own host. This arm claims the ISOLATED LEADER withholds the read, so
# its client must be able to reach that leader and the cut node must BE the
# client's host, which is the only way an isolated leader is still reachable at
# all. Opposite claims, opposite requirements.
#
# THE VERDICT IS TAKEN FROM THE FOUR SUB-VERDICTS AND NOT ONLY FROM THE EXIT CODE.
# Both are read, and a missing sub-verdict counts as a failure rather than as a
# silence, so the day that script grows or loses a check this arm reds instead of
# quietly attesting three checks where it used to attest four.
phase_readindex() {
	note "OM.readindex: a linearizable read is served only behind a confirmed majority round, and is withheld when that round cannot complete"
	begin_check

	local vec rc=0 before stale
	vec="$(vec_for "${READINDEX_ID}")"
	note "OM.readindex: handing gate/readindex.sh id=${READINDEX_ID} vec=${vec}, the manifest this run is building, and a redraw budget of ${READINDEX_TRIES}"

	# A rule left standing BEFORE this arm starts is not its failure and does not
	# count against it: partition.sh heal runs under errexit and gives up on the
	# first delete that misses, and OM.partition already recorded that with its own
	# fail. But it has to be cleared here anyway. The delegated gate spends its
	# whole redraw budget trying to land office on node 1, and a peer that cannot
	# be reached is exactly what stops office landing anywhere, so the arm would
	# burn twelve stop and start cycles and then blame the election.
	stale="$(rules_left)"
	if [ -n "${stale}" ]; then
		note "OM.readindex: partition rules were still installed before this arm ran (${stale}); clearing them, since a peer that cannot be reached is what keeps office from landing anywhere"
		teardown
	fi

	# How many times this id is already in the manifest, so the check further down
	# can require the count to have GROWN. Presence alone is not enough: a second
	# audit in the same working directory would still see the first one's line, and
	# the check that exists to catch a broken hand-off would be satisfied by the run
	# before it.
	before="$(grep -c "^put ${READINDEX_ID} " "${MANIFEST_LOCAL}" 2>/dev/null || true)"
	before="${before:-0}"

	# Truncate the evidence file HERE rather than trusting the tee to do it. A tee
	# that cannot open its output warns and keeps going on this platform, the
	# producer runs to completion and the status is unaffected, so the sub-verdicts
	# would be read back out of the PREVIOUS run's file and printed into this run's
	# artifact as if they were this run's. An unwritable evidence file is a stop.
	: > "${READINDEX_LOCAL}" || stop "OM.readindex: ${READINDEX_LOCAL} cannot be written, and the sub-verdicts are read back out of it; a run that cannot record this arm must not report it"

	# set +e because this arm reads the failing status instead of being stopped by
	# it, and PIPESTATUS is taken on the next line before anything can replace it.
	# The tee is not a convenience for the operator: the sub-verdicts below are read
	# back out of that file.
	set +e
	(
		export NAYLAMP_READINDEX_ID="${READINDEX_ID}"
		export NAYLAMP_READINDEX_VEC="${vec}"
		export NAYLAMP_READINDEX_MANIFEST="${MANIFEST_LOCAL}"
		export NAYLAMP_READINDEX_RESTART_TRIES="${READINDEX_TRIES}"
		"${GATE_DIR}/readindex.sh"
	) 2>&1 | tee "${READINDEX_LOCAL}"
	rc="${PIPESTATUS[0]}"
	set -e

	local id v why seeded short=""
	for id in RI.pre RI.green RI.red RI.negative; do
		# grep -F because the ids carry a dot, and the guard because a check that
		# never reported leaves no line and grep exits 1, which pipefail would turn
		# into the end of the run instead of the finding it is.
		v="$(grep -F "verdict ${id} = " "${READINDEX_LOCAL}" | tail -1 | awk '{print $NF}' || true)"
		note "OM.readindex: sub-verdict ${id} = ${v:-absent}"
		[ "${v}" = pass ] || short="${short} ${id}(${v:-absent})"
	done

	# The seed it wrote has to reach the ack oracle, and here is where that is worth
	# checking. The oracle is read three checks further down; a hand-off that broke
	# would leave an id on the wire that the manifest never names, which is the
	# definition of a phantom, and OM.faithful would red on it with nothing in its
	# message pointing back to this arm. One grep here turns a confusing red into a
	# named cause. The standing has to be CONFIRMED, not merely present: an uncertain
	# id has its value unchecked in both directions, so a pass line saying the
	# faithfulness check reads it as a write this run made would be false of it.
	#
	# The count has to land on EXACTLY ONE, which is stricter than growth and is the
	# invariant the id table above declares: every id is written once by the whole
	# run. Growth alone passes a second audit in the same working directory, which
	# would leave two put lines for one id and hand the checker a duplicate.
	local after
	after="$(grep -c "^put ${READINDEX_ID} " "${MANIFEST_LOCAL}" 2>/dev/null || true)"
	after="${after:-0}"
	seeded=""
	if [ "${after}" -eq 1 ] && [ "${before}" -eq 0 ]; then
		seeded="$(grep "^put ${READINDEX_ID} " "${MANIFEST_LOCAL}" | tail -1 | awk '{print $NF}' || true)"
	fi
	note "OM.readindex: the ack oracle holds ${before} -> ${after} lines for id=${READINDEX_ID}, standing ${seeded:-absent}"

	# THE CUT HAS TO BE PROVEN GONE, and this runs BEFORE the verdict rather than
	# after it, so the verdict accounts for it instead of the artifact carrying a
	# PASS and a FAIL for the same check. The delegated gate heals node 1 from its
	# exit trap, but that heal is one ssh whose failure is swallowed, and a single
	# transient sudo error leaves the node isolated with nothing saying so. What
	# follows then is a run of reds that all blame something else: the replicas will
	# not agree, the benchmark takes no sample because every write from the
	# co-located client is dropped on the way out, and only OM.hygiene at the very
	# end names the rule.
	local leftover
	leftover="$(rules_left)"
	if [ -n "${leftover}" ]; then
		fail "OM.readindex: a partition rule is still installed after the arm finished (${leftover}), so its heal did not take. Clearing it now, because everything below reads a cluster and would otherwise red on a cut nobody declared"
		teardown
	else
		note "OM.readindex: no host carries a partition rule; the cut this arm installed is gone"
	fi

	# The anchor is the run's, not this arm's, so it is stated as a fact about the
	# run and kept out of the verdict. GIT_SHA is set by the provenance phase, which
	# a bare "omnibus.sh audit" never runs; a pass line carrying "anchored to an
	# unrecorded head" would be this gate contradicting its own F1 in the one place
	# an operator reads for reassurance.
	if [ -n "${GIT_SHA}" ]; then
		note "OM.readindex: this verdict lands under ${GIT_SHA}${GIT_DIRTY}, the head the provenance phase recorded"
	else
		note "OM.readindex: no head was recorded, because this subcommand did not run the provenance phase; the verdict below names no tree"
	fi

	if [ "${rc}" -eq 0 ] && [ -z "${short}" ] && [ "${seeded}" = confirmed ]; then
		pass "OM.readindex: the read-index gate ran green inside this run. On the healthy majority the read was served and a new readindex line appeared; with node 1 cut from both peers the read was withheld and NO readindex line appeared, so the round never confirmed; after the heal the read was served again. Its seed id=${READINDEX_ID} is in the ack oracle as ${seeded}, so the faithfulness check below reads it as a write this run made. Scope: this exercises the read-index MECHANISM and the gate on it, not linearizability. One client, one read at a time, no concurrent history, and the answer is checked for the datum but never against an index, so it falsifies a read answered without a confirmable quorum and cannot falsify staleness inside a read that was served. The literal claim, that the served state reflects a prefix at or beyond the read index, needs the read-index accessor and stays with the seeded simulation, where TestClusterDST_ReadIndexLinearizableLiteral closed DEFER-014 in 4.3; this arm does not carry that claim onto hardware"
	else
		if [ -n "${short}" ]; then
			why="sub-verdicts short of pass:${short}. RI.pre, RI.green and RI.negative failing is the instrument outright: office never landing on node 1, a read served on a healthy majority with no readindex line to witness it, or a healed cluster that will not serve again. Any of those and the red attests nothing, so this verdict is not a finding about the read path. RI.red is where the property lives, and it is the one that has to be READ rather than assumed, because it has failure branches of both kinds. It is a linearizability regression when the read was ANSWERED, or a readindex line was LOGGED, while the leader could reach no majority. It is the instrument when office left node 1 before the cut, or when the read exited neither 0 nor 1, which is a load or argument error and not a refusal. Its own FAIL line above says which of the four it was, and this verdict does not presume"
		elif [ "${seeded}" != confirmed ]; then
			why="every sub-verdict passed, and the ack oracle does not hold exactly one confirmed line for id=${READINDEX_ID} (${before} -> ${after} lines, standing ${seeded:-absent}) after that gate put the id on the wire. None means the hand-off of NAYLAMP_READINDEX_MANIFEST broke, and left alone OM.faithful would red on that id as a phantom and say nothing about this arm; more than one means the audit ran twice over one manifest, and the id was written once but is claimed twice. Either way the fault is here and not in the read path"
		else
			why="every sub-verdict reported pass, so the status alone is the failure: that script exits non-zero when its run did not reach a clean completion, which means it stopped somewhere after the last check registered. Read the text above this line"
		fi
		fail "OM.readindex: the read-index gate did not end all-pass (exit ${rc}); ${why}"
	fi

	# The arm cut node 1 from both peers and healed it, so node 1 gets the same
	# rejoin budget OM.partition gives its own healed node before any state is
	# read. The four checks below compare the three replicas against each other,
	# and a replica that is merely still catching up is not a divergence.
	note "OM.readindex: letting node 1 rejoin for ${HEAL_SETTLE_S}s before the state is read"
	sleep "${HEAL_SETTLE_S}"

	end_check OM.readindex
}

# rules_left prints the node pairs that still carry a partition DROP rule, empty
# when none does. It asks through ask_on, so the answer carries THREE outcomes
# rather than two: a bare non-zero status cannot tell a rule that is absent
# from a host that would not answer, and reading the second as the first is how
# a swallowed heal stays invisible. A rule present is a finding, an unreadable
# probe is a finding and not a clean bill. This function carried the first
# three-valued probe in the tree, written inline; since 25 August 2026 the
# discrimination lives in one place, in common.sh, and phase_hygiene asks the
# same way.
rules_left() {
	local n x ar found=""
	for n in "${NODE_IDS[@]}"; do
		for x in "${NODE_IDS[@]}"; do
			[ "$x" = "$n" ] && continue
			ar=0
			ask_on "$n" "sudo iptables -C INPUT -s ${PRIV[$x]} -j DROP || sudo iptables -C OUTPUT -d ${PRIV[$x]} -j DROP" || ar=$?
			case "${ar}" in
				0) found="${found} ${n}-x-${x}" ;;
				1) ;;
				2) found="${found} ${n}-x-${x}(unreadable)" ;;
			esac
		done
	done
	printf '%s' "${found}"
}

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

	# THE VERDICT ABOVE IS THREE-WAY AND THE ARCHIVE WAS NOT. The loop pulls nodes 2
	# and 3; node 1's cold copy is read where it lies, so compare-logs saw three
	# replicas while gate/out/omnibus-cold held two, and phase_bench opens with a
	# wipe that removes the third seconds after OM.election. Whoever reads the
	# evidence later could re-derive the agreement between 2 and 3 and nothing else,
	# which is the same shape of defect as an artifact that names no commit.
	#
	# TWO SEPARATE GUARANTEES KEEP THIS OFF THE VERDICT, and the run needs both. It
	# reports through note, which does not touch CHECK_FAILED, so a failed pull
	# cannot turn a passing check into a failing one. It also sits inside an if,
	# which is what keeps errexit from seeing the non-zero status at all: this file
	# runs under set -euo pipefail, so a bare call would end the run at the ninth
	# phase of twelve over a transport error, and an archival copy is not worth the
	# run that produced it. The if earns its place over the || form the rest of this
	# function uses, because here both outcomes have something to report: the
	# artifact says either that all three inputs came home or that only two did.
	if copy_from 1 "naylamp/data.cold" "${COLD_LOCAL}/c1"; then
		note "OM.logmatch: the cold copy of node 1 is archived beside 2 and 3, so all three inputs to the verdict above leave the hosts"
	else
		note "OM.logmatch: the cold copy of node 1 could not be pulled for the archive. The verdict above stands; it was computed in place on host 1. But the evidence keeps only nodes 2 and 3, and the third input dies with the next wipe"
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
		# The pull must arrive WHOLE or not at all. The old run_on_ok swallowed
		# the status, so a node that never answered left an empty file
		# indistinguishable from a node that never led, and an ssh cut mid-cat
		# left a truncated one that passes any non-empty check: the two shapes
		# DEFER-072 names for this verdict. read_on proves the stream completed
		# and accepts only a clean cat; anything else is unreadable, and two
		# logs out of three is not the cluster.
		if ! read_on "$n" 0 'cat naylamp/logs/node.log' > "${LOGS_LOCAL}/node${n}.txt"; then
			fail "OM.election: node ${n} log could not be read whole; a partial or missing log cannot defend a no-duplicate-term verdict"
			end_check OM.election
			return
		fi
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
	# awk, not sed. The claims file is "<term> <node>", and a sed that rewrites the
	# first space hits the one inside the "gate: " prefix instead of the separator,
	# which printed the node label empty and left the id stranded at the end of the
	# line. The evidence file IS the artifact, so a line that reads wrong is a
	# defect in it even when the verdict above is right.
	sort -n "${claims}" | awk '{printf "gate:   term=%s node=%s\n", $1, $2}'

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
		# The || true is what makes the paragraph below true rather than merely
		# intended. phase_bench is dispatched bare, so errexit is live in this loop,
		# and an ssh that failed on its own account would end the run on this line,
		# after the write may have reached the cluster and before the append below
		# names it. The operation's own outcome is in the text, not in this status.
		out="$(client_op -op put -id "${bid}" -vec "$(vec_for "${bid}")" -deadline "${OP_DEADLINE}" -timing || true)"
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

	local n x ar left=0
	for n in "${NODE_IDS[@]}"; do
		for x in "${NODE_IDS[@]}"; do
			[ "$x" = "$n" ] && continue
			# The probe says which of the three it is, through ask_on. The old
			# two-valued form read an ssh failure as "rule absent" and declared
			# the host clean over it, the site DEFER-072 names for this verdict.
			ar=0
			ask_on "$n" "sudo iptables -C INPUT -s ${PRIV[$x]} -j DROP" || ar=$?
			case "${ar}" in
				0)
					fail "OM.hygiene: node ${n} still drops input from node ${x}"
					left=1
					;;
				1) ;;
				2)
					fail "OM.hygiene: node ${n} could not be read on the input probe for node ${x}; an unreadable host is not a clean one"
					left=1
					;;
			esac
			ar=0
			ask_on "$n" "sudo iptables -C OUTPUT -d ${PRIV[$x]} -j DROP" || ar=$?
			case "${ar}" in
				0)
					fail "OM.hygiene: node ${n} still drops output to node ${x}"
					left=1
					;;
				1) ;;
				2)
					fail "OM.hygiene: node ${n} could not be read on the output probe for node ${x}; an unreadable host is not a clean one"
					left=1
					;;
			esac
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
  audit         the linearizable read on the live cluster, then the Arc 4.8
                invariant audit over the state operability left
  bench         WIPES, then the real-infrastructure benchmark
  hygiene       no rule left behind, one binary on all three

THE SUBCOMMANDS ARE NOT INDEPENDENT. The order in "all" is the only order in
which they all mean something:

  audit READS THE STATE operability LEFT. Run on a freshly wiped cluster it
  attests nothing, because the acks oracle is the record of the client
  operations operability itself issued. It refuses to run without that
  manifest rather than produce an empty green.

  audit ALSO NEEDS THAT CLUSTER STILL RUNNING. Its first arm is a linearizable
  read, which no stopped cluster can answer, and it is that arm which stops the
  cluster for the four that follow. operability leaves the nodes up, so an
  audit that follows it finds what it needs; an audit run after a hand
  cluster.sh stop reds on its own precondition instead, saying there is no
  leader to read from.

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
	# The live arm first. Everything under it reads cold copies, and producing
	# those copies is what stops the cluster.
	phase_readindex
	quiesce_and_copy || stop "the cluster could not be quiesced and copied; the rest of the invariant audit reads cold copies only"
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
		EXPECTED="OM.readindex OM.faithful OM.digest OM.logmatch OM.election"
		teardown
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
		EXPECTED="OM.pre OM.provenance OM.serve OM.kill OM.partition OM.readindex OM.faithful OM.digest OM.logmatch OM.election OM.bench OM.hygiene"
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
