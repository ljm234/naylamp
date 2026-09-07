#!/usr/bin/env bash
# p2.sh: the gate for the central property of Phase 2, and TODAY only its
# localhost rehearsal.
#
# The property is stated outside this repository, in NAYLAMP_PHASE_2.md, and its
# clause (i) is the one this gate exists for: every write the engine ACKED is
# still present and searchable after a power cut and its recovery. Clauses (ii)
# no-corruption and (iii) idempotent startup ride along where iron can reach
# them. The design is section 10 of NAYLAMP_PROPUESTA_GATE_PHASE2_2026-09-04.md,
# which lives in the workspace and never in this repository.
#
# WHICH CARRIER. Phase 2 has two and they are not interchangeable. The engine the
# phase sealed, persist.DB, is started by no binary in this tree. The carrier that
# ships is the RAFT ENTRY LOG inside naylampd, whose barrier is the f.Sync() of
# raft.Storage.AppendEntries and whose ack is the StatusOK that
# (*Node).processReady emits inside the committed-entries loop. This gate measures
# the second one and says so. That is path B, and DEFER-046 decided it.
#
# WHERE THE WITNESS LIVES, declared before anything is claimed, because DEFER-046
# made that a hard rule for any cut gate written after it. The oracle is the
# manifest of acked operations, built ON THE OPERATOR'S MACHINE from client
# operations that exited 0. It never lives on a host that gets cut. A witness
# inside the cut set is not a witness, it is another casualty.
#
# THE CUT, AND WHAT IT DOES NOT REACH. On iron the cut is
# `echo b > /proc/sysrq-trigger` inside the guest, which reboots without syncing
# and takes the guest page cache with it. The fleet's three OS disks were read on
# 2026-09-06 with `az vm show`, with the fleet powered off: caching is ReadWrite,
# so the Azure host's write cache SURVIVES that reboot. Whoever commissions this
# work chose, that same day, to run with the fleet as it is, and the reason is the
# one the design measured: moving the disks to caching None would move the fleet
# under which the Phase 1 artifacts were sealed. So the boundary is not pending,
# it is the choice, and the banner below carries it in one sentence rather than
# leaving it to an item nobody opens.
#
# TODAY THIS SCRIPT IS THE REHEARSAL AND NOTHING ELSE. The iron path refuses to
# run and names what is missing, which is clause 15's shape: an instrument that
# breaks stops whoever is measuring, and one that answers falsely lets them carry
# on. The rehearsal's job is to exercise THIS SCRIPT before it costs VM time, and
# to time three of the five terms the design could not put a number on.
#
# WHAT THE REHEARSAL CANNOT DO, and this is why its banner says it attests
# nothing about durability: on this machine there is no sysrq-b. Its cut is
# `kill -9`, which takes the process and leaves the page cache alone, so an acked
# write survives it whether or not anything ever called fsync. FOUR verdicts are
# therefore NOT RUN here, by construction and not by omission, and they print as
# such alongside the fifteen this rehearsal does run. An earlier version of this
# line said "four of the fifteen", which its own output contradicts: the fifteen
# all pass and the four are outside that list.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"
OUT_DIR="${GATE_DIR}/out"

# NAYLAMP_P2_REPO points this script at a tree that is not its own parent, and it
# exists for exactly one caller: gate/p2-guard-test.sh, whose rows are COPIES of
# this file living under the system temp directory, where the parent of the copy
# holds no go.mod. Without the seam the red arm cannot fire a single row, which is
# how it was found: every mutant died on `go build` before reaching its guard.
#
# TWO THINGS KEEP THE SEAM FROM BECOMING A HOLE. It is read only in rehearsal
# mode, so no iron run can ever be pointed somewhere else by an environment
# variable; and the tree it resolves to is printed in the BANNER, on both
# streams, before the first phase. The banner and not the provenance file, and
# the correction is the adversarial round's: provenance.txt is only written by
# the phase of that name, so `p2.sh pre` measured a foreign tree, closed green
# and named it nowhere.
if [ -n "${NAYLAMP_P2_REPO:-}" ] && [ "${NAYLAMP_P2_LOCAL:-}" = 1 ]; then
	REPO_DIR="$(cd "${NAYLAMP_P2_REPO}" && pwd)"
	OUT_DIR="${REPO_DIR}/gate/out"
fi

# ---- the run id, and the deletion rule ---------------------------------------
#
# One directory per run, named from the run id. Every removal in this script is
# written against a LITERAL prefix with the run id appended inline, never against
# a bare variable, because that pattern admits a day when the variable arrives
# empty and the deletion lands somewhere that matters. The run id is validated
# the moment it is built, so the shape this script deletes by cannot drift. That
# is clause 23 of the protocol. gate/p1.sh carries the same rule in THREE of its
# four removals, at lines 1496, 1523 and 1537; the fourth, line 1228, takes the
# escape the clause leaves written and guards a variable root with :? instead.
# Saying "the same rule since it was written" would have been one word stronger
# than the file.
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
case "${RUN_ID}" in
	[0-9]*Z-[0-9]*) ;;
	*) echo "gate: refusing to run: the run id ${RUN_ID} is not the shape this script deletes by" >&2; exit 2 ;;
esac

REHEARSAL="${NAYLAMP_P2_LOCAL:-}"

# ---- the iron path refuses, and says what is missing --------------------------
#
# Not a stub that would run and produce something. A refusal, with the list, so
# that nobody can start it believing it seals. When the list empties, this block
# is what has to be deleted on purpose, which is harder to do by accident than
# forgetting to add a check.
if [ "${REHEARSAL}" != 1 ]; then
	cat >&2 <<'IRON'
gate: p2.sh has no iron path yet, and refuses rather than pretend one.

What is missing, measured on 2026-09-06 and not guessed:

  1. No primitive for cutting the POWER exists in this tree. `grep` over the
     tracked .sh, non-test .go and .yml files finds one line carrying the word
     sysrq and it is a comment, engine/naylamp/node.go:65. Cuts of other kinds do
     exist: SIX tracked .sh files carry iptables or pfctl, which are checkquorum,
     common_red, omnibus, partition, readindex and servicehealth, and gate/tls.sh
     carries a pkill and says of itself that it adds no firewall. An earlier
     version of this line said seven and reached that cardinal by listing tls.sh
     under iptables as well as under pkill.
  2. Nothing has read /proc/sys/kernel/sysrq on the fleet. Ubuntu documents 176
     as its default, which permits the reboot bit; that is a citation, not a
     measurement of these three machines, and reading it means booting them.
  3. The red arm's mutant binary, a naylampd built without the AppendEntries
     barrier, is not built by anything here.
  4. No term of the iron cost has ever been timed: fleet boot after a sysrq-b,
     and the election after a cold start of three.

Run the rehearsal instead, which exercises this script and times the terms it
can reach:

  NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all
IRON
	exit 2
fi

# ---- the rehearsal's fleet ----------------------------------------------------
#
# Three directories on this machine play the three replicas, on loopback ports
# that no other gate uses. common.sh is deliberately NOT sourced: it demands
# NAYLAMP_GATE_HOSTS, NAYLAMP_GATE_PRIVATE and NAYLAMP_GATE_KEY, and a rehearsal
# that never opens an ssh channel has no business requiring a fleet's identity to
# run. gate/p1.sh sources it in local mode and pays exactly that friction; this
# one does not repeat it.
NODE_IDS=(1 2 3)
CLIENT_ID=90
HOSTADDR=127.0.0.1
NODE_PORTS=(0 19401 19402 19403)   # index by node id; slot 0 unused
CLIENT_PORT=19490
# The mutant fleet gets its own ports so phase_red does not have to wait for the
# sane fleet to come down, and so neither can be mistaken for the other in lsof.
MUT_PORTS=(0 19411 19412 19413)
MUT_CLIENT_PORT=19500
DIM=8

