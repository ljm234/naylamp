#!/usr/bin/env bash
# faithlog.sh: prove on the three real hosts that each replica's committed log is a
# faithful record of a known workload, and that the checker knows how to catch a
# log that is not. This is Subphase 4.2, the log-fidelity audit of the engine
# (DEFER-013), carried from the seeded simulation onto real durable storage.
#
# THE PROPERTY. The committed log of a replica must be a complete and faithful
# record of the operations the clients acked: no id appears that was never written
# (no phantoms), every acked id is present (no gaps), and replaying the committed
# commands in order reproduces exactly the live set the workload built, with the
# idempotent duplicates a re-emitting client legitimately produces absorbed rather
# than counted as faults. This is a fidelity claim, not a physical exactly-once
# claim: the request id is not in the log entry, so a duplicate is expected and the
# audit tolerates it (see engine/naylamp/node.go CommittedCommands and
# engine/naylamp/cluster_dst_test.go TestClusterDST_CommittedLogIsFaithful).
#
# THE DIRECT SIGNAL. The durable log is a binary block format a shell cannot read,
# so the audit is a read-only Go tool: naylampd verify-log opens a COLD COPY of a
# stopped replica through the same OpenNode a restart uses, reads the committed
# commands through the existing read-only accessor, and compares them to a manifest
# the gate builds from the exit-0 client operations. It exits 0 when the copy is
# faithful and 1 when it is not, so the exit code is the verdict. The manifest is
# the oracle: it is assembled from what the client acked, never from the log under
# audit.
#
#   green     each of the three replicas' committed logs verifies faithful against
#             the workload manifest (exit 0). That triple is FL.green.
#   red       four deliberate defects injected into copies, each caught: a phantom
#             id, a dropped acked id, a byte flipped inside a non-final segment, and
#             as the NEGATIVE CONTROL an idempotent duplicate that must stay GREEN.
#             The three real defects red (exit 1) and the duplicate stays green:
#             that pairing is FL.red.
#   negative  a fresh untouched copy still verifies faithful after the reds (exit
#             0), so the reds came from the injected defects and not from a broken
#             instrument. That is FL.negative.
#
# WHY THE DEFECTS RUN ON COPIES. verify-log and the injector open storage O_RDWR
# and a torn tail would be truncated on open, so neither is ever pointed at an
# original. The gate copies a stopped replica's data before verifying, injects into
# a copy of that copy, and checksums the three originals before and after to prove
# they were never touched.
#
# WHY THE CORRUPT DEFECT USES SEVERAL SEGMENTS. A byte flipped in the final segment
# of the log is indistinguishable from a torn write and is truncated as a tail, not
# reported. The injector therefore rebuilds the log into one-entry segments and
# flips a byte in a NON-final one, where the raft replay path reports real
# corruption (ErrCorruptLog) at open. That is the corruption the property is about.
#
# WEAK COVERAGE, DECLARED. This gate runs one shard, so the per-shard sharding
# verdict (sm.ShardFor) is exercised only degenerately: every id maps to shard 0.
# The phantom, gap and replay verdicts are exercised fully; the sharding verdict is
# out of scope here until a multi-shard gate exists.
#
# RUNBOOK. Build and gate go under ONE tee so the whole run, including any
# certificate re-mint in the build, lands in one evidence file:
#
#   {
#     ./gate/build.sh &&
#     ./gate/deploy.sh &&
#     ./gate/cluster.sh start &&
#     ./gate/cluster.sh status &&   # repeat until one leader appears
#     ./gate/faithlog.sh
#   } 2>&1 | tee NAYLAMP_FAITHLOG_GATE_2026-07-22.txt
#
# Usage: faithlog.sh
#
# This script assumes build.sh, deploy.sh, and cluster.sh start have run and a
# leader has appeared. It writes a known workload, stops the cluster to take a cold
# copy, and audits offline. It leaves the cluster STOPPED on every exit path.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

ELECT_TIMEOUT_S=15   # poll budget for a leader to appear
WRITE_DEADLINE=20s   # the client's own budget for one committed write
PHANTOM_ID=900001    # an id far outside the workload, for the phantom defect
DIM=3                # the workload's vector dimension

# The manifest is built locally from the exit-0 client operations, then pushed to
# each host so verify-log can read it beside the copy it audits.
MANIFEST_LOCAL="${OUT_DIR}/faithlog-manifest.txt"
MANIFEST_REMOTE="gate-faithlog-manifest.txt"