FLEET="${OUT_DIR}/p2-local-fleet-${RUN_ID}"
OUT_LOCAL="${OUT_DIR}/p2-local-${RUN_ID}"
MANIFEST="${OUT_LOCAL}/manifest.txt"
BIN="${OUT_DIR}/p2-naylampd"   # en OUT_DIR y no por corrida: eran 7.4 MiB de copia en cada ensayo
CERT_DIR="${OUT_DIR}/certs"

VERDICTS=" "
EXPECTED=""
COMPLETED=0
RUN_STARTED=0
CHECK_FAILED=0
EMITIDO=0

note() { printf 'gate: %s\n' "$*" >&2; }
pass() { printf 'gate: PASS %s\n' "$*" >&2; }
fail() { CHECK_FAILED=1; printf 'gate: FAIL %s\n' "$*" >&2; }
stop() { printf 'gate: STOP %s\n' "$*" >&2; exit 1; }

record_verdict() { VERDICTS="${VERDICTS}$1=$2 "; }
# Precedence is fail, then none, then pass, the same order gate/p1.sh uses and for
# the same reason: this gate can record "did not run", and an unrun check that a
# later line marks pass has to keep saying unrun.
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
	if [ "${CHECK_FAILED}" -eq 0 ]; then record_verdict "$1" pass; else record_verdict "$1" fail; fi
}
not_run() {
	local id="$1"; shift
	record_verdict "${id}" none
	printf 'gate: NOT RUN %s: %s\n' "${id}" "$*" >&2
}

emit_final_verdict() {
	EMITIDO=1
	if [ -z "${EXPECTED}" ]; then
		[ "${RUN_STARTED}" -eq 0 ] && return 0
		echo "gate: NOT A SUCCESS; the run began and ended with no verdict set, so no clause was checked and this run attests nothing" >&2
		return 1
	fi
	local id v bad=""
	for id in ${EXPECTED}; do
		v="$(verdict_of "${id}")"
		printf 'gate: verdict %s = %s\n' "${id}" "${v}" >&2
		[ "${v}" != pass ] && bad="${bad} ${id}(${v})"
	done
	EMITIDO=1
	if [ "${COMPLETED}" -eq 1 ] && [ -z "${bad}" ]; then
		echo "gate: all rehearsal checks passed (${EXPECTED})"
		return 0
	fi
	if [ -n "${bad}" ]; then
		echo "gate: NOT A SUCCESS; checks without a passing verdict:${bad}" >&2
	else
		echo "gate: NOT A SUCCESS; the run did not reach a clean completion" >&2
	fi
	return 1
}

# ---- timing, and it is the reason the rehearsal exists at all -----------------
#
# The design could not put a number on the iron run's cost because five of its
# terms had never been timed. Three of them are reachable here. Each is measured
# once, with its wall clock, and the banner names the machine, the toolchain and
# the load so the figure is not read as a fleet number.
T_WORKLOAD=""
T_RECOVER=""
T_OVERHEAD=""
ahora() { /usr/bin/python3 -c 'import time; print("%.3f" % time.time())'; }
delta() { /usr/bin/python3 -c "print('%.2f' % ($2 - $1))"; }

# ---- the banner, which is where the boundary is read --------------------------
#
# Printed on BOTH streams and before any phase, so it is in the console log a
# reader opens and not only in a backlog item they would have to go looking for.
# The sentence about the cut model is the one whoever commissions this work
# dictated on 2026-09-06, and it is not a summary of exclusion 17, it is the
# exclusion.
banner() {
	# THE TEXT IS EMITTED, NOT CAPTURED, and that is a measured trap rather than a
	# preference. This used to be b=$(cat <<BANNER ... BANNER) followed by two
	# printfs. Inside a command substitution bash tracks the quotes of the content
	# even when the content is a here-document, so the banner had to carry an EVEN
	# number of apostrophes to parse at all. It carried two. On 2026-09-07 a
	# sentence with a third was added and the whole script stopped parsing, with
	# the error reported three hundred lines away inside an unrelated case. A pipe
	# to tee duplicates the stream without any substitution, so no invisible
	# condition is left on what the banner may say.
	cat <<BANNER | tee /dev/stderr
================================================================================
NAYLAMP PHASE 2 GATE, REHEARSAL ONLY. run id p2-local-${RUN_ID}
This is NOT gate evidence and it seals nothing.

WHAT THIS REHEARSAL EXERCISES: this script. Three directories on 127.0.0.1 play
three replicas, the binaries are native, and there is no fleet.

WHAT IT DOES NOT EXERCISE: the property. Its cut is kill -9, which takes the
process and leaves the page cache alone, so an acked write survives it whether or
not anything ever called fsync. Four verdicts are NOT RUN here by construction:
P2.pre.sysrq, P2.cut.bytes, P2.red.barrier and P2.red.fires.

THE SENTENCE THE IRON ARTIFACT WILL CARRY, printed here so the rehearsal and the
run declare the same boundary: this gate exercises over a real kernel, a real
filesystem, three real machines and a real election, and it does NOT exercise a
cut model different from the simulation's. The fleet's three OS disks are
caching: ReadWrite, read on 2026-09-06 with the fleet powered off, so the host
write cache survives the guest reboot. That is the choice, not a pending item.
And it stopped being a reading on 2026-09-07: naylamp-1 was powered on, cut with
echo b > /proc/sysrq-trigger and read back. It stopped answering 6 s after the
cut and answered again 14 s after it, the cut being the mandate plus a deliberate
three second delay. The journal DID need recovery, and the boot before it, a
normal one from deallocate, did not: that difference is what says the cut cut,
and at least 39 s of that boot's journal never reached the disk.

Two files fsynced before the cut both survived, the one whose directory was also
fsynced and the one whose was not. That is a bounded result and it is written as
one: it says the DEFER-028 gap did not materialise on ext4 in ordered data mode
under this cut. It does not say why, and this gate does not need it to.

TREE MEASURED: ${REPO_DIR}
CARRIER: the Raft entry log inside naylampd, which is the half that makes its
directory entry durable. raft.openFreshSegment calls fsyncDir(s.dir)
(engine/raft/storage.go:455 and :460); persist.openActiveSegment returns without
it (engine/persist/wal.go:149), and fsyncDir appears zero times in that file.
That gap is DEFER-028 and this gate does NOT exercise it: persist.DB is out by
name, and no binary in this tree starts one. Outside its own package, persist is
used only for encoding helpers.
WITNESS: the manifest of acked client operations, built on this machine, outside
anything that gets cut.
================================================================================
BANNER
}

# vec_for prints the vector this rehearsal gives an id: its binary expansion over
# DIM coordinates. The shape is not decoration and the first version got it wrong.
# The index measures vector.CosineDistance, which is blind to magnitude, so any
# two collinear vectors are the SAME point to it. The first workload used
# (id%7, id%5, id%3), and there ids 1 and 2 came out (1,1,1) and (2,2,2), parallel
# and at cosine distance zero from each other: the query for id 1 returned id 2
# with dist=-3.6e-08. Distinct binary patterns are never collinear, because two
# 0/1 vectors are scalar multiples only when they are equal.
vec_for() {
	local id="$1" j out=""
	for j in $(seq 0 $((DIM - 1))); do
		[ -n "${out}" ] && out="${out},"
		out="${out}$(( (id >> j) & 1 ))"
	done
	printf '%s' "${out}"
}

# ---- fleet helpers ------------------------------------------------------------

peers_of() {
	local n="$1" peers="" j
	for j in "${NODE_IDS[@]}"; do
		if [ "$j" != "$n" ]; then
			[ -n "$peers" ] && peers="${peers},"
			peers="${peers}${j}=${HOSTADDR}:${NODE_PORTS[$j]}"
		fi
	done
	printf '%s' "${peers}"
}

group_spec() {
	local g="" j
	for j in "${NODE_IDS[@]}"; do
		[ -n "$g" ] && g="${g},"
		g="${g}${j}=${HOSTADDR}:${NODE_PORTS[$j]}"
	done
	printf '%s' "${g}"
}

tls_env_for() {
	printf 'NAYLAMP_TLS_CERT=%s/node-%s.pem NAYLAMP_TLS_KEY=%s/node-%s-key.pem NAYLAMP_TLS_CA=%s/ca.pem' \
		"${CERT_DIR}" "$1" "${CERT_DIR}" "$1" "${CERT_DIR}"
}

launch_node() {
	local n="$1" dir="${FLEET}/node${n}"
	mkdir -p "${dir}"
	NAYLAMP_TLS_CERT="${CERT_DIR}/node-${n}.pem" \
	NAYLAMP_TLS_KEY="${CERT_DIR}/node-${n}-key.pem" \
	NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
	nohup "${BIN}" node \
		-id "${n}" \
		-listen "${HOSTADDR}:${NODE_PORTS[$n]}" \
		-peers "$(peers_of "$n")" \
		-client "${CLIENT_ID}=${HOSTADDR}:${CLIENT_PORT}" \
		-dir "${dir}/data" \
		-dim "${DIM}" \
		</dev/null >>"${FLEET}/node${n}.log" 2>&1 &
	echo $! > "${OUT_LOCAL}/node${n}.pid"
	# EVERY pid this run ever launched is appended here, and the cleanup kills
	# from this list and not from the per node file. The reason is a hole the
	# adversarial round demonstrated: phase_recover relaunches a cut replica, and
	# launch_node OVERWRITES node<N>.pid, so if the cut had failed to kill the
	# old process its pid was lost and nothing behind could reach it. Measured
	# that day: with only node 2 cut, the run ended and pid 35900 was still
	# listening on 127.0.0.1:19401 over a data directory that had already been
	# removed.
	echo $! >> "${OUT_LOCAL}/pids.txt"
}

node_pid() { cat "${OUT_LOCAL}/node$1.pid" 2>/dev/null || true; }
node_alive() { local p; p="$(node_pid "$1")"; [ -n "${p}" ] && kill -0 "${p}" 2>/dev/null; }

# Waits for a node's log to show it listening. A fixed sleep would either waste
# time or race; the log line is the event itself.
# lineas_listening counts how many times this node has announced it is listening.
# The COUNT and not the presence, and that distinction is a false green this bench
# caught on 2026-09-06: the log is APPENDED across launches, so after the first
# start the line is there forever, and a recover check written as `grep -q` passed
# for a replica that had never been relaunched. The mutation that removed the
# relaunch left P2.recover.boots green, which is what the row was written to see.
lineas_listening() {
	grep -c 'listening' "${FLEET}/node$1.log" 2>/dev/null || echo 0
}

# Waits for a node to announce it is listening MORE times than it had, and for its
# pid to be alive. A fixed sleep would either waste time or race; the log line is
# the event itself, and the pid is what says the event belongs to a live process.
wait_listening() {
	local n="$1" antes="${2:-0}" i
	for i in $(seq 1 100); do
		if [ "$(lineas_listening "$n")" -gt "${antes}" ] && node_alive "$n"; then
			return 0
		fi
		sleep 0.1
	done
	return 1
}

client_op() {
	local out rc
	set +e
	out="$(NAYLAMP_TLS_CERT="${CERT_DIR}/node-${CLIENT_ID}.pem" \
		NAYLAMP_TLS_KEY="${CERT_DIR}/node-${CLIENT_ID}-key.pem" \
		NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
		"${BIN}" client \
			-listen "${HOSTADDR}:${CLIENT_PORT}" \
			-group "$(group_spec)" \
			-dim "${DIM}" \
			"$@" </dev/null 2>&1)"
	rc=$?
	set -e
	printf '%s\nexit=%d\n' "${out}" "${rc}"
}
committed() { printf '%s' "$1" | grep -q 'exit=0$'; }

# manifest_put appends to the manifest ONLY when the client exited 0, so the
# manifest is exactly the acked set and never the attempted set. That is the
# whole reason the manifest can serve as an oracle.
manifest_put() {
	local id="$1" vec="$2" out
	out="$(client_op -op put -id "${id}" -vec "${vec}")"
	if committed "${out}"; then
		echo "put ${id} ${vec}" >> "${MANIFEST}"
		return 0
	fi
	printf '%s\n' "${out}" >> "${OUT_LOCAL}/client-failures.txt"
	return 1
}
manifest_del() {
	local id="$1" out
	out="$(client_op -op del -id "${id}")"
	if committed "${out}"; then
		echo "del ${id}" >> "${MANIFEST}"
		return 0
	fi
	printf '%s\n' "${out}" >> "${OUT_LOCAL}/client-failures.txt"
	return 1
}