# Verdict registry, the same mechanism readindex.sh, tls.sh and checkquorum.sh use.
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

# cleanup runs on every exit path: verify the originals were never mutated, remove
# the scratch copies from the hosts, then emit the verdict and force a non-zero exit
# if the run did not end all-pass.
cleanup() {
	local rc=$?
	set +e
	guard_originals
	remove_scratch
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# leader_role prints a node's last role line, empty if none yet. It returns 2
# when the host could not be read, which is not the same as having no role line:
# the read goes through read_on so a cut stream cannot pass for a whole answer.
leader_role() {
	local out
	out="$(read_on "$1" "0 1" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1')" || return 2
	printf '%s' "${out}"
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
		# THE ROLE LINE IS READ WITH ITS THIRD VALUE. Written as a bare command
		# substitution, a host that could not be read fell into the case below as
		# "not leader", which is the DEFER-072 collapse: an unreadable node and a
		# follower produced the same answer, and the caller could not tell them
		# apart. Skipping it is still not a verdict, and saying so on stderr is
		# what lets whoever reads the run know a node was passed over.
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

# wait_for_leader polls until some node reports leader, within the elect budget.
wait_for_leader() {
	local t=0
	while [ "${t}" -lt "${ELECT_TIMEOUT_S}" ]; do
		[ -n "$(find_leader || true)" ] && return 0
		sleep 1; t=$((t + 1))
	done
	return 1
}

# peers_of prints the id=addr list of a node's two peers, the same shape the node
# was launched with. verify-log ignores the addresses and reads only the ids, but
# the shape is reused so the config it builds matches the deployment exactly.
peers_of() {
	local n="$1" peers="" j
	for j in "${NODE_IDS[@]}"; do
		if [ "$j" != "$n" ]; then
			[ -n "$peers" ] && peers="${peers},"
			peers="${peers}${j}=${PRIV[$j]}:${NODE_PORT}"
		fi
	done
	printf '%s' "${peers}"
}

# client_op runs one one-shot client operation on host 1 and appends exit=<code>.
# It mirrors the wrapper readindex.sh uses; the client exits 0 only on StatusOK.
client_op() {
	local group="1=${PRIV[1]}:${NODE_PORT},2=${PRIV[2]}:${NODE_PORT},3=${PRIV[3]}:${NODE_PORT}"
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '${group}' $* ; echo exit=\$?" 2>&1
}
committed() { printf '%s' "$1" | grep -q 'exit=0$'; }

# manifest_put and manifest_del run a client op and, only when it commits, append
# the operation to the local manifest, so the manifest is exactly the acked set.
manifest_put() {
	local id="$1" vec="$2" out
	out="$(client_op -op put -id "${id}" -vec "${vec}" -deadline "${WRITE_DEADLINE}")"
	printf '%s\n' "${out}"
	committed "${out}" || return 1
	echo "put ${id} ${vec}" >> "${MANIFEST_LOCAL}"
	return 0
}
manifest_del() {
	local id="$1" out
	out="$(client_op -op del -id "${id}" -deadline "${WRITE_DEADLINE}")"
	printf '%s\n' "${out}"
	committed "${out}" || return 1
	echo "del ${id}" >> "${MANIFEST_LOCAL}"
	return 0
}

# data_checksum prints a stable checksum of a host's original data directory, so a
# before and after comparison proves no tool mutated it.
data_checksum() {
	run_on "$1" 'cd naylamp && find data -type f -exec sha256sum {} \; 2>/dev/null | sort | sha256sum | cut -d" " -f1' 2>/dev/null || true
}

# verify_copy runs verify-log on a host against a directory (a copy) and prints its
# output ending in exit=<code>. verify-log needs no TLS material; it only reads a
# directory.
verify_copy() {
	local n="$1" dir="$2"
	run_on "$n" "cd naylamp && ./bin/naylampd verify-log -dir '${dir}' -id ${n} -peers '$(peers_of "$n")' -dim ${DIM} -manifest '${MANIFEST_REMOTE}' ; echo exit=\$?" 2>&1
}
faithful() { printf '%s' "$1" | grep -q 'exit=0$'; }
notfaithful() { printf '%s' "$1" | grep -q 'exit=1$'; }

# ORIG_CK holds each host's original data checksum, captured after the stop.
declare -a ORIG_CK

# guard_originals re-checksums the originals and fails the run if any changed. Runs
# from the exit trap, so a mutation anywhere is caught even on an early exit. It
# only registers a verdict once the checksums were captured (after the stop); an
# earlier exit leaves FL.guard unregistered, which the completion check catches on
# its own.
#
# CHECKED IS A COUNT AND NOT A FLAG, and the difference is a verdict. It was a
# flag, set to 1 by the first node that had a captured checksum, so a run where
# stop_and_copy died partway left ORIG_CK holding one node, compared that one,
# and registered FL.guard pass under a line claiming all three directories were
# byte-identical. Measured on the lines of this file with ORIG_CK[1] alone set:
# the pass was recorded and the line printed. The count against the length of
# NODE_IDS is what separates "all of them are unchanged" from "the ones I could
# read are unchanged", and only the first of those is what FL.guard means.
#
# The three outcomes are kept apart on purpose. Nothing captured is the early
# exit the paragraph above describes and stays unregistered. Some captured is a
# FAILURE and not a pass, because the verdict quantifies over the fleet. All
# captured is the only road to a pass.
guard_originals() {
	local n now changed=0 checked=0 want="${#NODE_IDS[@]}"
	for n in "${NODE_IDS[@]}"; do
		[ -n "${ORIG_CK[$n]:-}" ] || continue
		checked=$((checked + 1))
		now="$(data_checksum "$n")"
		if [ "${now}" != "${ORIG_CK[$n]}" ]; then
			echo "gate: FAIL guard: node ${n} original data changed during the run (before=${ORIG_CK[$n]} after=${now}); a tool touched the original, not a copy" >&2
			changed=1
		fi
	done
	[ "${checked}" -eq 0 ] && return 0
	if [ "${checked}" -ne "${want}" ]; then
		record_verdict FL.guard fail
		echo "gate: FAIL guard: only ${checked} of ${want} original data directories had a checksum captured, so this verdict cannot say the originals are untouched; it can only say that the ${checked} it could read are" >&2
	elif [ "${changed}" -eq 0 ]; then
		record_verdict FL.guard pass
		echo "gate: guard: all ${want} original data directories are byte-identical before and after, one by one; every tool touched only copies" >&2
	else
		record_verdict FL.guard fail
	fi
}

# remove_scratch deletes the copies and injected directories the gate created on the
# hosts, leaving only the originals.
remove_scratch() {
	local n
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" "cd naylamp && rm -rf data.verify data.negative data.red.src data.red.phantom data.red.missing data.red.corrupt data.red.dup '${MANIFEST_REMOTE}'" >/dev/null 2>&1 || true
	done
}

# ---- precondition -----------------------------------------------------------

precondition() {
	note "FL.pre: cluster of three healthy, a known workload of put, del and put-then-del written and acked, the manifest built from the exit-0 operations"
	begin_check
	wait_for_leader || stop "FL.pre: no leader; run cluster.sh start and wait until cluster.sh status shows a leader"
	note "FL.pre: leader is node $(find_leader)"
	: > "${MANIFEST_LOCAL}"
	# A small workload that exercises every verdict: three live ids, one put-then-del
	# (seen but not live), and a final live-id put. Because each operation runs to
	# completion before the next, every committed copy of that final put, however many
	# the client re-emitted, is the contiguous committed tail, which is what the
	# missing defect drops to make id 5 absent.
	manifest_put 1 1,0,0 || fail "FL.pre: put id=1 did not commit"
	manifest_put 2 0,1,0 || fail "FL.pre: put id=2 did not commit"
	manifest_put 3 0,0,1 || fail "FL.pre: put id=3 did not commit"
	manifest_del 2       || fail "FL.pre: del id=2 did not commit"
	manifest_put 5 1,1,1 || fail "FL.pre: put id=5 did not commit"
	note "FL.pre: manifest is"
	cat "${MANIFEST_LOCAL}"
	if [ "${CHECK_FAILED}" -eq 0 ]; then
		pass "FL.pre: the workload committed and the manifest holds ids 1,2,3 written, 2 deleted, 5 written"
	fi
	end_check FL.pre
}

# ---- stop and copy ----------------------------------------------------------

stop_and_copy() {
	note "stopping the cluster for a cold copy; a stopped node has no torn tail, so the copy is integral"
	"${GATE_DIR}/cluster.sh" stop || true
	local n
	for n in "${NODE_IDS[@]}"; do
		ORIG_CK[$n]="$(data_checksum "$n")"
		note "node ${n} original data checksum ${ORIG_CK[$n]}"
		copy_to "$n" "${MANIFEST_LOCAL}" "naylamp/${MANIFEST_REMOTE}"
	done
}

# ---- green ------------------------------------------------------------------

green() {
	note "FL.green: a cold copy of each of the three replicas verifies faithful against the workload manifest"
	begin_check
	local n out
	for n in "${NODE_IDS[@]}"; do
		run_on "$n" 'cd naylamp && rm -rf data.verify && cp -r data data.verify'
		out="$(verify_copy "$n" data.verify)"
		printf '%s\n' "${out}"
		if faithful "${out}"; then
			pass "FL.green: node ${n} committed log is faithful (exit=0)"
		else
			fail "FL.green: node ${n} committed log did not verify faithful; a healthy replica must be a faithful record of the acked workload"
		fi
	done
	end_check FL.green
}

# ---- red --------------------------------------------------------------------

red() {
	note "FL.red: four defects injected into copies on node 1; the three real defects must red and the idempotent duplicate must stay green"
	begin_check
	# One clean copy feeds the injector; each defect lands in its own fresh output,
	# so the injector never mutates the copy it reads.
	run_on 1 'cd naylamp && rm -rf data.red.src data.red.phantom data.red.missing data.red.corrupt data.red.dup && cp -r data data.red.src'

	local out
	# phantom: a committed id the workload never wrote must red.
	run_on 1 "cd naylamp && ./bin/naylamp faultlog -mode phantom -src data.red.src -out data.red.phantom -phantom-id ${PHANTOM_ID}" 2>&1 || fail "FL.red: phantom injection failed"
	out="$(verify_copy 1 data.red.phantom)"
	printf '%s\n' "${out}"
	if notfaithful "${out}"; then pass "FL.red: the phantom id was caught (exit=1)"; else fail "FL.red: a phantom committed id was NOT caught; the no-phantoms check is not live"; fi

	# missing: a dropped acked id must red.
	run_on 1 'cd naylamp && ./bin/naylamp faultlog -mode missing -src data.red.src -out data.red.missing' 2>&1 || fail "FL.red: missing injection failed"
	out="$(verify_copy 1 data.red.missing)"
	printf '%s\n' "${out}"
	if notfaithful "${out}"; then pass "FL.red: the dropped acked id was caught (exit=1)"; else fail "FL.red: a missing acked id was NOT caught; the no-gaps check is not live"; fi

	# corrupt: a byte flipped in a non-final segment must red at open.
	run_on 1 'cd naylamp && ./bin/naylamp faultlog -mode corrupt -src data.red.src -out data.red.corrupt' 2>&1 || fail "FL.red: corrupt injection failed"
	out="$(verify_copy 1 data.red.corrupt)"
	printf '%s\n' "${out}"
	if notfaithful "${out}"; then pass "FL.red: the corrupt non-final segment was caught at open (exit=1)"; else fail "FL.red: a corrupt log segment was NOT caught; the corruption check is not live"; fi

	# dup: the negative control. An idempotent duplicate must stay faithful.
	run_on 1 'cd naylamp && ./bin/naylamp faultlog -mode dup -src data.red.src -out data.red.dup' 2>&1 || fail "FL.red: dup injection failed"
	out="$(verify_copy 1 data.red.dup)"
	printf '%s\n' "${out}"
	if faithful "${out}"; then pass "FL.red: the idempotent duplicate stayed faithful (exit=0), the negative control that keeps the checker honest"; else fail "FL.red: an idempotent duplicate was flagged; the checker false-reds on a legitimate re-issue, which would make it dishonest about the property"; fi
	end_check FL.red
}

# ---- negative control -------------------------------------------------------

negative() {
	note "FL.negative: a fresh untouched copy of node 1 still verifies faithful after the reds, so the reds came from the injected defects and not from a broken instrument"
	begin_check
	run_on 1 'cd naylamp && rm -rf data.negative && cp -r data data.negative'
	local out
	out="$(verify_copy 1 data.negative)"
	printf '%s\n' "${out}"
	if faithful "${out}"; then
		pass "FL.negative: the untouched copy is still faithful (exit=0); the reds are attributable to the defects alone"
	else
		fail "FL.negative: an untouched copy did not verify faithful; the instrument is suspect and the reds cannot be trusted"
	fi
	end_check FL.negative
}

# ---- main -------------------------------------------------------------------

EXPECTED="FL.pre FL.green FL.red FL.negative FL.guard"
precondition
stop_and_copy
green
red
negative
COMPLETED=1