entry_log_bytes() {
	local n="$1" t=0 f
	for f in "${FLEET}/node${n}/data"/raft-*.log; do
		[ -e "${f}" ] || continue
		t=$(( t + $(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}") ))
	done
	printf '%d' "${t}"
}

# ---- phases -------------------------------------------------------------------

# THE RUNNING MARKER, and it is the FIRST byte written into the artifact rather
# than a detail of the build phase. It exists because make clean has now killed a
# live rehearsal TWICE, on 2026-08-28 and on 2026-09-07, and both times the sweep
# took gate/out out from under a run that was still writing. The predicate that
# matters is not the file, it is the PROCESS: a marker whose pid is gone must not
# block a clean forever, which is how a defence gets switched off for being in the
# way. So the marker carries the pid and whoever reads it asks the operating system.
#
# WHAT IT DOES NOT COVER, said here and not left to be discovered. A marker whose
# process died does NOT protect its directory, on purpose, so a run killed with -9
# leaves an artifact that the next clean sweeps. A pid can be REUSED, so a stale
# marker whose number now belongs to some unrelated process reads as alive and
# blocks a clean until somebody removes it by hand. When this was written gate/p1.sh
# wrote NO marker, so a live NAYLAMP_P1_LOCAL=1 rehearsal was still swept exactly as
# one was on 2026-08-28, which is the incident this piece cites as half of its
# reason. That half closed the same day, a few hours later: gate/p1.sh writes one
# now. The first two are the cheap side of the trade, and the expensive side was
# losing a running gate.
escribe_running() {
	printf 'pid: %s\nrun: p2-local-%s\nstarted: %s\nscript: %s\nhost: %s\n' \
		"$$" "${RUN_ID}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "gate/p2.sh" "$(hostname)" \
		> "${OUT_LOCAL}/RUNNING"
}

retira_running() {
	# The removal is written against a LITERAL prefix with the run id appended
	# inline, never a bare variable, and only if the file this run wrote is the one
	# being removed. Clause 23.
	#
	# AND IT ASSERTS THAT THE LITERAL AND OUT_LOCAL ARE THE SAME PATH, which they are
	# today only because line 150 says so and nothing checked it. A reader measured
	# what that costs on the day the iron path lands: OUT_LOCAL becomes p2-<run id>,
	# this function walks p2-local-<run id>, finds nothing, returns 0, and the marker
	# outlives the run. Every later make clean would then announce the remains of a
	# run that did not finish, forever, over a directory it never sweeps. Clause 23
	# justifies the literal in a REMOVAL; it does not justify deriving the write and
	# the removal by two different routes.
	if [ "${OUT_LOCAL}" != "${OUT_DIR}/p2-local-${RUN_ID}" ]; then
		echo "gate: RUNNING marker NOT removed: the artifact is ${OUT_LOCAL} and this removal only knows p2-local-${RUN_ID}" >&2
		return 0
	fi
	[ -f "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING" ] || return 0
	grep -q "^pid: $$\$" "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING" || return 0
	rm -f -- "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING"
}

phase_build() {
	begin_check
	mkdir -p "${OUT_DIR}" "${OUT_LOCAL}" "${FLEET}"
	escribe_running
	note "rehearsal: building naylampd NATIVE; on iron this build is linux/arm64 static and comes from gate/build.sh"
	( cd "${REPO_DIR}" && go build -o "${BIN}" ./engine/cmd/naylampd ) || stop "naylampd did not build"
	note "built naylampd $(stat -f%z "${BIN}" 2>/dev/null || stat -c%s "${BIN}") bytes, sha256 $(shasum -a 256 "${BIN}" | cut -c1-16)"

	# Certificates. gate/build.sh owns the freshness rule and its comment records
	# what a weaker version cost, so this calls it rather than re-deriving it.
	# Measured on 2026-09-06: the material under gate/out/certs had expired on
	# 2026-08-11, so a rehearsal that assumed it was usable would have died in a
	# mutual TLS handshake with no leader.
	local stale=0 id
	for id in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		# The KEY is checked too, and its absence is a real failure mode this
		# guard used to miss: a directory with valid certificates and no
		# node-<id>-key.pem does not re-mint, and the run then dies in the mutual
		# TLS handshake with no leader, which is exactly what gate/build.sh's own
		# comment calls a slow thing to diagnose.
		if [ ! -f "${CERT_DIR}/node-${id}.pem" ] || [ ! -f "${CERT_DIR}/node-${id}-key.pem" ] || \
		   ! openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend 7200 >/dev/null 2>&1; then
			stale=1
		fi
	done
	if [ ! -f "${CERT_DIR}/ca.pem" ] || ! openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend 7200 >/dev/null 2>&1; then
		stale=1
	fi
	if [ "${stale}" -eq 1 ]; then
		note "certificates missing or within two hours of expiry: re-minting through gate/build.sh"
		( cd "${REPO_DIR}" && ./gate/build.sh ) >>"${OUT_LOCAL}/build.log" 2>&1 || stop "gate/build.sh failed while minting certificates"
	else
		note "certificates present and not expiring within two hours: reused"
	fi
	# P2.build EXISTS SO THAT `p2.sh build` CAN SUCCEED. Without it that
	# subcommand ran, built correctly, and then closed with "the run began and
	# ended with no verdict set, so no clause was checked and this run attests
	# nothing", every single time. The message was right about the mechanism and
	# wrong about the run, and the fix is not to special case the subcommand: it
	# is to give the phase the verdict it always deserved.
	local id
	[ -x "${BIN}" ] || fail "P2.build: ${BIN} is missing or not executable"
	for id in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		[ -f "${CERT_DIR}/node-${id}.pem" ] || fail "P2.build: no certificate for id ${id}"
		[ -f "${CERT_DIR}/node-${id}-key.pem" ] || fail "P2.build: no private key for id ${id}"
		openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend 7200 >/dev/null 2>&1 \
			|| fail "P2.build: the certificate for id ${id} is expired or expires within two hours"
	done
	[ -f "${CERT_DIR}/ca.pem" ] || fail "P2.build: no CA certificate"
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.build: naylampd built and the TLS material for ${#NODE_IDS[@]} nodes plus the client is present and not expiring within two hours"
	end_check P2.build
}

phase_pre() {
	begin_check
	local n
	for n in "${NODE_IDS[@]}"; do
		launch_node "${n}"
	done
	for n in "${NODE_IDS[@]}"; do
		if wait_listening "${n}" 0; then
			note "node ${n} listening on ${HOSTADDR}:${NODE_PORTS[$n]}, pid $(node_pid "$n")"
		else
			fail "P2.pre.fleet: node ${n} never reported listening"
		fi
	done
	# A leader has to exist before anything commits, and the probe that proves it
	# must NOT write. The first version probed with a put of id 999999 kept out of
	# the manifest, and verify-log called it exactly what it was: a phantom,
	# committed but never emitted by the workload, on all three replicas. A read
	# needs a leader too and leaves no entry, so the probe is a search.
	local out i ok=0
	for i in $(seq 1 40); do
		out="$(client_op -op search -vec "$(vec_for 1)" -k 1)"
		if committed "${out}"; then ok=1; break; fi
		sleep 0.25
	done
	if [ "${ok}" -eq 1 ]; then
		[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.pre.fleet: the three replicas reported listening and a query was served, so a leader exists and nothing was written to prove it"
	else
		fail "P2.pre.fleet: no query was served in ten seconds, so no leader formed"
	fi
	end_check P2.pre.fleet

	# THE FIRST VERSION OF THIS CHECK WAS A TAUTOLOGY and it is worth the lines,
	# because it was one of the eleven greens. It read `want=$(shasum ...)` and
	# then `got="${want}"`, so it compared a variable with itself and its fail
	# branch was dead code. The adversarial round of 2026-09-06 did not argue it,
	# it demonstrated it: node 3 relaunched from a DIFFERENT binary and the check
	# still printed PASS with the old digest, and the run closed green.
	#
	# What it asks now is answerable and can be wrong: every replica that is up
	# has to be executing THE FILE THIS RUN BUILT. `ps -o args=` prints the
	# command line as invoked, and launch_node invokes BIN by absolute path, so a
	# replica running anything else shows it. The shared binary in gate/out makes
	# this worth asking rather than academic: a second run rebuilding it while
	# this one is up is exactly the drift the check now sees.
	begin_check
	local n args vistos=0
	for n in "${NODE_IDS[@]}"; do
		node_alive "$n" || { fail "P2.pre.identity: node ${n} is not running, so its binary cannot be read"; continue; }
		args="$(ps -p "$(node_pid "$n")" -o args= 2>/dev/null || true)"
		case "${args}" in
			"${BIN} node"*) vistos=$((vistos + 1)) ;;
			"") fail "P2.pre.identity: node ${n} did not answer with its command line" ;;
			*) fail "P2.pre.identity: node ${n} is executing [${args%% *}] and this run built [${BIN}]" ;;
		esac
	done
	if [ "${vistos}" -ne "${#NODE_IDS[@]}" ]; then
		fail "P2.pre.identity: ${vistos} of ${#NODE_IDS[@]} replicas confirmed against the binary this run built"
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.pre.identity: the ${vistos} replicas are executing ${BIN}, sha256 $(shasum -a 256 "${BIN}" | cut -c1-16) (on iron this compares three uploads by digest)"
	end_check P2.pre.identity

	not_run P2.pre.sysrq "there is no /proc/sys/kernel/sysrq on this machine and no sysrq-b to permit; on iron this reads the value on all three hosts and fails loudly if the reboot bit is off"
}

phase_provenance() {
	begin_check
	local head dirty
	# Both reads are allowed to come back empty instead of aborting the run, so
	# the check below can call it a failure and the artifact says so. Under set -e
	# a bare failing substitution would kill the run and leave no verdict at all,
	# which is the shape clause 15 calls worse than a break.
	head="$(cd "${REPO_DIR}" && git rev-parse HEAD 2>/dev/null || true)"
	dirty="$(cd "${REPO_DIR}" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ' || true)"
	note "HEAD ${head}"
	note "uncommitted entries: ${dirty}"
	note "toolchain $(go version)"
	note "run id p2-local-${RUN_ID}"
	{
		echo "run: p2-local-${RUN_ID}"
		echo "head: ${head}"
		echo "uncommitted: ${dirty}"
		echo "toolchain: $(go version)"
		echo "repo: ${REPO_DIR}"
		echo "naylampd sha256: $(shasum -a 256 "${BIN}" | cut -d' ' -f1)"
		echo "machine: $(uname -sr) $(sysctl -n hw.model 2>/dev/null || echo unknown)"
		echo "load at start: $(uptime | sed 's/.*load averages*: //')"
	} > "${OUT_LOCAL}/provenance.txt"
	# A rehearsal does not require a clean tree: it exists to be run while the
	# script is being written, which is the state the tree is in. It records the
	# count instead of refusing on it, and the iron path is where refusing
	# belongs. What it DOES require is that the recording happened, and the first
	# version did not ask: it called pass unconditionally, so the verdict could
	# not go red for any reason at all. Two things can be wrong here and both are
	# now asked: the tree may not answer for its own head, and the file may end up
	# empty or missing.
	if [ -z "${head}" ]; then
		fail "P2.provenance: ${REPO_DIR} did not answer with a head, so nothing anchors this run"
	fi
	if [ ! -s "${OUT_LOCAL}/provenance.txt" ]; then
		fail "P2.provenance: provenance.txt is missing or empty, so the run recorded nothing"
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.provenance: head ${head:0:12}, ${dirty} uncommitted entries, toolchain and binary digest written to provenance.txt"
	end_check P2.provenance
}

phase_workload() {
	begin_check
	local t0 t1 i n_ok=0 n_try=0
	: > "${MANIFEST}"
	t0="$(ahora)"
	for i in $(seq 1 30); do
		n_try=$((n_try + 1))
		if manifest_put "${i}" "$(vec_for "${i}")"; then n_ok=$((n_ok + 1)); fi
	done
	for i in 3 11 19; do
		n_try=$((n_try + 1))
		if manifest_del "${i}"; then n_ok=$((n_ok + 1)); fi
	done
	t1="$(ahora)"
	T_WORKLOAD="$(delta "${t0}" "${t1}")"
	local lines
	lines="$(wc -l < "${MANIFEST}" | tr -d ' ')"
	note "workload: ${n_ok} of ${n_try} operations acked, manifest holds ${lines} lines, ${T_WORKLOAD}s"
	# Anti-vacuity, and it is the guard that keeps an empty manifest from reading
	# as a clean run: the manifest must be non-empty AND its length must equal the
	# number of operations that exited 0. A manifest that silently lost a line
	# would make every later check easier to pass.
	if [ "${lines}" -eq 0 ]; then
		fail "P2.workload.acked: the manifest is empty, so every later check would be vacuous"
	elif [ "${lines}" -ne "${n_ok}" ]; then
		fail "P2.workload.acked: ${n_ok} operations exited 0 and the manifest holds ${lines} lines"
	elif [ "${n_ok}" -ne "${n_try}" ]; then
		fail "P2.workload.acked: ${n_try} operations attempted and only ${n_ok} acked"
	else
		pass "P2.workload.acked: ${n_ok} of ${n_try} acked and the manifest holds exactly those ${lines}"
	fi
	end_check P2.workload.acked
}

phase_cut() {
	begin_check
	local n before after cut_any=0
	declare -a PID_BEFORE=() BYTES_BEFORE=()
	for n in "${NODE_IDS[@]}"; do
		PID_BEFORE[$n]="$(node_pid "$n")"
		BYTES_BEFORE[$n]="$(entry_log_bytes "$n")"
	done
	note "cutting nodes 1 and 2 with kill -9; on iron this is echo b > /proc/sysrq-trigger on at least two of three"
	for n in 1 2; do
		kill -9 "${PID_BEFORE[$n]}" 2>/dev/null || true
	done
	sleep 1
	for n in 1 2; do
		if node_alive "$n"; then
			fail "P2.cut.fired: node ${n} is still alive after the cut"
		else
			note "node ${n} pid ${PID_BEFORE[$n]} is gone"
		fi
	done
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.cut.fired: the two cut replicas are gone"
	end_check P2.cut.fired

	for n in 1 2; do
		after="$(entry_log_bytes "$n")"
		before="${BYTES_BEFORE[$n]}"
		note "node ${n} entry log: ${before} bytes before the cut, ${after} after"
		[ "${after}" -lt "${before}" ] && cut_any=$((cut_any + 1))
	done
	not_run P2.cut.bytes "kill -9 does not evict the page cache, so nothing on disk can be lost here and a green would attest nothing; measured this run, bytes lost across the cut: ${cut_any} of 2 replicas. On iron this guard compares raft-<n>.log sizes across a sysrq-b and records none, never pass, when nothing was cut"
}

phase_recover() {
	begin_check
	local n t0 t1
	t0="$(ahora)"
	declare -a ANTES_LISTEN=()
	for n in 1 2; do
		ANTES_LISTEN[$n]="$(lineas_listening "$n")"
	done
	for n in 1 2; do
		launch_node "${n}"
	done
	for n in 1 2; do
		if wait_listening "${n}" "${ANTES_LISTEN[$n]}"; then
			note "node ${n} came back, pid $(node_pid "$n")"
		else
			fail "P2.recover.boots: node ${n} did not come back"
		fi
	done
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.recover.boots: the cut replicas started from their own directories"
	end_check P2.recover.boots

	begin_check
	local out i ok=0
	for i in $(seq 1 40); do
		out="$(client_op -op search -vec "$(vec_for 1)" -k 3)"
		if committed "${out}"; then ok=1; break; fi
		sleep 0.25
	done
	if [ "${ok}" -eq 1 ]; then
		pass "P2.recover.elects: a query was served after the cut, so a leader exists again"
	else
		fail "P2.recover.elects: no query was served in ten seconds after the cut"
	fi
	end_check P2.recover.elects

	# Every acked id present and searchable, with zero tolerance: the first
	# missing id fails the check. The set comes from the manifest, which is the
	# oracle, and not from anything the cluster reports about itself.
	begin_check
	local id vivos=0 ausentes=0
	# The live set is every id put and not later deleted, in manifest order.
	/usr/bin/python3 - "${MANIFEST}" > "${OUT_LOCAL}/live-ids.txt" <<'PY'
import sys
vivos = []
for renglon in open(sys.argv[1], encoding='utf-8'):
    p = renglon.split()
    if not p:
        continue
    if p[0] == 'put' and p[1] not in vivos:
        vivos.append(p[1])
    elif p[0] == 'del' and p[1] in vivos:
        vivos.remove(p[1])
print('\n'.join(vivos))
PY
	while read -r id; do
		[ -z "${id}" ] && continue
		out="$(client_op -op search -vec "$(vec_for "${id}")" -k 1)"
		if committed "${out}" && printf '%s' "${out}" | grep -q "^id=${id} "; then
			vivos=$((vivos + 1))
		else
			ausentes=$((ausentes + 1))
			fail "P2.recover.acked: acked id ${id} did not come back; the query answered: $(printf '%s' "${out}" | tr '\n' '|')"
			break
		fi
	done < "${OUT_LOCAL}/live-ids.txt"
	if [ "${ausentes}" -eq 0 ] && [ "${vivos}" -gt 0 ]; then
		pass "P2.recover.acked: all ${vivos} live acked ids came back and are searchable"
	elif [ "${vivos}" -eq 0 ] && [ "${ausentes}" -eq 0 ]; then
		fail "P2.recover.acked: the live set was empty, so this check saw nothing"
	fi
	end_check P2.recover.acked

	# verify-log and state-hash run on COLD COPIES, never on the live directory:
	# both open their argument read-write, and auditing the original would be
	# auditing something the audit itself can change.
	begin_check
	local copia
	for n in "${NODE_IDS[@]}"; do
		copia="${OUT_LOCAL}/cold-node${n}"
		rm -rf -- "${OUT_LOCAL}/cold-node${n}"
		cp -R "${FLEET}/node${n}/data" "${copia}"
		set +e
		"${BIN}" verify-log -id "${n}" -peers "$(peers_of "$n")" -dir "${copia}" -manifest "${MANIFEST}" -dim "${DIM}" \
			> "${OUT_LOCAL}/verify-node${n}.txt" 2>&1
		rc=$?
		set -e
		if [ "${rc}" -eq 0 ]; then
			note "node ${n} committed log verifies faithful against the manifest"
		else
			fail "P2.recover.faithful: node ${n} did not verify faithful (exit ${rc}); see verify-node${n}.txt"
		fi
	done
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.recover.faithful: the three cold copies verify faithful against the acked manifest"
	end_check P2.recover.faithful

	begin_check
	local h1 h2 r1 r2
	copia="${OUT_LOCAL}/cold-node1"
	# The EXIT CODE is read, and it was not before: the check compared two tails
	# of a stream that carried stderr, so two identical error messages would have
	# read as two equal digests. What stopped that from happening was pipefail,
	# which turns the failure into an abort instead of a red, and an abort is the
	# shape that used to leave the run with no verdict block at all.
	set +e
	h1="$("${BIN}" state-hash -id 1 -peers "$(peers_of 1)" -dir "${copia}" -dim "${DIM}" 2>/dev/null | tail -1)"; r1=$?
	h2="$("${BIN}" state-hash -id 1 -peers "$(peers_of 1)" -dir "${copia}" -dim "${DIM}" 2>/dev/null | tail -1)"; r2=$?
	set -e
	if [ "${r1}" -ne 0 ] || [ "${r2}" -ne 0 ]; then
		fail "P2.recover.idem: state-hash exited ${r1} and ${r2}, so there is no digest to compare"
	elif [ -n "${h1}" ] && [ "${h1}" = "${h2}" ]; then
		pass "P2.recover.idem: two recoveries from the same directory give the same digest, ${h1}"
	else
		fail "P2.recover.idem: two recoveries gave [${h1}] and [${h2}]"
	fi
	end_check P2.recover.idem
	t1="$(ahora)"
	T_RECOVER="$(delta "${t0}" "${t1}")"
	note "recovery and its verification took ${T_RECOVER}s"
}

# ---- the red arm, taken apart -------------------------------------------------
#
# WHY THIS PHASE EXISTS AT ALL, and it is the correction of 2026-09-06. Until
# that day the whole red arm was two NOT RUN lines, so the first time anything of
# it ever ran would have been on iron, with three VMs powered on and billing. A
# red arm declared and never fired is what this house has spent months retiring,
# and the same day had already produced four green verdicts that attested nothing,
# one of them caught by an adversarial reader who FIRED it instead of arguing it.
#
# So the arm is taken apart and each part is asked whether it can run here. Three
# of four can, and they run. The fourth is named.
#
#   P2.red.mutation  the mutation applies to the tree, the mutant builds, and its
#                    binary differs from the sane one. Runs here.
#   P2.red.bites     under that mutation the tree's OWN durability defenders go
#                    RED, and under the sane tree the same two are GREEN. Runs
#                    here, and this is the part that matters most: a mutation
#                    that does not reach the site proves nothing about the arm,
#                    which is what the DEFER-077 census measured for every red arm
#                    in this house.
#   P2.red.daemon    three replicas launched on the MUTANT binary form a cluster,
#                    elect a leader and ack a write. Runs here, and it is what
#                    keeps the iron arm from dying before its cut with the fleet
#                    powered on.
#   P2.red.barrier   the mutant, under a REAL cut, LOSES an acked write. Does NOT
#                    run here and cannot: kill -9 leaves the page cache alone, so
#                    the mutant returns everything the sane build returns.
#   P2.red.fires     the mutant's own cut guard, which needs the cut above.
#
# THE MUTANT TREE IS A COPY OF THE TRACKED WORKING TREE, not of HEAD, so what the
# arm mutates is what this run measured. It lives outside the repository and
# hygiene removes it.
MUT_ROOT="${TMPDIR:-/tmp}/naylamp-p2-mut-${RUN_ID}"
MUT_MARCA="${MUT_ROOT}/.naylamp-p2-mut"

mut_peers_of() {
	local n="$1" peers="" j
	for j in "${NODE_IDS[@]}"; do
		if [ "$j" != "$n" ]; then
			[ -n "$peers" ] && peers="${peers},"
			peers="${peers}${j}=${HOSTADDR}:${MUT_PORTS[$j]}"
		fi
	done
	printf '%s' "${peers}"
}

phase_red() {
	begin_check
	local mutante="${MUT_ROOT}/naylampd-mutante"
	mkdir -p "${MUT_ROOT}/arbol"
	: > "${MUT_MARCA}"
	# Only the files git tracks, with their CURRENT content, so gate/out and .git
	# are excluded by construction rather than by a list that could go stale.
	( cd "${REPO_DIR}" && git ls-files -z | xargs -0 tar cf - ) | ( cd "${MUT_ROOT}/arbol" && tar xf - ) \
		|| fail "P2.red.mutation: could not copy the tracked tree"
	# The heredoc runs under `if !` and not followed by a `$?` test, because a
	# bare failing command dies under set -e before any check of its status can
	# run. The first version of this block wrote `if [ $? -ne 0 ]` underneath and
	# that branch was unreachable: its message never printed once. It is the same
	# defect this file records having caught in itself twice on the same day.
	if ! /usr/bin/python3 - "${MUT_ROOT}/arbol/engine/raft/storage.go" <<'MUTPY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
a = """	if err := s.active.Sync(); err != nil {
		return fmt.Errorf("raft: fsync entries: %w", err)
	}
	s.lastIndex = entries[len(entries)-1].Index"""
b = """	// red arm mutation: the AppendEntries barrier removed.
	s.lastIndex = entries[len(entries)-1].Index"""
if s.count(a) != 1:
    sys.exit("the barrier is not where this arm expects it: %d occurrences" % s.count(a))
open(p, 'w', encoding='utf-8').write(s.replace(a, b))
MUTPY
	then
		fail "P2.red.mutation: the barrier is not where this arm expects it in engine/raft/storage.go"
	fi
	( cd "${MUT_ROOT}/arbol" && go build -o "${mutante}" ./engine/cmd/naylampd ) >>"${OUT_LOCAL}/red-build.log" 2>&1 \
		|| fail "P2.red.mutation: the mutant did not build"
	if [ -f "${mutante}" ] && cmp -s "${BIN}" "${mutante}"; then
		fail "P2.red.mutation: the mutant binary is byte identical to the sane one, so the mutation never reached the compiler"
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.red.mutation: barrier removed, mutant built, sha256 $(shasum -a 256 "${mutante}" | cut -c1-16) against the sane $(shasum -a 256 "${BIN}" | cut -c1-16)"
	end_check P2.red.mutation

	# THE MUTATION HAS TO REACH THE SITE, and both sides are run because only the
	# pair says anything: a test that is red on the mutant and red on the sane
	# tree is a broken test, not a caught mutation.
	begin_check
	local rc_mut_raft rc_san_raft rc_mut_clu rc_san_clu
	set +e
	( cd "${MUT_ROOT}/arbol/engine" && go test -count=1 -run 'TestDropUnsynced_AppendedEntriesSurvivePowerLoss' ./raft/ ) \
		>"${OUT_LOCAL}/red-mut-raft.log" 2>&1; rc_mut_raft=$?
	( cd "${MUT_ROOT}/arbol/engine" && go test -count=1 -run 'TestQuorumPowerLoss_AcknowledgedWriteSurvives' ./naylamp/ ) \
		>"${OUT_LOCAL}/red-mut-cluster.log" 2>&1; rc_mut_clu=$?
	( cd "${REPO_DIR}/engine" && go test -count=1 -run 'TestDropUnsynced_AppendedEntriesSurvivePowerLoss' ./raft/ ) \
		>"${OUT_LOCAL}/red-sane-raft.log" 2>&1; rc_san_raft=$?
	( cd "${REPO_DIR}/engine" && go test -count=1 -run 'TestQuorumPowerLoss_AcknowledgedWriteSurvives' ./naylamp/ ) \
		>"${OUT_LOCAL}/red-sane-cluster.log" 2>&1; rc_san_clu=$?
	set -e
	# THE EXIT CODE IS NOT ENOUGH, and this house paid for that line. The first
	# version read the four rc values and nothing else, and `go test` on a package
	# that does not COMPILE also exits non zero. So a mutation that never reached
	# the compiler read as a defender going red: reproduced on 2026-09-06 with a
	# mutation that produced invalid Go, where P2.red.mutation went fail and this
	# check printed PASS on the same run, asserting logs it had never opened.
	#
	# What it asks now is the line the defender itself prints. A red has to carry
	# `--- FAIL: <the exact test>` and a green has to carry `ok`, and a mutant log
	# that says the build failed or that there was nothing to run is neither.
	local T_RAFT='TestDropUnsynced_AppendedEntriesSurvivePowerLoss'
	local T_CLU='TestQuorumPowerLoss_AcknowledgedWriteSurvives'
	grep -q "build failed\|no tests to run\|cannot find package" "${OUT_LOCAL}/red-mut-raft.log" \
		&& fail "P2.red.bites: the mutant tree did not even build for engine/raft, so nothing was measured"
	grep -q "build failed\|no tests to run\|cannot find package" "${OUT_LOCAL}/red-mut-cluster.log" \
		&& fail "P2.red.bites: the mutant tree did not even build for engine/naylamp, so nothing was measured"
	grep -q -- "--- FAIL: ${T_RAFT}" "${OUT_LOCAL}/red-mut-raft.log" \
		|| fail "P2.red.bites: ${T_RAFT} did not print its own FAIL line under the mutation"
	grep -q -- "--- FAIL: ${T_CLU}" "${OUT_LOCAL}/red-mut-cluster.log" \
		|| fail "P2.red.bites: ${T_CLU} did not print its own FAIL line under the mutation"
	grep -qE '^ok[[:space:]]' "${OUT_LOCAL}/red-sane-raft.log" \
		|| fail "P2.red.bites: engine/raft is not clean on the SANE tree, so its red on the mutant proves nothing"
	grep -qE '^ok[[:space:]]' "${OUT_LOCAL}/red-sane-cluster.log" \
		|| fail "P2.red.bites: engine/naylamp is not clean on the SANE tree"
	[ "${rc_mut_raft}" -eq 0 ] && fail "P2.red.bites: engine/raft exited 0 under the mutation"
	[ "${rc_mut_clu}" -eq 0 ] && fail "P2.red.bites: engine/naylamp exited 0 under the mutation"
	[ "${rc_san_raft}" -ne 0 ] && fail "P2.red.bites: engine/raft exited non zero on the SANE tree"
	[ "${rc_san_clu}" -ne 0 ] && fail "P2.red.bites: engine/naylamp exited non zero on the SANE tree"
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.red.bites: ${T_RAFT} and ${T_CLU} each printed their own FAIL line under the mutation, and both packages print ok on the sane tree"
	end_check P2.red.bites

	# AND THE MUTANT HAS TO RUN AS A DAEMON. On iron this is what stands between
	# the arm and a fleet powered on for nothing: a mutant that cannot form a
	# cluster would take the whole session with it, and finding that out there
	# costs VM time.
	begin_check
	local n out i ok=0 mgroup=""
	for n in "${NODE_IDS[@]}"; do
		mkdir -p "${MUT_ROOT}/flota/node${n}"
		NAYLAMP_TLS_CERT="${CERT_DIR}/node-${n}.pem" \
		NAYLAMP_TLS_KEY="${CERT_DIR}/node-${n}-key.pem" \
		NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
		nohup "${mutante}" node -id "${n}" -listen "${HOSTADDR}:${MUT_PORTS[$n]}" \
			-peers "$(mut_peers_of "$n")" -client "${CLIENT_ID}=${HOSTADDR}:${MUT_CLIENT_PORT}" \
			-dir "${MUT_ROOT}/flota/node${n}/data" -dim "${DIM}" \
			</dev/null >>"${MUT_ROOT}/flota/node${n}.log" 2>&1 &
		echo $! >> "${OUT_LOCAL}/pids-mut.txt"
		[ -n "${mgroup}" ] && mgroup="${mgroup},"
		mgroup="${mgroup}${n}=${HOSTADDR}:${MUT_PORTS[$n]}"
	done
	for i in $(seq 1 40); do
		set +e
		out="$(NAYLAMP_TLS_CERT="${CERT_DIR}/node-${CLIENT_ID}.pem" \
			NAYLAMP_TLS_KEY="${CERT_DIR}/node-${CLIENT_ID}-key.pem" \
			NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
			"${mutante}" client -listen "${HOSTADDR}:${MUT_CLIENT_PORT}" -group "${mgroup}" \
			-dim "${DIM}" -op put -id 7 -vec "$(vec_for 7)" </dev/null 2>&1)"
		[ $? -eq 0 ] && ok=1
		set -e
		[ "${ok}" -eq 1 ] && break
		sleep 0.25
	done
	if [ "${ok}" -eq 1 ]; then
		pass "P2.red.daemon: three replicas on the MUTANT binary formed a cluster, elected a leader and acked a write, so on iron this arm reaches its cut"
	else
		fail "P2.red.daemon: the mutant fleet never acked a write, so on iron this arm would die before its cut with the fleet powered on"
	fi
	end_check P2.red.daemon

	not_run P2.red.barrier "the cut, and the oracle that would read it. Four things WERE measured above and are named so this line is not read as a promise: the mutation applies, the mutant builds and differs, both defenders print their own FAIL line under it, and three replicas on it form a cluster. What was NOT measured is anything about loss: this run never cut the mutant, never read anything back from it and never compared it with the sane build. Its single put id=7 enters no manifest. On iron this arm is that same mutant under echo b > /proc/sysrq-trigger, and it still needs an oracle of its own"
	not_run P2.red.fires "the mutant's own cut guard. It needs the cut above AND it is not written: nothing here compares raft-<n>.log sizes across a cut on the mutant tree, so this is code that does not exist yet rather than code that cannot run here"
}

phase_hygiene() {
	begin_check
	local n left=0
	for n in "${NODE_IDS[@]}"; do
		if node_alive "$n"; then
			kill "$(node_pid "$n")" 2>/dev/null || true
		fi
	done
	sleep 1
	for n in "${NODE_IDS[@]}"; do
		if node_alive "$n"; then
			kill -9 "$(node_pid "$n")" 2>/dev/null || true
		fi
	done
	sleep 0.5
	for n in "${NODE_IDS[@]}"; do
		node_alive "$n" && { left=$((left + 1)); fail "P2.hygiene: node ${n} is still running"; }
	done
	# The removal is written against a LITERAL prefix with the run id appended
	# inline, never a bare variable. Clause 23, and gate/p1.sh's own rule.
	rm -rf -- "${OUT_DIR}/p2-local-fleet-${RUN_ID}"
	# THE MUTANT TREE, and its root comes from a variable, so clause 23's escape is
	# the one taken: the directory is validated before the order and the order
	# refuses if it does not hold. Two conditions and both have to be true: the
	# marker file this run wrote is inside it, and the run id has the shape this
	# script deletes by, which was checked the moment it was built.
	if [ -n "${MUT_ROOT}" ] && [ -f "${MUT_MARCA}" ]; then
		rm -rf -- "${MUT_ROOT}"
		[ -d "${MUT_ROOT}" ] && fail "P2.hygiene: the mutant tree survived its own removal"
	elif [ -d "${MUT_ROOT}" ]; then
		fail "P2.hygiene: ${MUT_ROOT} exists and does not carry this run's marker, so it is not removed"
	fi
	if [ -d "${OUT_DIR}/p2-local-fleet-${RUN_ID}" ]; then
		fail "P2.hygiene: the fleet directory survived its own removal"
	elif [ "${left}" -eq 0 ]; then
		pass "P2.hygiene: no node left running and the fleet directory is gone"
	fi
	end_check P2.hygiene
}

# Killing whatever is still up. It runs on EXIT and not only on a signal, and the
# distinction is a defect this rehearsal found in itself: with the trap on INT and
# TERM alone, `p2.sh pre` returned to the shell leaving three daemons listening on
# loopback, because only the `all` path reaches phase_hygiene. It touches nothing
# outside this run's own pid files, and it does NOT call exit, so the status the
# script was leaving with survives the trap.
limpia_flota() {
	local p args
	# Every pid this run launched, not just the last one per node. Each is checked
	# against its own command line before being signalled, so a pid the operating
	# system has already recycled onto somebody else's process is left alone.
	local lista
	for lista in "${OUT_LOCAL}/pids.txt" "${OUT_LOCAL}/pids-mut.txt"; do
		[ -f "${lista}" ] || continue
		while read -r p; do
			[ -z "${p}" ] && continue
			kill -0 "${p}" 2>/dev/null || continue
			args="$(ps -p "${p}" -o args= 2>/dev/null || true)"
			case "${args}" in
				"${BIN} node"*|"${MUT_ROOT}/naylampd-mutante node"*) kill -9 "${p}" 2>/dev/null || true ;;
			esac
		done < "${lista}"
	done
	# The node logs are the only evidence a failed run leaves, so they are moved
	# into the artifact BEFORE the fleet directory goes. Then the directory is
	# removed against a literal prefix with the run id appended inline, never a
	# bare variable, which is clause 23.
	for n in "${NODE_IDS[@]}"; do
		[ -f "${FLEET}/node${n}.log" ] && cp "${FLEET}/node${n}.log" "${OUT_LOCAL}/node${n}.log" 2>/dev/null || true
	done
	rm -rf -- "${OUT_DIR}/p2-local-fleet-${RUN_ID}"
}

# al_salir is the ONLY exit path, and it closes the run instead of letting it
# evaporate. The hole it fills was demonstrated on 2026-09-06: with the verdict
# block reachable only as the last statement of main, a phase that aborted under
# set -e left a console log full of PASS lines, ZERO 'gate: verdict' lines and no
# NOT A SUCCESS, so a reader saw eight greens and no closing line. The
# RUN_STARTED guard inside emit_final_verdict had been written for exactly that
# case and was unreachable. An abort now prints the block, says it aborted, and
# can never come out zero.
al_salir() {
	local rc=$?
	limpia_flota
	retira_running
	if [ "${RUN_STARTED}" -eq 1 ] && [ "${EMITIDO}" -eq 0 ]; then
		echo "gate: the run ABORTED before reaching its verdict block, so nothing above is a result" >&2
		emit_final_verdict || true
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}

usage() {
	cat >&2 <<'USAGE'
usage: NAYLAMP_P2_LOCAL=1 p2.sh <all|build|pre|provenance|red>

Five subcommands and not one more. An earlier version of this line advertised
nine, five of which fell through to this message: the phases exist as functions
but only these five are wired, because the rest need the fleet a previous phase
left running and there is no state between invocations. Advertising them cost a
directory under gate/out per attempt, since the artifact was created before the
subcommand was validated.

Without NAYLAMP_P2_LOCAL=1 this script refuses and prints what its iron path is
still missing. There is no default subcommand: a bare invocation is a usage error.
USAGE
	exit 2
}

main() {
	local sub="${1:-}"
	[ -z "${sub}" ] && usage
	# THE PORTS ARE CHECKED BEFORE ANYTHING IS CREATED, and this refusal was
	# earned. The rehearsal listens on EIGHT fixed loopback ports, four for the sane
	# fleet and four for the mutant one, so two runs at
	# once fight over them, and the loser does not fail cleanly: it comes out with
	# P2.pre.fleet, P2.pre.identity and P2.workload.acked in red, which reads
	# exactly like the property failing. Measured on 2026-09-06, with three runs
	# overlapping by accident. A red that names the wrong cause is worse than a
	# break, which is clause 15, so this breaks.
	local puerto ocupados=""
	for puerto in "${NODE_PORTS[@]}" "${CLIENT_PORT}" "${MUT_PORTS[@]}" "${MUT_CLIENT_PORT}"; do
		[ "${puerto}" = 0 ] && continue
		if lsof -nP -iTCP:"${puerto}" -sTCP:LISTEN >/dev/null 2>&1; then
			ocupados="${ocupados} ${puerto}"
		fi
	done
	if [ -n "${ocupados}" ]; then
		echo "gate: refusing to run: these loopback ports are already listening:${ocupados}" >&2
		echo "gate: another rehearsal is probably still up. Two runs share these eight ports and the" >&2
		echo "gate: second one would report the property red when what collided was a socket." >&2
		exit 2
	fi

	# THE SUBCOMMAND IS VALIDATED BEFORE ANYTHING IS CREATED. It used to be the
	# other way round, so `p2.sh hygiene`, which is not wired, printed the usage
	# and left an empty gate/out/p2-local-<runid> behind. Five attempts, five
	# directories, in the script whose own item is about gate/out growing.
	case "${sub}" in
		all|build|pre|provenance|red) ;;
		*) usage ;;
	esac
	local t_start t_end
	t_start="$(ahora)"
	mkdir -p "${OUT_LOCAL}" "${FLEET}"
	trap al_salir EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	banner
	RUN_STARTED=1
	case "${sub}" in
		all)
			EXPECTED="P2.build P2.pre.fleet P2.pre.identity P2.provenance P2.workload.acked P2.cut.fired P2.recover.boots P2.recover.elects P2.recover.acked P2.recover.faithful P2.recover.idem P2.red.mutation P2.red.bites P2.red.daemon P2.hygiene"
			phase_build
			phase_pre
			phase_provenance
			phase_workload
			phase_cut
			phase_recover
			phase_red
			phase_hygiene
			COMPLETED=1
			;;
		build) EXPECTED="P2.build"; phase_build; COMPLETED=1 ;;
		pre) EXPECTED="P2.build P2.pre.fleet P2.pre.identity"; phase_build; phase_pre; COMPLETED=1 ;;
		provenance) EXPECTED="P2.build P2.provenance"; phase_build; phase_provenance; COMPLETED=1 ;;
		red) EXPECTED="P2.build P2.red.mutation P2.red.bites P2.red.daemon"; phase_build; phase_red; phase_hygiene; COMPLETED=1 ;;
	esac
	t_end="$(ahora)"
	T_OVERHEAD="$(delta "${t_start}" "${t_end}")"
	{
		echo "run: p2-local-${RUN_ID}"
		echo "workload_s: ${T_WORKLOAD:-not measured in this subcommand}"
		echo "recover_and_verify_s: ${T_RECOVER:-not measured in this subcommand}"
		echo "whole_run_s: ${T_OVERHEAD}"
		echo "machine: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
		echo "toolchain: $(go version)"
		echo "load at start: $(grep '^load at start: ' "${OUT_LOCAL}/provenance.txt" 2>/dev/null | sed 's/^load at start: //' || true)"
		echo "note: an empty load field means this subcommand did not run phase_provenance"
	} > "${OUT_LOCAL}/timings.txt"
	note "timings written to $(basename "${OUT_LOCAL}")/timings.txt"
	emit_final_verdict
}

main "$@"
