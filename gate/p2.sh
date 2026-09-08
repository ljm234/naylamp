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

# THE MARGIN OF LIFE DEMANDED OF THE TLS MATERIAL LIVES IN ONE PLACE, and that is
# not cosmetic: if this script and the two others that look at the same thing
# ever carried different numbers there would be a DEAD ZONE, a stretch where the
# preflight refuses to start and the documented remedy, rebuilding, leaves the
# certificates exactly as they were. A missing file here is a failure and not a
# default: with no margin there is no check to make, and assuming one would be
# inventing it.
if [ ! -r "${GATE_DIR}/cert-margen.sh" ]; then
	echo "gate: ${GATE_DIR}/cert-margen.sh is missing, and that is where the TLS margin lives" >&2
	exit 2
fi
. "${GATE_DIR}/cert-margen.sh"
case "${CERT_MARGEN_SEG:-}" in
	''|*[!0-9]*)
		echo "gate: CERT_MARGEN_SEG is not a number of seconds: '${CERT_MARGEN_SEG:-}'" >&2
		exit 2
		;;
esac
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

# ---- the two paths, and which one this run takes -------------------------------
#
# ES_FIERRO=1 drives the three real hosts over ssh. ES_FIERRO=0 is the rehearsal
# on loopback, and it keeps every line it had.
#
# WHAT THIS BLOCK REPLACES, said plainly because the thing it replaces asked for
# it. Until 2026-09-07 this was a REFUSAL that listed four missing pieces and
# ended "when the list empties, this block is what has to be deleted on purpose".
# It is deleted on purpose here, and three of the four are CLOSED and not
# declared: the power cut exists now, `echo b > /proc/sysrq-trigger` over ssh
# fired on the THREE at once; the mutant is built, shipped and cut by
# phase_red; and the boot term is measured, 10.13 timed one VM answering again
# 54 s after the cut. THE ONE THAT STAYS OPEN IS NAMED: nobody has timed the
# ELECTION after a cold start of three, because that needs the three up, and
# this gate is what will time it. It goes into timings.txt as a first figure,
# never as a threshold.
ES_FIERRO=0
if [ "${REHEARSAL}" != 1 ]; then
	ES_FIERRO=1
fi

if [ "${ES_FIERRO}" -eq 1 ]; then
	# common.sh brings run_on, ask_on, read_on and copy_to, plus HOSTS, PRIV, the
	# ids and the ports, and it refuses on its own if NAYLAMP_GATE_HOSTS,
	# NAYLAMP_GATE_PRIVATE or NAYLAMP_GATE_KEY is missing. That refusal is the one
	# this path wants: an iron run with no fleet identity must not start.
	# shellcheck source=common.sh
	source "${GATE_DIR}/common.sh"
	# There is no single address on iron: each node listens on its own PRIV[n].
	HOSTADDR=""
	# The loopback port arrays exist so the shared code can index them, and they
	# are EMPTY on iron on purpose: main's port check skips them, because nothing
	# here binds a local socket.
	NODE_PORTS=()
	MUT_PORTS=()
	MUT_CLIENT_PORT=""
	# THE MUTANT DOES NOT LAND ON naylamp/bin/naylampd, and that is not tidiness.
	# gate/omnibus.sh:589 reads `sha256sum naylamp/bin/naylampd` on every host to
	# assert the fleet is homogeneous, and gate/deploy.sh:20 puts the sane build
	# there. A mutant at that path changes the omnibus's answer without anybody
	# asking it to.
	MUT_REMOTO="naylamp/bin/naylampd-mutante"
	MUT_PORT_FIERRO=9411
	MUT_CLIENT_PORT_FIERRO=9500
	DIM=8
else
	# ---- the rehearsal's fleet ------------------------------------------------
	#
	# Three directories on this machine play the three replicas, on loopback ports
	# that no other gate uses. common.sh is NOT sourced here: it demands the
	# fleet's identity, and a rehearsal that never opens an ssh channel has no
	# business requiring it. gate/p1.sh sources it in local mode and pays exactly
	# that friction; this one does not repeat it.
	NODE_IDS=(1 2 3)
	CLIENT_ID=90
	HOSTADDR=127.0.0.1
	NODE_PORTS=(0 19401 19402 19403)   # index by node id; slot 0 unused
	CLIENT_PORT=19490
	# The mutant fleet gets its own ports so phase_red does not have to wait for
	# the sane fleet to come down, and so neither can be mistaken for the other in
	# lsof.
	MUT_PORTS=(0 19411 19412 19413)
	MUT_CLIENT_PORT=19500
	DIM=8
fi

# NOMBRE_CORRIDA is the artifact's name, derived ONCE so the banner, the marker
# and timings.txt cannot drift apart.
if [ "${ES_FIERRO}" -eq 1 ]; then
	NOMBRE_CORRIDA="p2-${RUN_ID}"
else
	NOMBRE_CORRIDA="p2-local-${RUN_ID}"
fi

# THE PREFIX IS NOT COSMETIC: it is what decides whether `make clean` sweeps this
# run's artifact or refuses to. The Makefile guard asks by SHAPE,
# `-name 'p[0-9]-*' ! -name 'p[0-9]-local-*'`, so a `p2-local-<run id>` is
# rehearsal scratch and goes, while a `p2-<run id>` is an iron artifact and does
# not go without SEALED inside it or UNSEALED_OK=1 typed on purpose. An iron run
# writing under the local name would have its evidence swept by an ordinary
# `make clean`, which is the incident this file already carries twice.
if [ "${ES_FIERRO}" -eq 1 ]; then
	FLEET="${OUT_DIR}/p2-fleet-${RUN_ID}"
	OUT_LOCAL="${OUT_DIR}/p2-${RUN_ID}"
else
	FLEET="${OUT_DIR}/p2-local-fleet-${RUN_ID}"
	OUT_LOCAL="${OUT_DIR}/p2-local-${RUN_ID}"
fi
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
NAYLAMP PHASE 2 GATE. run id ${NOMBRE_CORRIDA}
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

# addr_de <n>: where node n listens, and the two paths differ in exactly this.
# On loopback it is HOSTADDR and a per-id port; on iron it is that host's private
# address and the fleet's single port, the same pair gate/cluster.sh builds.
addr_de() {
	if [ "${ES_FIERRO}" -eq 1 ]; then
		printf '%s:%s' "${PRIV[$1]}" "${NODE_PORT}"
	else
		printf '%s:%s' "${HOSTADDR}" "${NODE_PORTS[$1]}"
	fi
}

# addr_cliente: where the client binds ON LOOPBACK. The iron path does not use
# it: there the client runs inside host 1 through run_on, because PRIV[1] is that
# host's address and this machine can neither bind it nor reach it. See client_op.
addr_cliente() {
	if [ "${ES_FIERRO}" -eq 1 ]; then
		printf '%s:%s' "${PRIV[1]}" "${CLIENT_PORT}"
	else
		printf '%s:%s' "${HOSTADDR}" "${CLIENT_PORT}"
	fi
}

peers_of() {
	local n="$1" peers="" j
	for j in "${NODE_IDS[@]}"; do
		if [ "$j" != "$n" ]; then
			[ -n "$peers" ] && peers="${peers},"
			peers="${peers}${j}=$(addr_de "$j")"
		fi
	done
	printf '%s' "${peers}"
}

group_spec() {
	local g="" j
	for j in "${NODE_IDS[@]}"; do
		[ -n "$g" ] && g="${g},"
		g="${g}${j}=$(addr_de "$j")"
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
# It returns ONE integer and never two, and that is a defect this file carried
# into three archived rehearsals before anyone read them. Written as
# `grep -c ... || echo 0`, a log that EXISTS without the line makes grep print 0
# AND exit 1, so the `|| echo 0` fires on top and the function answers "0\n0".
# `[ "0\n0" -gt 0 ]` does not compare: it prints `integer expression expected`,
# returns 2, and the caller reads a failed comparison as a false one. It printed
# 7, 3 and 5 times in three archived runs. The shape below cannot do that: one
# read, the first line only, and anything that is not a plain number becomes 0.
lineas_listening() {
	local n
	n="$(grep -c 'listening' "${FLEET}/node$1.log" 2>/dev/null | head -1)"
	case "${n}" in
		''|*[!0-9]*) n=0 ;;
	esac
	printf '%s' "${n}"
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

# client_op: one client operation, with its exit status appended so the caller
# reads a status and not a guess.
#
# ON IRON IT RUNS INSIDE HOST 1, and that is not a preference. `-listen` is a
# real bind (engine/cmd/naylampd/client.go, cluster.NewTCPTransport), and PRIV[1]
# is the host's private address, which this laptop does not have and cannot
# reach: binding it here answers `can't assign requested address`. gate/omnibus.sh
# is the only gate in this house that already drives a client over iron, and it
# runs it through `run_on 1` for exactly this reason, at :492. A reader measured
# the bind failing on 2026-09-07 before the fleet was ever powered on.
#
# WHAT THAT COSTS AND WHERE IT IS PAID: the client now executes on a host that
# gets cut. The manifest does NOT move: it is still written on this machine, from
# the `exit=` this function brings back, so the witness stays outside the cut set
# exactly as the banner claims. What lives on host 1 is the client PROCESS, not
# the record of what it acked.
client_op() {
	local out rc
	set +e
	if [ "${ES_FIERRO}" -eq 1 ]; then
		out="$(run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '$(group_spec)' -dim ${DIM} $* ; echo __RC__=\$?" 2>&1)"
		# THE STATUS IS THE LAST LINE AND HAS TO BE THE WHOLE LINE. Matching
		# `*__RC__=0*` anywhere in the stream would let the client's own output
		# decide the verdict if it ever printed that string, and a status channel
		# that any payload can forge is not a status channel. Anything that is not
		# exactly the marker followed by digits leaves rc at 1, which is the
		# fail-closed side: an unreadable answer is not a success.
		local ultima
		ultima="$(printf '%s' "${out}" | tail -1)"
		rc=1
		case "${ultima}" in
			__RC__=0) rc=0 ;;
			__RC__=[0-9]*) rc=1 ;;
			*) rc=2 ;;
		esac
		out="$(printf '%s' "${out}" | sed '$d')"
	else
		out="$(NAYLAMP_TLS_CERT="${CERT_DIR}/node-${CLIENT_ID}.pem" \
			NAYLAMP_TLS_KEY="${CERT_DIR}/node-${CLIENT_ID}-key.pem" \
			NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
			"${BIN}" client \
				-listen "$(addr_cliente)" \
				-group "$(group_spec)" \
				-dim "${DIM}" \
				"$@" </dev/null 2>&1)"
		rc=$?
	fi
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

# entry_log_bytes <node id>: the total size of that replica's entry log, with
# THREE outcomes and not two, because this is the number the whole cut verdict
# turns on.
#
#	prints the total, returns 0   every segment was read
#	prints nothing,   returns 2   a segment exists and could not be read
#
# The two-outcome form it replaces was fail-open and `set -e` did not catch it:
# written `t=$(( t + $(stat ...) ))`, a failed read makes the substitution empty,
# bash prints `syntax error: operand expected` on stderr, LEAVES t at its previous
# value, and the script continues with rc 0. In a loop over segments an unreadable
# file then contributes nothing and the total comes out silently short, which on
# iron reads as "the log shrank across the cut": the exact conclusion this gate
# exists to draw. Measured that way on 2026-09-07 before it was closed.
entry_log_bytes() {
	local n="$1" t=0 f sz
	for f in "${FLEET}/node${n}/data"/raft-*.log; do
		# `-e` alone reopens the hole in different clothes: it is FALSE for a name
		# that exists as a directory entry but does not resolve, a dangling or
		# circular symlink among them, so such a segment was SKIPPED and
		# contributed nothing to the total. Same fail-open, quieter. `-L` catches
		# the entry that exists without resolving, and then stat fails and the
		# whole reading becomes ILEGIBLE, which is the honest answer. Found by
		# gate/p2-iron-test.sh row 12 while it was being written.
		if [ ! -e "${f}" ]; then
			[ -L "${f}" ] && return 2
			continue
		fi
		sz="$(stat -f%z "${f}" 2>/dev/null || stat -c%s "${f}" 2>/dev/null || true)"
		case "${sz}" in
			''|*[!0-9]*) return 2 ;;
		esac
		t=$(( t + sz ))
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
# ---- the iron primitives -------------------------------------------------------
#
# Every one of them goes through ask_on or read_on, never through run_on, so a
# host that cannot be read is its own outcome and never a clean bill. That is
# DEFER-072, and this file pays it from the first line rather than later.

# boot_id_de <n>: the kernel's boot id, which is the oracle of the cut. It
# changes if and only if the machine actually rebooted, so it cannot be faked by
# a daemon that merely died, and it cannot be missed by a machine that rebooted
# and came back fast.
boot_id_de() {
	local v
	v="$(read_on "$1" "0" 'cat /proc/sys/kernel/random/boot_id')" || return 2
	printf '%s' "$(printf '%s' "${v}" | tr -d '[:space:]')"
}

# sysrq_de <n>: the raw value of /proc/sys/kernel/sysrq. NOT a plain bitmask:
# 0 disables everything, 1 enables every function, and anything above 1 is a
# mask whose bit 7 (128) is the reboot one. Measured on naylamp-1 on
# 2026-09-07: the value was 176.
sysrq_de() {
	local v
	v="$(read_on "$1" "0" 'cat /proc/sys/kernel/sysrq')" || return 2
	printf '%s' "$(printf '%s' "${v}" | tr -d '[:space:]')"
}

sysrq_permite_reinicio() {
	local v="$1"
	case "${v}" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "${v}" -eq 1 ] && return 0
	[ "${v}" -eq 0 ] && return 1
	[ $(( v & 128 )) -ne 0 ]
}

# ---- THE DECISIONS, as named functions ----------------------------------------
#
# They exist as functions rather than as expressions inline for one reason a
# reader put a number on: gate/p2-iron-test.sh had ten rows that re-typed these
# comparisons over literals of its own, so `cambiados=2; [ "${cambiados}" -ge 2 ]`
# proved that two is at least two and nothing about this script. Rewinding the
# threshold in p2.sh left all ten green. A bench that cannot see the object is a
# bench that measures arithmetic.

# mayoria_de <total>: the majority size, the same one cluster.Config.Quorum()
# computes at engine/cluster/config.go:87.
mayoria_de() { printf '%s' "$(( $1 / 2 + 1 ))"; }

# corte_completo <rebooted> <total>: whether the cut may be accepted. THE THREE,
# never a majority and never a threshold of two. With one survivor Raft heals the
# cut replicas from it and every green below attests replication, not durability.
corte_completo() { [ "$1" -eq "$2" ]; }

# faithful_suficiente <faithful> <total>: whether enough cold copies verified.
# A MAJORITY, because Raft acks on a majority and a replica that had not yet
# persisted the last acked write is legitimately short.
faithful_suficiente() { [ "$1" -ge "$(mayoria_de "$2")" ]; }

# identidad_confirmada <sha vivo> <sha sano>: whether the live binary is NOT the
# sane one. By content, so a mutant deployed over the sane path is still caught.
identidad_confirmada() { [ -n "$1" ] && [ "$1" != "$2" ]; }

# ventana_dentro <segundos>: whether the measured window is inside VENTANA_MAX.
ventana_dentro() { [ "$(/usr/bin/python3 -c "print(1 if $1 > ${VENTANA_MAX} else 0)")" = 0 ]; }

# testigo_veredicto <tamano> <semilla> <cola>: what a canary's size means. Four
# outcomes, and the fourth is the one that would be the finding of the session.
testigo_veredicto() {
	local d="$1" sem="$2" col="$3"
	case "${d}" in ''|*[!0-9]*) printf 'ilegible'; return ;; esac
	if [ "${d}" -lt "${sem}" ]; then printf 'bajo-semilla'
	elif [ "${d}" -eq "${sem}" ]; then printf 'seco'
	elif [ "${d}" -ge $(( sem + col )) ]; then printf 'entero'
	else printf 'parcial'
	fi
}

# ---- THE THIRD CANARY, which is what turns P2.cut.bytes from a measurement of
# the BARRIER into a measurement of the CUT.
#
# The problem it solves: with the barrier healthy, s.active.Sync() in
# engine/raft/storage.go:304 runs before any entry can be acked, so the acked
# loss expected from a clean cut is ZERO, the guard records `none`, and section
# 10.12 reads that `none` as a named infrastructure red. A perfect run would
# publish a failure. DEFER-046 already said the local guard, `disk.BytesCut() > 0`,
# is a faultio reading with no analogue on hardware.
#
# The canary is that analogue. It is written in TWO steps on purpose:
#
#   testigo_siembra  creates the file with SEMILLA bytes and SYNCS it, file and
#                    directory both, so what exists after any reboot is durable
#                    by construction. If this part were unsynced too, ext4 in
#                    data=ordered would drag the data along with the directory
#                    entry and the whole probe would measure the journal.
#   testigo_arma     appends COLA bytes and does NOT sync anything.
#
# After the cut the file is read back. SEMILLA means the cut was dry and took
# the unsynced tail; SEMILLA+COLA means nothing was cut, or the journal flushed
# first, and either way the run has no evidence that the machine lost power.
#
# THE BOUND IS PART OF THE PROBE AND NOT AN OPTIMISATION. The fleet's root is
# mounted with commit=30, measured in 10.13, so an unsynced write reaches the
# platter on its own within 30 seconds. If more than VENTANA_MAX seconds pass
# between arming and cutting, the canary is not evidence of anything and the
# verdict says so with the elapsed time printed, instead of reading a flushed
# tail as "nothing was cut".
TESTIGO_REMOTO="naylamp/testigo-corte.bin"
TESTIGO_SEMILLA=4096
TESTIGO_COLA=65536
VENTANA_MAX=5

testigo_siembra() {
	local n="$1"
	ask_on "${n}" "head -c ${TESTIGO_SEMILLA} /dev/zero > ${TESTIGO_REMOTO} && sync"
}

testigo_arma() {
	local n="$1"
	ask_on "${n}" "head -c ${TESTIGO_COLA} /dev/zero >> ${TESTIGO_REMOTO}"
}

# testigo_tamano <n>: the canary's size as a BARE integer. The `tr -d` is not
# decoration: `wc -c` pads its answer with leading spaces on BSD and on macOS, so
# the value came back as "    4096" and every numeric comparison downstream was
# reading a padded string. Caught by gate/p2-iron-test.sh rows 22 to 25 before
# any of this reached a host.
testigo_tamano() {
	local n="$1" v
	v="$(read_on "${n}" "0" "wc -c < ${TESTIGO_REMOTO}")" || return 2
	v="$(printf '%s' "${v}" | tr -d '[:space:]')"
	case "${v}" in
		''|*[!0-9]*) return 2 ;;
	esac
	printf '%s' "${v}"
}

# corta_en <n>: the cut itself. It is a run_on and not an ask_on for one reason
# that is not laziness: the machine dies mid-sentence, so ssh returns a transport
# failure and there IS no answer to classify. The oracle is never this call's
# exit status; it is the boot id read afterwards.
corta_en() {
	local n="$1"
	run_on "${n}" 'sudo sh -c "echo b > /proc/sysrq-trigger"' >/dev/null 2>&1 || true
}

# espera_vuelta <n> <segundos> <instante del corte>: waits for a host to answer
# ssh again, with a BOUND, and returns 1 when the bound is spent. Clause 24: a
# wait carries a bound, and the bound is enforced by this loop and not by
# `timeout`, which does not exist on this machine and whose absence once produced
# a bound reporting on itself.
#
# THE NUMBER IT PRINTS IS MEASURED FROM THE CUT and not from the start of its own
# loop, and that is not a detail. The three hosts are waited for one after
# another, so host 2's loop only begins once host 1 has answered: a figure
# counted from the loop would report host 3 as coming back in a couple of seconds
# when it had been down for two minutes. The bound stays on this host's own wait;
# what is reported is the elapsed time since the cut, which is the figure anybody
# reading the artifact will believe is that.
espera_vuelta() {
	local n="$1" tope="$2" t_corte="$3" i=0
	while [ "${i}" -lt "${tope}" ]; do
		if ask_on "${n}" 'true'; then
			delta "${t_corte}" "$(ahora)"
			return 0
		fi
		sleep 1
		i=$(( i + 1 ))
	done
	delta "${t_corte}" "$(ahora)"
	return 1
}

# espera_caida <n> <segundos> <instante del corte>: waits for a host to STOP
# answering ssh, with a bound.
#
# THIS PIECE COST 10.13 A RUN AND ITS ABSENCE INVERTS THE RESULT, which is why it
# is here and not left to the return wait. Section 10.13 says it in those words:
# without it, the return wait exits immediately with the machine still alive, the
# timestamps come out in the wrong order and the boot id read afterwards is the
# one from BEFORE the reboot. The gate would then publish "the cut did not cut"
# over a cut that cut, on a three second race. A machine that never stopped
# answering was not cut, so this failing is a fail and not a note.
espera_caida() {
	local n="$1" tope="$2" t0="$3" i=0
	while [ "${i}" -lt "${tope}" ]; do
		ask_on "${n}" 'true' || { delta "${t0}" "$(ahora)"; return 0; }
		sleep 1
		i=$(( i + 1 ))
	done
	delta "${t0}" "$(ahora)"
	return 1
}

# sha_del_binario_vivo <n> <pidfile>: the sha256 of the file the running process
# is EXECUTING, read through /proc/<pid>/exe, which is the only reading that
# survives the two ways a path lies: a mutant deployed over the sane name, and a
# sane binary invoked through the mutant's path. P2.pre.identity already asks the
# weaker question, by command line, for the sane fleet; this is the strong one
# and the red arm is where it earns its keep.
sha_del_binario_vivo() {
	local n="$1" pidfile="$2"
	read_on "${n}" "0" "sudo sha256sum /proc/\$(cat ${pidfile})/exe 2>/dev/null | cut -d' ' -f1"
}

# copia_fria_de <n>: brings that host's data directory down, and the ORDER is
# the whole point. It runs AFTER the reboot and BEFORE anything relaunches the
# node, with the motor stopped, because a copy taken after launch_node is a copy
# of a log Raft already healed from the leader: it verifies what replication
# returned, not what the barrier left. The rehearsal used to copy at that later
# point and nobody had noticed.
copia_fria_de() {
	local n="$1" destino="$2"
	# Clause 23 takes its second escape here: the root cannot be a literal because
	# the caller names the directory, so the order REFUSES unless the path is the
	# one this run built, under this run's own artifact and carrying its run id.
	# It was a bare `rm -rf -- "${destino}"` until a reader pointed out it was the
	# only removal in this file taking neither of the two ways out.
	case "${destino}" in
		"${OUT_LOCAL}/cold-node"[0-9]|"${OUT_LOCAL}/cold-mutante-node"[0-9]) ;;
		*) echo "gate: refusing to remove ${destino}: it is not one of this run's cold copies" >&2; return 2 ;;
	esac
	rm -rf -- "${destino}"
	mkdir -p "${destino}"
	scp "${SSH_OPTS[@]}" -q -r "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:naylamp/data/." "${destino}/" 2>/dev/null
}

escribe_running() {
	printf 'pid: %s\nrun: %s\nstarted: %s\nscript: %s\nhost: %s\n' \
		"$$" "${NOMBRE_CORRIDA}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "gate/p2.sh" "$(hostname)" \
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
	# THE READER'S WARNING CAME TRUE ON 2026-09-07 AND THIS IS THE ANSWER. It said:
	# the day the iron path lands, OUT_LOCAL becomes p2-<run id>, this function
	# walks p2-local-<run id>, finds nothing, returns 0, and the marker outlives
	# the run forever. The iron path landed that day. So the removal knows BOTH
	# names, each written as a literal with the run id inline, and refuses loudly
	# for anything that is neither. Two literals is still clause 23; a variable
	# holding a path is not.
	if [ "${OUT_LOCAL}" = "${OUT_DIR}/p2-local-${RUN_ID}" ]; then
		[ -f "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING" ] || return 0
		grep -q "^pid: $$\$" "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING" || return 0
		rm -f -- "${OUT_DIR}/p2-local-${RUN_ID}/RUNNING"
		return 0
	fi
	if [ "${OUT_LOCAL}" = "${OUT_DIR}/p2-${RUN_ID}" ]; then
		[ -f "${OUT_DIR}/p2-${RUN_ID}/RUNNING" ] || return 0
		grep -q "^pid: $$\$" "${OUT_DIR}/p2-${RUN_ID}/RUNNING" || return 0
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/RUNNING"
		return 0
	fi
	echo "gate: RUNNING marker NOT removed: the artifact is ${OUT_LOCAL} and this removal only knows p2-local-${RUN_ID} and p2-${RUN_ID}" >&2
	return 0
}

phase_build() {
	begin_check
	mkdir -p "${OUT_DIR}" "${OUT_LOCAL}" "${FLEET}"
	escribe_running
	if [ "${ES_FIERRO}" -eq 1 ]; then
		# On iron the fleet runs linux/arm64 and this machine is darwin/arm64, so
		# the binary the hosts execute comes from gate/build.sh and not from a
		# native build. It is not re-derived here: build.sh already owns the flags
		# (GOOS, GOARCH, CGO_ENABLED=0) and the certificate freshness rule.
		note "iron: cross compiling through gate/build.sh, linux/arm64 static"
		( cd "${REPO_DIR}" && ./gate/build.sh ) >>"${OUT_LOCAL}/build.log" 2>&1 || stop "gate/build.sh failed"
		[ -f "${OUT_DIR}/naylampd" ] || stop "gate/build.sh left no linux/arm64 naylampd in gate/out"
		# BIN is the client this machine runs to drive the fleet, so it is the
		# NATIVE one; the cross compiled naylampd is what the hosts execute and
		# what P2.pre.identity compares by digest.
		( cd "${REPO_DIR}" && go build -o "${BIN}" ./engine/cmd/naylampd ) || stop "the native driver did not build"
		note "cross compiled naylampd $(stat -f%z "${OUT_DIR}/naylampd" 2>/dev/null || stat -c%s "${OUT_DIR}/naylampd") bytes, sha256 $(shasum -a 256 "${OUT_DIR}/naylampd" | cut -c1-16)"
	else
		note "rehearsal: building naylampd NATIVE; the iron path cross compiles linux/arm64 through gate/build.sh"
		( cd "${REPO_DIR}" && go build -o "${BIN}" ./engine/cmd/naylampd ) || stop "naylampd did not build"
	fi
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
		   ! openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1; then
			stale=1
		fi
	done
	if [ ! -f "${CERT_DIR}/ca.pem" ] || ! openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1; then
		stale=1
	fi
	if [ "${stale}" -eq 1 ]; then
		note "certificates missing or within ${CERT_MARGEN_SEG}s of expiry: re-minting through gate/build.sh"
		( cd "${REPO_DIR}" && ./gate/build.sh ) >>"${OUT_LOCAL}/build.log" 2>&1 || stop "gate/build.sh failed while minting certificates"
	else
		note "certificates present and not expiring within ${CERT_MARGEN_SEG}s: reused"
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
		openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1 \
			|| fail "P2.build: the certificate for id ${id} is expired or expires within ${CERT_MARGEN_SEG}s"
	done
	[ -f "${CERT_DIR}/ca.pem" ] || fail "P2.build: no CA certificate"
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.build: naylampd built and the TLS material for ${#NODE_IDS[@]} nodes plus the client is present and not expiring within ${CERT_MARGEN_SEG}s"
	end_check P2.build
}

phase_pre() {
	if [ "${ES_FIERRO}" -eq 1 ]; then
		phase_pre_fierro
		return
	fi
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

	not_run P2.pre.sysrq "there is no /proc/sys/kernel/sysrq on this machine and no sysrq-b to permit; the iron path reads the value on all three hosts and fails loudly if the reboot bit is off"
}

# ---- phase_pre on iron --------------------------------------------------------
#
# It launches nothing: the fleet is expected up, brought there by the preflight,
# and this phase reads it. Three questions and each one answerable and able to be
# wrong: does every host answer, is every host executing the binary this run
# shipped, and does every host permit the reboot key.
phase_pre_fierro() {
	local n out i ok=0 sha_local sha_remoto vistos=0 v permiten=0
	begin_check
	for n in "${NODE_IDS[@]}"; do
		case "$(ask_on "$n" 'true'; echo $?)" in
			0) note "node ${n} at ${HOSTS[$n]} answers" ;;
			1) fail "P2.pre.fleet: node ${n} answered NO to a probe that cannot answer NO, which means the channel is lying" ;;
			*) fail "P2.pre.fleet: node ${n} at ${HOSTS[$n]} could not be read" ;;
		esac
	done
	# A leader has to exist before anything commits, and the probe must NOT write:
	# a search needs a leader too and leaves no entry.
	for i in $(seq 1 40); do
		out="$(client_op -op search -vec "$(vec_for 1)" -k 1)"
		if committed "${out}"; then ok=1; break; fi
		sleep 0.25
	done
	if [ "${ok}" -eq 1 ]; then
		[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.pre.fleet: the three hosts answer and a query was served, so a leader exists and nothing was written to prove it"
	else
		fail "P2.pre.fleet: no query was served in ten seconds, so no leader formed"
	fi
	end_check P2.pre.fleet

	# THE IDENTITY, BY CONTENT. On iron the weaker command-line reading is not
	# enough: the file at naylamp/bin/naylampd is what deploy.sh put there and
	# what omnibus measures, so this compares its digest against the local build.
	begin_check
	sha_local="$(shasum -a 256 "${OUT_DIR}/naylampd" 2>/dev/null | cut -d' ' -f1)"
	if [ -z "${sha_local}" ]; then
		fail "P2.pre.identity: there is no cross compiled naylampd in gate/out to compare against"
	else
		for n in "${NODE_IDS[@]}"; do
			sha_remoto="$(read_on "$n" "0" 'sha256sum naylamp/bin/naylampd | cut -d" " -f1')" || {
				fail "P2.pre.identity: node ${n} binary digest could not be read"
				continue
			}
			if [ "${sha_remoto}" = "${sha_local}" ]; then
				vistos=$((vistos + 1))
			else
				fail "P2.pre.identity: node ${n} carries ${sha_remoto:0:16} and this run cross compiled ${sha_local:0:16}"
			fi
		done
		if [ "${vistos}" -ne "${#NODE_IDS[@]}" ]; then
			fail "P2.pre.identity: ${vistos} of ${#NODE_IDS[@]} hosts carry the binary this run built"
		fi
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.pre.identity: the ${vistos} hosts carry ${sha_local:0:16}, byte identical to the cross compiled build"
	end_check P2.pre.identity

	# THE REBOOT KEY. Without it the cut is a no-op and every green below would
	# attest a fleet that never lost power. The value is NOT a plain bitmask: 0
	# disables everything, 1 enables every function, and above 1 it is a mask
	# whose bit 128 is the reboot one. naylamp-1 read 176 on 2026-09-07.
	begin_check
	for n in "${NODE_IDS[@]}"; do
		v="$(sysrq_de "$n")" || { fail "P2.pre.sysrq: node ${n} /proc/sys/kernel/sysrq could not be read, and an unreadable answer is not a permission"; continue; }
		if sysrq_permite_reinicio "${v}"; then
			permiten=$((permiten + 1))
			note "node ${n} sysrq=${v}, the reboot bit is on"
		else
			fail "P2.pre.sysrq: node ${n} sysrq=${v}, which does not permit the reboot key, so the cut would be a no-op"
		fi
	done
	if [ "${permiten}" -ne "${#NODE_IDS[@]}" ]; then
		fail "P2.pre.sysrq: ${permiten} of ${#NODE_IDS[@]} hosts permit the reboot key, and the cut needs the three"
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.pre.sysrq: the ${permiten} hosts permit the reboot key"
	end_check P2.pre.sysrq
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
	note "run id ${NOMBRE_CORRIDA}"
	{
		echo "run: ${NOMBRE_CORRIDA}"
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

# ---- phase_cut ----------------------------------------------------------------
#
# ON IRON IT CUTS THE THREE, and that was a decision and not a default. The
# design carried both answers in writing until 2026-09-07: gate/p2.sh said "at
# least two of three" and the preflight said "the THREE at once". With two of
# three the survivor keeps its whole log, Raft heals the other two from it, and
# P2.recover.acked and P2.recover.faithful both go green WITHOUT THE BARRIER
# HAVING DONE ANYTHING; and P2.red.barrier goes RED for the wrong reason,
# because the mutant fleet also keeps a survivor and the arm cannot show the
# difference it exists to show. So the three, and P2.cut.fired demands that the
# THREE rebooted, by boot id, never a threshold of two.
phase_cut() {
	if [ "${ES_FIERRO}" -eq 1 ]; then
		phase_cut_fierro
		return
	fi
	begin_check
	local n before after cut_any=0 rc_b rc_a ilegibles=0
	declare -a PID_BEFORE=() BYTES_BEFORE=()
	for n in "${NODE_IDS[@]}"; do
		PID_BEFORE[$n]="$(node_pid "$n")"
		# The unreadable side is REMEMBERED and not counted here: counting in both
		# loops let `ilegibles` reach 4 over 2 replicas, and a figure that can
		# exceed its own denominator is not a figure.
		BYTES_BEFORE[$n]="$(entry_log_bytes "$n")" && rc_b=0 || rc_b=$?
		[ "${rc_b}" -ne 0 ] && BYTES_BEFORE[$n]="ilegible"
	done
	note "cutting nodes 1 and 2 with kill -9; the iron path cuts the THREE with echo b > /proc/sysrq-trigger"
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
		after="$(entry_log_bytes "$n")" && rc_a=0 || rc_a=$?
		before="${BYTES_BEFORE[$n]}"
		if [ "${rc_a}" -ne 0 ] || [ "${before}" = "ilegible" ]; then
			note "node ${n} entry log: ILEGIBLE on at least one side, so this replica contributes nothing"
			ilegibles=$((ilegibles + 1))
			continue
		fi
		note "node ${n} entry log: ${before} bytes before the cut, ${after} after"
		[ "${after}" -lt "${before}" ] && cut_any=$((cut_any + 1))
	done
	not_run P2.cut.bytes "kill -9 does not evict the page cache, so nothing on disk can be lost here and a green would attest nothing; measured this run, bytes lost across the cut: ${cut_any} of 2 replicas, ${ilegibles} unreadable readings. The iron path does not measure the log at all here: it measures a third canary written unsynced inside a bounded window, which is the only reading that separates a dry cut from a healthy barrier"
}

# phase_cut_fierro: seed the canary, arm it, cut the three, and prove they went
# down by boot id. Nothing here reads the entry log to decide whether the cut was
# dry: with the barrier healthy the acked loss is zero by construction, so the
# entry log is the wrong witness. The canary is the right one.
phase_cut_fierro() {
	local n antes despues rc t_arma t_corte ventana v id_antes id_despues
	declare -a BOOT_ANTES=() TESTIGO_ANTES=()

	# --- the boot ids before, which are the only oracle of the cut ---
	begin_check
	for n in "${NODE_IDS[@]}"; do
		id_antes="$(boot_id_de "$n")" || { fail "P2.cut.fired: node ${n} boot id could not be read BEFORE the cut, so nothing after it can be compared"; continue; }
		BOOT_ANTES[$n]="${id_antes}"
		note "node ${n} boot id before: ${id_antes}"
	done

	# --- seed the canary and prove it landed durable ---
	for n in "${NODE_IDS[@]}"; do
		if ! testigo_siembra "$n"; then
			fail "P2.cut.fired: node ${n} would not seed its canary, so this run has no witness of the cut"
			continue
		fi
		antes="$(testigo_tamano "$n")" || { fail "P2.cut.fired: node ${n} canary size unreadable after seeding"; continue; }
		if [ "${antes}" != "${TESTIGO_SEMILLA}" ]; then
			fail "P2.cut.fired: node ${n} canary seeded at ${antes} bytes and ${TESTIGO_SEMILLA} were asked for"
		fi
		TESTIGO_ANTES[$n]="${antes}"
	done
	if [ "${CHECK_FAILED}" -ne 0 ]; then
		end_check P2.cut.fired
		not_run P2.cut.bytes "the canary was not in place, so the cut has no witness and this verdict is not a reading"
		return
	fi

	# --- arm, then cut, and MEASURE the window between the two ---
	#
	# THE ARMING HAS ITS OWN GATE, and its absence made P2.cut.bytes publish a
	# green over three canaries nobody had armed. A reader measured it on
	# 2026-09-07 by making testigo_arma fail, which is what a full disk or a cut
	# ssh leaves: the three FAILs landed on P2.cut.fired, then P2.cut.bytes opened
	# its own begin_check, which resets CHECK_FAILED, read the seed alone on all
	# three and called it a dry cut. An unarmed canary is indistinguishable from a
	# dry cut by size, so the state has to be REMEMBERED PER NODE and not inferred.
	t_arma="$(ahora)"
	declare -a TESTIGO_ARMADO=()
	local armados=0
	for n in "${NODE_IDS[@]}"; do
		if testigo_arma "$n"; then
			TESTIGO_ARMADO[$n]=1
			armados=$((armados + 1))
		else
			TESTIGO_ARMADO[$n]=0
			fail "P2.cut.fired: node ${n} would not arm its canary, so nothing it says about the cut is evidence"
		fi
	done
	if [ "${armados}" -eq 0 ]; then
		end_check P2.cut.fired
		not_run P2.cut.bytes "no canary was armed on any host, so there is nothing whose loss could be read"
		return
	fi
	# THE CUTS GO IN PARALLEL, and that is the bound's problem and not tidiness.
	# Between arming and cutting this function used to open SIX sequential ssh
	# sessions, three to arm and three to cut, each a fresh TCP connection plus
	# handshake plus authentication against Azure. VENTANA_MAX is 5 s and it was
	# derived from the physics, commit=30, with nobody having measured the
	# instrument. Six round trips can spend it on their own, and then P2.cut.bytes
	# records none on every healthy run and the oracle of the cut turns
	# decorative. Firing the three at once takes the cut side down to one round
	# trip, and what it actually cost is printed so the bound stops being a guess.
	note "cutting the THREE with echo b > /proc/sysrq-trigger, fired in parallel"
	for n in "${NODE_IDS[@]}"; do
		corta_en "$n" &
	done
	wait
	t_corte="$(ahora)"
	ventana="$(delta "${t_arma}" "${t_corte}")"
	note "window between arming the canary and firing the cut: ${ventana} s (bound ${VENTANA_MAX} s, root is mounted commit=30)"

	# --- first they have to GO DOWN, then come back, and both waits are bounded ---
	for n in "${NODE_IDS[@]}"; do
		v="$(espera_caida "$n" 60 "${t_corte}")" && note "node ${n} stopped answering ssh ${v} s after the cut" \
			|| fail "P2.cut.fired: node ${n} never stopped answering ssh within 60 s of the cut, so it was not cut and every reading below about it is about a live machine"
	done
	for n in "${NODE_IDS[@]}"; do
		v="$(espera_vuelta "$n" 300 "${t_corte}")" && note "node ${n} answered ssh again ${v} s after the cut" \
			|| fail "P2.cut.fired: node ${n} did not answer ssh within 300 s of the cut (${v} s elapsed)"
	done

	# --- the oracle: the boot id CHANGED on all THREE ---
	local vueltas=0
	for n in "${NODE_IDS[@]}"; do
		id_despues="$(boot_id_de "$n")" || { fail "P2.cut.fired: node ${n} boot id could not be read after the cut"; continue; }
		if [ "${id_despues}" = "${BOOT_ANTES[$n]}" ]; then
			fail "P2.cut.fired: node ${n} kept boot id ${id_despues}, so it never rebooted and its data never lost power"
		else
			vueltas=$((vueltas + 1))
			note "node ${n} boot id after: ${id_despues}, changed"
		fi
	done
	if ! corte_completo "${vueltas}" "${#NODE_IDS[@]}"; then
		fail "P2.cut.fired: ${vueltas} of ${#NODE_IDS[@]} replicas rebooted, and this gate requires the three; a survivor makes every green below attest replication and not durability"
	fi
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.cut.fired: the THREE rebooted, by boot id, ${vueltas} of ${#NODE_IDS[@]}"
	end_check P2.cut.fired

	# --- P2.cut.bytes, over the canary and never over the barrier ---
	begin_check
	local secos=0 enteros=0 ilegibles=0 bajo_semilla=0
	for n in "${NODE_IDS[@]}"; do
		# A node whose canary was never armed contributes to NEITHER side. It is
		# counted as unreadable, because that is what it is: the run has no
		# evidence from it.
		if [ "${TESTIGO_ARMADO[$n]}" -ne 1 ]; then
			note "node ${n} canary was never armed, so it says nothing about the cut"
			ilegibles=$((ilegibles + 1))
			continue
		fi
		despues="$(testigo_tamano "$n")" && rc=0 || rc=$?
		if [ "${rc}" -ne 0 ]; then
			note "node ${n} canary: ILEGIBLE after the cut"
			ilegibles=$((ilegibles + 1))
			continue
		fi
		note "node ${n} canary: ${TESTIGO_ANTES[$n]} bytes synced, $(( TESTIGO_SEMILLA + TESTIGO_COLA )) expected if nothing was cut, ${despues} found"
		case "$(testigo_veredicto "${despues}" "${TESTIGO_SEMILLA}" "${TESTIGO_COLA}")" in
			bajo-semilla)
				# THE FOURTH OUTCOME, and it would be the finding of the whole
				# session: the cut took bytes that had been FSYNCED, which is a
				# broken barrier below the filesystem and not a dry cut. It never
				# counts as evidence that the cut worked; it is louder than that.
				bajo_semilla=$((bajo_semilla + 1))
				fail "P2.cut.bytes: node ${n} came back BELOW its synced seed, ${despues} of ${TESTIGO_SEMILLA}, so the cut took bytes that had crossed fsync; that is not a dry cut, it is a broken barrier under the filesystem"
				;;
			seco)    secos=$((secos + 1)) ;;
			entero)  enteros=$((enteros + 1)) ;;
			parcial) secos=$((secos + 1)); note "node ${n} canary came back PARTIAL at ${despues} bytes, which is still a dry cut" ;;
			*)       ilegibles=$((ilegibles + 1)) ;;
		esac
	done
	# The window first, because a canary armed outside it is not evidence and a
	# verdict on it would be a guess wearing a number.
	if ! ventana_dentro "${ventana}"; then
		not_run P2.cut.bytes "the canary was armed ${ventana} s before the cut and the bound is ${VENTANA_MAX} s; with the root at commit=30 the tail may have reached the platter on its own, so this reading is not evidence either way"
	elif [ "${ilegibles}" -ne 0 ]; then
		not_run P2.cut.bytes "${ilegibles} of ${#NODE_IDS[@]} canaries could not be read after the cut, and an unreadable canary is not a clean bill"
	elif [ "${bajo_semilla}" -ne 0 ]; then
		end_check P2.cut.bytes
		return
	elif [ "${secos}" -eq 0 ]; then
		not_run P2.cut.bytes "the ${enteros} readable canaries came back WHOLE, so nothing on them lost power: the machines rebooted but their unsynced tail survived, and no green below attests durability"
	else
		pass "P2.cut.bytes: ${secos} of ${#NODE_IDS[@]} canaries lost their unsynced tail, so the cut was dry on those hosts; window ${ventana} s of ${VENTANA_MAX} s"
	fi
	end_check P2.cut.bytes
}

phase_recover() {
	local t0 t1
	t0="$(ahora)"
	if [ "${ES_FIERRO}" -eq 1 ]; then
		phase_recover_arranque_fierro
	else
		phase_recover_arranque_local
	fi
	phase_recover_lecturas "${t0}"
}

# THE COLD COPIES COME DOWN FIRST, WITH THE MOTOR STOPPED, and the order is the
# verdict. After a sysrq-b nothing on those hosts is running, which is the only
# moment in the whole session when each replica's directory holds exactly what
# the barrier left and nothing replication put back. One `cluster.sh start-node`
# before this and the evidence is gone: OpenStorage truncates a torn tail on
# open, engine/raft/storage.go:237 and :250, so the file comes back SMALLER, and
# then Raft heals the gap from the leader. Neither is a lie the gate could see.
phase_recover_arranque_fierro() {
	local n v listo=0 t0 rc_l
	declare -a ANTES_LISTEN_FIERRO=()
	begin_check
	# The count BEFORE anything is relaunched, because the predicate below is that
	# it GREW and not that the word is present.
	for n in "${NODE_IDS[@]}"; do
		ANTES_LISTEN_FIERRO[$n]="$(lineas_listening_en "$n")" && rc_l=0 || rc_l=$?
		if [ "${rc_l}" -ne 0 ]; then
			ANTES_LISTEN_FIERRO[$n]=""
			fail "P2.recover.boots: node ${n} listening count could not be read before the relaunch, so no growth can be asserted"
		fi
	done
	for n in "${NODE_IDS[@]}"; do
		if copia_fria_de "$n" "${OUT_LOCAL}/cold-node${n}"; then
			note "node ${n} cold copy taken with the motor stopped, $(find "${OUT_LOCAL}/cold-node${n}" -type f 2>/dev/null | wc -l | tr -d ' ') files"
		else
			fail "P2.recover.boots: node ${n} cold copy could not be taken, and taking it later would audit a healed log"
		fi
	done
	# Only now is anything relaunched, and it is relaunched by the script that
	# already knew how: gate/cluster.sh start-node, whose launch line is the
	# historical one, byte for byte. Nothing here re-invents a naylampd command.
	for n in "${NODE_IDS[@]}"; do
		if "${GATE_DIR}/cluster.sh" start-node "$n" >>"${OUT_LOCAL}/relaunch.log" 2>&1; then
			note "node ${n} relaunched through gate/cluster.sh start-node"
		else
			fail "P2.recover.boots: node ${n} did not relaunch; see relaunch.log"
		fi
	done
	t0="$(ahora)"
	for n in "${NODE_IDS[@]}"; do
		if [ -z "${ANTES_LISTEN_FIERRO[$n]}" ]; then
			fail "P2.recover.boots: node ${n} has no baseline count, so its return cannot be asserted"
			continue
		fi
		v="$(espera_vuelta_listening "$n" 120 "${ANTES_LISTEN_FIERRO[$n]}" "${t0}")" \
			&& { listo=$((listo + 1)); note "node ${n} announced listening again ${v} s after the relaunch, count above ${ANTES_LISTEN_FIERRO[$n]}"; } \
			|| fail "P2.recover.boots: node ${n} never announced listening ABOVE its earlier count of ${ANTES_LISTEN_FIERRO[$n]} within 120 s (${v} s elapsed)"
	done
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.recover.boots: the ${listo} replicas started from their own directories, and their cold copies were taken before any of them did"
	end_check P2.recover.boots
}

# lineas_listening_en <n>: how many times that host has announced it is
# listening. The COUNT and never the presence, and the reason is written twice in
# this file already: naylamp/logs/node.log is APPENDED across launches, so after
# the first boot the line is there forever and a `grep -q` passes for a replica
# that was never relaunched. The rehearsal caught exactly that false green on
# 2026-09-06, and the first version of the iron path written on 2026-09-07
# reproduced it, asking `grep -q listening` after a reboot. Three outcomes, and
# an unreadable host is not a zero.
lineas_listening_en() {
	local n="$1" v
	v="$(read_on "${n}" "0 1" 'grep -c listening naylamp/logs/node.log 2>/dev/null')" || return 2
	v="$(printf '%s' "${v}" | tr -d '[:space:]')"
	case "${v}" in
		'') v=0 ;;
		*[!0-9]*) return 2 ;;
	esac
	printf '%s' "${v}"
}

# espera_vuelta_listening <n> <segundos> <cuenta anterior> <instante de partida>:
# waits for that host to announce it is listening MORE times than it had AND for
# its pid file to name a live process. Clause 24: the bound is enforced here and
# what gets printed is the elapsed time since the shared starting instant, not
# since this loop began, because the three hosts are waited for one after another
# and a per-loop figure would report the last one as instant.
espera_vuelta_listening() {
	local n="$1" tope="$2" antes="$3" t0="$4" i=0 ahora_n
	while [ "${i}" -lt "${tope}" ]; do
		ahora_n="$(lineas_listening_en "${n}")" && 		[ "${ahora_n}" -gt "${antes}" ] && 		ask_on "${n}" 'pid=$(cat naylamp/naylampd.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"' && {
			delta "${t0}" "$(ahora)"
			return 0
		}
		sleep 1
		i=$(( i + 1 ))
	done
	delta "${t0}" "$(ahora)"
	return 1
}

phase_recover_arranque_local() {
	begin_check
	local n
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
}

phase_recover_lecturas() {
	local t0="$1" t1 n rc
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
	#
	# THE COPY IS TAKEN BEFORE THE MOTOR IS RELAUNCHED, and on iron that ordering
	# is the whole verdict. Until 2026-09-07 the copy happened here, after the
	# nodes were already back up, so between the relaunch and the copy Raft had
	# healed the cut replicas from the leader and verify-log was auditing what
	# REPLICATION returned, not what the barrier left. On iron the copies come
	# down over scp in phase_recover_fierro, with the daemons still stopped, and
	# this branch only reads what is already on disk here.
	#
	# AND THE PREDICATE IS A MAJORITY, NOT THE THREE. Raft acks on a majority:
	# cluster.Config.Quorum() is len(Nodes)/2+1, engine/cluster/config.go:87, and
	# the leader advances its commit to matches[Quorum()-1], engine/raft/raft.go:1050,
	# which with three nodes is the SECOND highest match. Measured by probe on
	# 2026-09-07: with one replica partitioned the leader committed to index 2
	# while that replica stayed at 0. So a replica that had not yet persisted the
	# last acked write when the power went is LEGITIMATELY short, and a predicate
	# demanding all three is a false red on healthy hardware. Demanding a majority
	# keeps the red arm red: the barrierless mutant loses the write on every
	# replica, which is zero of three and never reaches two.
	begin_check
	local copia fieles=0 mayoria
	mayoria="$(mayoria_de "${#NODE_IDS[@]}")"
	for n in "${NODE_IDS[@]}"; do
		copia="${OUT_LOCAL}/cold-node${n}"
		if [ "${ES_FIERRO}" -eq 0 ]; then
			rm -rf -- "${OUT_LOCAL}/cold-node${n}"
			cp -R "${FLEET}/node${n}/data" "${copia}"
		fi
		if [ ! -d "${copia}" ]; then
			fail "P2.recover.faithful: node ${n} has no cold copy at $(basename "${copia}"), so it cannot be verified"
			continue
		fi
		set +e
		"${BIN}" verify-log -id "${n}" -peers "$(peers_of "$n")" -dir "${copia}" -manifest "${MANIFEST}" -dim "${DIM}" \
			> "${OUT_LOCAL}/verify-node${n}.txt" 2>&1
		rc=$?
		set -e
		if [ "${rc}" -eq 0 ]; then
			fieles=$((fieles + 1))
			note "node ${n} committed log verifies faithful against the manifest"
		else
			note "node ${n} did not verify faithful (exit ${rc}); see verify-node${n}.txt"
		fi
	done
	# THE EMPTINESS GATE, and its absence made this verdict green over nothing.
	# verify-log on an EMPTY cold copy against an EMPTY manifest exits 0 and prints
	# FAITHFUL with committed_commands=0: measured on 2026-09-07. Three empty
	# copies would then give fieles=3, three is at least two, green. And the
	# manifest empties itself whenever no client op exits 0, which is exactly the
	# case another finding of the same round produced. Its sister check,
	# P2.recover.acked, has had this gate since the day it was written; this one
	# did not.
	if [ ! -s "${MANIFEST}" ]; then
		fail "P2.recover.faithful: the acked manifest is EMPTY, so verifying against it proves nothing and a green here would be a green over nothing"
	elif faithful_suficiente "${fieles}" "${#NODE_IDS[@]}"; then
		pass "P2.recover.faithful: ${fieles} of ${#NODE_IDS[@]} cold copies verify faithful against a manifest of $(wc -l < "${MANIFEST}" | tr -d ' ') acked operations, and a majority is ${mayoria}"
	else
		fail "P2.recover.faithful: only ${fieles} of ${#NODE_IDS[@]} cold copies verify faithful and a majority is ${mayoria}; see verify-node<n>.txt"
	fi
	end_check P2.recover.faithful

	begin_check
	local h1 h2 r1 r2
	copia="${OUT_LOCAL}/cold-node1"
	if [ ! -d "${copia}" ]; then
		fail "P2.recover.idem: there is no cold copy of node 1, so there is nothing to recover twice"
		end_check P2.recover.idem
		t1="$(ahora)"
		T_RECOVER="$(delta "${t0}" "${t1}")"
		return
	fi
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
# The linux/arm64 copy of the mutant, which only the iron path builds and ships.
MUT_LINUX="${MUT_ROOT}/naylampd-mutante-linux-arm64"
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
	# LA MARCA LLEVA EL PID, y hasta el 7 de septiembre de 2026 era un fichero
	# VACIO. Sin pid dentro no hay con que decidir si el arbol es de una corrida
	# viva o de una muerta, asi que un arbol huerfano de una corrida matada se
	# quedaba para siempre: uno de 9784 KiB del 6 de septiembre seguia ahi al
	# cerrar el dia siguiente. Es la misma forma que el marcador RUNNING de este
	# fichero, y por la misma razon.
	printf 'pid: %s\nrun: %s\nscript: gate/p2.sh\n' "$$" "${NOMBRE_CORRIDA}" > "${MUT_MARCA}"
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
	# ON IRON THE MUTANT NEEDS A SECOND BINARY, and its absence was a defect a
	# reader measured on 2026-09-07 before any of this ran. phase_build already
	# knows the fleet is linux/arm64 and this machine darwin/arm64, and cross
	# compiles the sane daemon through gate/build.sh for exactly that reason. The
	# mutant did not inherit the lesson: it was built native and scp'd to Ubuntu,
	# where it would answer Exec format error. It would have failed CLOSED by
	# accident, because nohup returns 0 and the dead pid then makes
	# sha_del_binario_vivo unreadable, so P2.red.barrier fell for the wrong
	# reason AND only after cluster.sh stop-node had taken the sane fleet down.
	# The native one stays: P2.red.bites and the local daemon check need it.
	if [ "${ES_FIERRO}" -eq 1 ]; then
		( cd "${MUT_ROOT}/arbol" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "${MUT_LINUX}" ./engine/cmd/naylampd ) >>"${OUT_LOCAL}/red-build.log" 2>&1 \
			|| fail "P2.red.mutation: the mutant did not cross compile for linux/arm64, so nothing could be shipped"
		if [ -f "${MUT_LINUX}" ] && ! file "${MUT_LINUX}" 2>/dev/null | grep -q 'ELF.*ARM aarch64'; then
			fail "P2.red.mutation: the cross compiled mutant is not an aarch64 ELF: $(file "${MUT_LINUX}" 2>/dev/null | cut -c1-90)"
		fi
	fi
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
	#
	# THE LOOPBACK DAEMON CHECK IS SKIPPED ON IRON, and skipping it was not a
	# choice, it was a crash. MUT_PORTS and HOSTADDR are empty on the iron path,
	# and under `set -u` an index into an empty array is not an empty string, it
	# is an abort: `MUT_PORTS[$n]: unbound variable`. So an iron `all` died right
	# here, after the cut and after the recovery, and phase_red_fierro below was
	# unreachable code that no run could have reached. Measured by a reader on
	# 2026-09-07 before the fleet was ever powered on. On iron the daemon question
	# is answered where it belongs, on the three hosts, inside phase_red_fierro.
	if [ "${ES_FIERRO}" -eq 1 ]; then
		phase_red_fierro "${mutante}"
		return
	fi
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

	not_run P2.red.barrier "the cut, and the oracle that would read it. Four things WERE measured above and are named so this line is not read as a promise: the mutation applies, the mutant builds and differs, both defenders print their own FAIL line under it, and three replicas on it form a cluster. What was NOT measured is anything about loss: this rehearsal never cut the mutant, never read anything back from it and never compared it with the sane build. Its single put id=7 enters no manifest. The iron path below does cut it"
	not_run P2.red.fires "the mutant's own cut guard, which on iron is the identity of the binary that was executing when the power went; nothing on loopback can stand in for that"
}

# ---- phase_hygiene on iron ----------------------------------------------------
#
# The loopback version is VACUOUS here and a reader measured it: it reads
# ${OUT_LOCAL}/node<n>.pid, which only launch_node writes and which the iron path
# never calls, so left comes out 0 by construction and the verdict published "no
# node left running and the fleet directory is gone" about a local directory that
# never held anything. Meanwhile the three hosts kept naylamp/bin/naylampd-mutante,
# naylamp/data-mutante, naylamp/testigo-corte.bin, and the SANE FLEET STOPPED,
# because phase_red_fierro takes it down with cluster.sh stop-node and nothing
# brought it back.
#
# The removals are written against literal remote paths. They are not this run's
# to parameterise: they are fixed names this script itself chose.
phase_hygiene_fierro() {
	begin_check
	local n vivos=0 rc_a
	# 1. the mutant daemons, stopped by their own pid file and then asked again
	for n in "${NODE_IDS[@]}"; do
		ask_on "$n" 'if [ -f naylamp/naylampd-mutante.pid ]; then pid=$(cat naylamp/naylampd-mutante.pid); kill -TERM "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true; fi; true' >/dev/null 2>&1 || true
	done
	for n in "${NODE_IDS[@]}"; do
		ask_on "$n" 'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'
		rc_a=$?
		case "${rc_a}" in
			0) vivos=$((vivos + 1)); fail "P2.hygiene: node ${n} still has a mutant daemon alive" ;;
			1) ;;
			*) fail "P2.hygiene: node ${n} could not be asked whether its mutant daemon is alive, and an unreadable answer is not a clean host" ;;
		esac
	done
	# 2. what this run left on the three hosts, removed by literal path
	for n in "${NODE_IDS[@]}"; do
		ask_on "$n" 'rm -rf -- naylamp/data-mutante; rm -f -- naylamp/bin/naylampd-mutante naylamp/naylampd-mutante.pid naylamp/testigo-corte.bin' >/dev/null 2>&1 || true
	done
	for n in "${NODE_IDS[@]}"; do
		if ask_on "$n" 'test -e naylamp/data-mutante -o -e naylamp/bin/naylampd-mutante -o -e naylamp/testigo-corte.bin'; then
			fail "P2.hygiene: node ${n} still carries something this run put there"
		fi
	done
	# 3. AND THE SANE FLEET IS BROUGHT BACK, or this phase says out loud that it
	#    is leaving it down. phase_red_fierro stopped it to run the mutant, and a
	#    hygiene phase that closes green over three stopped daemons is lying about
	#    the state it leaves.
	for n in "${NODE_IDS[@]}"; do
		"${GATE_DIR}/cluster.sh" start-node "$n" >>"${OUT_LOCAL}/hygiene.log" 2>&1 || true
	done
	local levantados=0
	for n in "${NODE_IDS[@]}"; do
		if ask_on "$n" 'pid=$(cat naylamp/naylampd.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'; then
			levantados=$((levantados + 1))
		fi
	done
	if [ "${levantados}" -ne "${#NODE_IDS[@]}" ]; then
		fail "P2.hygiene: the sane fleet is at ${levantados} of ${#NODE_IDS[@]} after this run stopped it for the red arm, so this session leaves the fleet DOWN"
	fi
	# 4. and the local side, same as the rehearsal
	rm -rf -- "${OUT_DIR}/p2-fleet-${RUN_ID}"
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.hygiene: the three hosts carry nothing this run put there, no mutant daemon is alive, and the sane fleet is back up on ${levantados} of ${#NODE_IDS[@]}"
	end_check P2.hygiene
}

# ---- the red arm on iron ------------------------------------------------------
#
# It ships the mutant, runs it on the three hosts, and asks the two questions the
# rehearsal cannot: was the binary that lost power REALLY the mutant, and did the
# acked write die with it.
#
# THE IDENTITY IS READ BY CONTENT AND NOT BY PATH. P2.pre.identity already asks
# the weaker question of the sane fleet, comparing `ps -o args=` against the
# binary this run built, and that only separates mutant from sane while the two
# are invoked through different names. Here the reading is
# `sha256sum /proc/<pid>/exe`, which is the file the kernel is actually
# executing, and the assertion is that it DIFFERS from the sane build on all
# three. A red arm whose mutant never reached a host is worth nothing, and until
# today nothing in this gate could tell.
#
# AND THE WINDOW IS MEASURED AND BOUNDED. The fleet's root is mounted commit=30,
# measured in 10.13, so an unsynced write reaches the platter on its own inside
# thirty seconds. If more than VENTANA_MAX seconds pass between the mutant's ack
# and the cut, the journal may have saved what the missing barrier did not, and
# then a surviving write says nothing about the barrier. In that case the
# verdicts record `none` WITH THE WINDOW PRINTED, never pass.
phase_red_fierro() {
	local mutante="$1" n sha_sano sha_vivo distintos=0 ilegibles=0
	local t_ack t_corte ventana out ok=0 mgroup="" vueltas=0 perdidas=0 v

	sha_sano="$(shasum -a 256 "${BIN}" | cut -d' ' -f1)"

	# --- ship it, under its own name so record_binary_digests keeps measuring the
	# --- sane one, gate/omnibus.sh:589
	begin_check
	for n in "${NODE_IDS[@]}"; do
		# The LINUX one, never the native one. Shipping a darwin binary to Ubuntu
		# answers Exec format error, and the failure would have arrived disguised:
		# nohup returns 0, the pid dies, and the identity read comes back empty.
		if [ ! -f "${MUT_LINUX}" ]; then
			fail "P2.red.barrier: there is no linux/arm64 mutant to ship"
			break
		fi
		if scp "${SSH_OPTS[@]}" -q "${MUT_LINUX}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:${MUT_REMOTO}" 2>/dev/null \
			&& ask_on "$n" "chmod +x ${MUT_REMOTO}" \
			&& ask_on "$n" "head -c 4 ${MUT_REMOTO} | od -An -c | grep -q 'E   L   F'"; then
			note "mutant shipped to node ${n} as ${MUT_REMOTO}, and it is an ELF there"
		else
			fail "P2.red.barrier: the mutant did not reach node ${n} as a runnable ELF"
		fi
	done
	if [ "${CHECK_FAILED}" -ne 0 ]; then
		end_check P2.red.barrier
		not_run P2.red.fires "the mutant never reached the three hosts, so there was nothing whose identity to read"
		return
	fi

	# --- stop the sane fleet, start the mutant one, on its own port ---
	for n in "${NODE_IDS[@]}"; do
		"${GATE_DIR}/cluster.sh" stop-node "$n" >>"${OUT_LOCAL}/red-iron.log" 2>&1 || true
	done
	for n in "${NODE_IDS[@]}"; do
		[ -n "${mgroup}" ] && mgroup="${mgroup},"
		mgroup="${mgroup}${n}=${PRIV[$n]}:${MUT_PORT_FIERRO}"
	done
	for n in "${NODE_IDS[@]}"; do
		local peers="" j
		for j in "${NODE_IDS[@]}"; do
			if [ "$j" != "$n" ]; then
				[ -n "${peers}" ] && peers="${peers},"
				peers="${peers}${j}=${PRIV[$j]}:${MUT_PORT_FIERRO}"
			fi
		done
		run_on "$n" "cd naylamp || exit 1; mkdir -p data-mutante logs; NAYLAMP_TLS_CERT=certs/node-${n}.pem NAYLAMP_TLS_KEY=certs/node-${n}-key.pem NAYLAMP_TLS_CA=certs/ca.pem nohup ./bin/naylampd-mutante node -id ${n} -listen ${PRIV[$n]}:${MUT_PORT_FIERRO} -peers ${peers} -client ${CLIENT_ID}=${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO} -dir data-mutante -tick 10ms >> logs/mutante.log 2>&1 < /dev/null & echo \$! > naylampd-mutante.pid; sleep 1" \
			>>"${OUT_LOCAL}/red-iron.log" 2>&1 || fail "P2.red.barrier: the mutant would not start on node ${n}"
	done

	# --- THE IDENTITY, by content, on the three ---
	for n in "${NODE_IDS[@]}"; do
		sha_vivo="$(sha_del_binario_vivo "$n" 'naylamp/naylampd-mutante.pid')" || {
			note "node ${n}: /proc/<pid>/exe could not be read"
			ilegibles=$((ilegibles + 1))
			continue
		}
		if [ -z "${sha_vivo}" ]; then
			note "node ${n}: /proc/<pid>/exe answered empty"
			ilegibles=$((ilegibles + 1))
		elif ! identidad_confirmada "${sha_vivo}" "${sha_sano}"; then
			fail "P2.red.barrier: node ${n} is EXECUTING the sane build (${sha_vivo:0:16}), so this arm would measure the wrong binary"
		else
			distintos=$((distintos + 1))
			note "node ${n} is executing ${sha_vivo:0:16}, which differs from the sane ${sha_sano:0:16}"
		fi
	done
	if [ "${ilegibles}" -ne 0 ] || [ "${distintos}" -ne "${#NODE_IDS[@]}" ]; then
		fail "P2.red.barrier: identity confirmed by content on ${distintos} of ${#NODE_IDS[@]} hosts, ${ilegibles} unreadable; this arm requires the three"
		end_check P2.red.barrier
		not_run P2.red.fires "the mutant's identity was not confirmed on the three, so a cut here would measure something unnamed"
		return
	fi

	# --- one acked write on the mutant fleet, then the cut, window measured ---
	for v in $(seq 1 40); do
		set +e
		out="$(NAYLAMP_TLS_CERT="${CERT_DIR}/node-${CLIENT_ID}.pem" \
			NAYLAMP_TLS_KEY="${CERT_DIR}/node-${CLIENT_ID}-key.pem" \
			NAYLAMP_TLS_CA="${CERT_DIR}/ca.pem" \
			"${BIN}" client -listen "${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO}" -group "${mgroup}" \
			-dim "${DIM}" -op put -id 7 -vec "$(vec_for 7)" </dev/null 2>&1)"
		[ $? -eq 0 ] && ok=1
		set -e
		[ "${ok}" -eq 1 ] && break
		sleep 0.25
	done
	if [ "${ok}" -ne 1 ]; then
		fail "P2.red.barrier: the mutant fleet never acked a write, so there is nothing whose survival to measure"
		end_check P2.red.barrier
		not_run P2.red.fires "no acked write on the mutant fleet"
		return
	fi
	# The boot ids BEFORE this second cut, because P2.red.fires has to be able to
	# say the machines lost power and not merely that ssh answered again.
	declare -a BOOT_ROJO=()
	for n in "${NODE_IDS[@]}"; do
		BOOT_ROJO[$n]="$(boot_id_de "$n")" || fail "P2.red.barrier: node ${n} boot id could not be read before the cut"
	done
	t_ack="$(ahora)"
	note "the mutant fleet acked id=7; cutting the THREE now, in parallel"
	for n in "${NODE_IDS[@]}"; do
		corta_en "$n" &
	done
	wait
	t_corte="$(ahora)"
	ventana="$(delta "${t_ack}" "${t_corte}")"
	note "window between the mutant ack and the cut: ${ventana} s (bound ${VENTANA_MAX} s, root is mounted commit=30)"

	local caidas=0
	for n in "${NODE_IDS[@]}"; do
		v="$(espera_caida "$n" 60 "${t_corte}")" && { caidas=$((caidas + 1)); note "node ${n} stopped answering ssh ${v} s after the cut"; } \
			|| fail "P2.red.barrier: node ${n} never stopped answering ssh within 60 s of the cut, so it was not cut"
	done
	for n in "${NODE_IDS[@]}"; do
		v="$(espera_vuelta "$n" 300 "${t_corte}")" && { vueltas=$((vueltas + 1)); note "node ${n} answered ssh again ${v} s after the cut"; } \
			|| note "node ${n} did not answer ssh within 300 s (${v} s elapsed)"
	done

	# --- THE ORACLE, and the first version of it was wrong in three ways ---
	#
	# It asked `ask_on` whether the first mutant segment was non empty and read
	# anything that was not a YES as "the write is gone". Three defects, all
	# measured by a reader on 2026-09-07 before the fleet was ever powered on:
	#
	#   1. ask_on has THREE outcomes and that `if` collapsed two of them, so a
	#      host that could not be READ counted as a host that LOST the write. And
	#      this loop runs seconds after three machines rebooted, when sshd is
	#      still settling: one transient failure and the red arm went green. That
	#      is DEFER-072, in the one place on the iron path where it had not been
	#      paid.
	#   2. The predicate measured whether a FILE was empty, not whether the acked
	#      write was gone. openFreshSegment fsyncs the directory entry at
	#      engine/raft/storage.go:460, and the mutation only removes the entry
	#      sync at :304, so a log with any earlier flushed byte reads as "kept"
	#      while missing id=7, and an empty log reads as "lost" for reasons that
	#      have nothing to do with the barrier. False in both directions.
	#   3. Nothing read a boot id, so P2.red.fires could call three live machines
	#      "the binary that lost power".
	#
	# The oracle now is the same one the positive side uses: the cold copy of the
	# mutant's data directory, taken with the motor stopped, verified against a
	# manifest holding the one write that was acked.
	local ilegibles_perdida=0
	printf 'put 7 %s\n' "$(vec_for 7)" > "${OUT_LOCAL}/manifest-mutante.txt"
	for n in "${NODE_IDS[@]}"; do
		local copia_m="${OUT_LOCAL}/cold-mutante-node${n}"
		rm -rf -- "${copia_m}"
		mkdir -p "${copia_m}"
		if ! scp "${SSH_OPTS[@]}" -q -r "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:naylamp/data-mutante/." "${copia_m}/" 2>/dev/null; then
			note "node ${n} mutant data directory could not be brought down, so it says nothing"
			ilegibles_perdida=$((ilegibles_perdida + 1))
			continue
		fi
		set +e
		"${BIN}" verify-log -id "${n}" -peers "$(peers_of "$n")" -dir "${copia_m}" -manifest "${OUT_LOCAL}/manifest-mutante.txt" -dim "${DIM}" \
			> "${OUT_LOCAL}/verify-mutante-node${n}.txt" 2>&1
		rc=$?
		set -e
		if [ "${rc}" -eq 0 ]; then
			note "node ${n} mutant log still holds the acked write, so the missing barrier cost it nothing here"
		else
			perdidas=$((perdidas + 1))
			note "node ${n} mutant log does NOT hold the acked write: $(grep -m1 'NOT FAITHFUL\|missing from' "${OUT_LOCAL}/verify-mutante-node${n}.txt" 2>/dev/null | cut -c1-110)"
		fi
	done

	if ! ventana_dentro "${ventana}"; then
		not_run P2.red.barrier "the cut came ${ventana} s after the mutant ack and the bound is ${VENTANA_MAX} s; with the root at commit=30 the journal may have saved what the missing barrier did not, so a surviving write here says nothing about the barrier"
		end_check P2.red.barrier
		not_run P2.red.fires "the window above was spent, so the identity reading stands and the loss reading does not"
		return
	fi
	if [ "${ilegibles_perdida}" -ne 0 ]; then
		not_run P2.red.barrier "${ilegibles_perdida} of ${#NODE_IDS[@]} mutant directories could not be read after the cut, and a host nobody could read is not a host that lost a write"
	elif [ "${vueltas}" -ne "${#NODE_IDS[@]}" ]; then
		fail "P2.red.barrier: ${vueltas} of ${#NODE_IDS[@]} hosts came back, and this arm requires the three"
	elif [ "${perdidas}" -eq 0 ]; then
		fail "P2.red.barrier: the barrierless mutant did NOT lose its acked write on any host, so the sane fleet's green attests nothing"
	else
		pass "P2.red.barrier: the barrierless mutant lost its acked write on ${perdidas} of ${#NODE_IDS[@]} hosts, verified by verify-log against a one line manifest; window ${ventana} s of ${VENTANA_MAX} s"
	fi
	end_check P2.red.barrier

	# P2.red.fires: that the binary which LOST POWER was the mutant. Two halves,
	# and the first version had only one. Identity by content, which is measured
	# before the cut, says WHAT was running; the boot id says that it lost power.
	# Without the second half this verdict could call three live machines "the
	# binary that lost power", because corta_en swallows every error by design and
	# its exit status is not the oracle. The threshold is three, the same as the
	# positive side, and not the `vueltas >= 1` the first version accepted.
	begin_check
	local reinicios=0 id_r
	for n in "${NODE_IDS[@]}"; do
		id_r="$(boot_id_de "$n")" || { fail "P2.red.fires: node ${n} boot id could not be read after the cut"; continue; }
		if [ "${id_r}" = "${BOOT_ROJO[$n]}" ]; then
			fail "P2.red.fires: node ${n} kept boot id ${id_r}, so it never rebooted and its mutant never lost power"
		else
			reinicios=$((reinicios + 1))
		fi
	done
	if [ "${distintos}" -eq "${#NODE_IDS[@]}" ] && [ "${reinicios}" -eq "${#NODE_IDS[@]}" ]; then
		pass "P2.red.fires: the binary that lost power was the mutant on ${distintos} of ${#NODE_IDS[@]} hosts, read by sha256 of /proc/<pid>/exe and not by path, and the ${reinicios} boot ids changed"
	else
		fail "P2.red.fires: identity by content held on ${distintos} of ${#NODE_IDS[@]} hosts and ${reinicios} of ${#NODE_IDS[@]} rebooted; this arm requires the three on both"
	fi
	end_check P2.red.fires
}

# barre_mutantes_huerfanos: retira los arboles de mutante de corridas que ya no
# existen, y conserva los de corridas VIVAS.
#
# El predicado es el PROCESO y no la fecha: cada arbol lleva su marca con el pid
# dentro, y solo se retira si ese pid ya no esta. La vida se pregunta dos veces,
# `kill -0` y `ps`, porque `kill -0` lee EPERM como muerto y un proceso vivo de
# otro usuario se llevaria su arbol por delante con un mensaje tranquilizador;
# ese defecto ya se pago en la guarda de `make clean` el 7 de septiembre. Una
# marca sin pid legible NO se retira: se anuncia, porque es de antes de que la
# marca lo llevara y no hay con que decidir.
barre_mutantes_huerfanos() {
	local base="${TMPDIR:-/tmp}" d marca pid retirados=0 dudosos=0
	for d in "${base}"/naylamp-p2-mut-*; do
		[ -d "${d}" ] || continue
		[ "${d}" = "${MUT_ROOT}" ] && continue
		marca="${d}/.naylamp-p2-mut"
		if [ ! -f "${marca}" ]; then
			continue
		fi
		pid="$(sed -n 's/^pid: \([0-9][0-9]*\)$/\1/p' "${marca}" 2>/dev/null | head -1)"
		if [ -z "${pid}" ]; then
			dudosos=$((dudosos + 1))
			note "mutant tree ${d##*/} carries no pid in its marker, so it is LEFT ALONE: nothing here can tell whether its run is alive"
			continue
		fi
		if kill -0 "${pid}" 2>/dev/null || ps -p "${pid}" >/dev/null 2>&1; then
			note "mutant tree ${d##*/} belongs to pid ${pid}, which is alive: left alone"
			continue
		fi
		case "${d}" in
			"${base}"/naylamp-p2-mut-*) rm -rf -- "${d}"; retirados=$((retirados + 1)) ;;
			*) note "refusing to remove ${d}: it is not a mutant tree of this script" ;;
		esac
	done
	[ "${retirados}" -ne 0 ] && note "swept ${retirados} orphaned mutant trees whose run is gone"
	[ "${dudosos}" -ne 0 ] && note "${dudosos} mutant trees left alone for carrying no pid; they predate the marker that has one"
	return 0
}

# mut_barre <senal o vacio>: walks this run's mutant pid list, counts the ones
# that are alive AND ours, and signals them when a signal is given. It prints the
# count so the caller can use it as the predicate. The identity test is the
# command line, and liveness is asked twice because `kill -0` reports EPERM as
# dead: a live process belonging to another user would otherwise be swept from
# the count with a reassuring number.
mut_barre() {
	local senal="$1" p args vivos=0
	[ -f "${OUT_LOCAL}/pids-mut.txt" ] || { printf '0'; return 0; }
	while read -r p; do
		[ -z "${p}" ] && continue
		case "${p}" in ''|*[!0-9]*) continue ;; esac
		kill -0 "${p}" 2>/dev/null || ps -p "${p}" >/dev/null 2>&1 || continue
		args="$(ps -p "${p}" -o args= 2>/dev/null || true)"
		case "${args}" in
			"${MUT_ROOT}/naylampd-mutante node"*)
				vivos=$((vivos + 1))
				[ -n "${senal}" ] && ${senal} "${p}" 2>/dev/null || true
				;;
		esac
	done < "${OUT_LOCAL}/pids-mut.txt"
	printf '%s' "${vivos}"
}

phase_hygiene() {
	if [ "${ES_FIERRO}" -eq 1 ]; then
		phase_hygiene_fierro
		return
	fi
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
	# AND THE MUTANT DAEMONS, which this verdict did not look at until 2026-09-07.
	# phase_red launches three of them and writes their pids to pids-mut.txt, and
	# the only reader of that file was limpia_flota, which runs on the EXIT trap,
	# so it fires AFTER this verdict has already been recorded. The verdict went
	# green with three mutant daemons alive, every single run. It reads the file
	# now, and the order is KILL, then ASK, exactly as above for the sane fleet:
	# this verdict asserts that nothing is left running, not that nothing was
	# running when it arrived. Each pid is checked against its own command line
	# before being signalled or counted, so a pid the operating system has recycled
	# onto somebody else's process is left alone. `kill -0` alone is not the
	# question: it reads EPERM, another user's live process, as dead, so `ps` is
	# asked too.
	mut_barre "kill" >/dev/null
	sleep 1
	mut_barre "kill -9" >/dev/null
	sleep 0.5
	local mut_vivos
	mut_vivos="$(mut_barre "")"
	if [ "${mut_vivos}" -ne 0 ]; then
		left=$((left + mut_vivos))
		fail "P2.hygiene: ${mut_vivos} mutant daemons are still running after this phase tried to stop them"
	fi
	# The removal is written against a LITERAL prefix with the run id appended
	# inline, never a bare variable. Clause 23, and gate/p1.sh's own rule.
	if [ "${ES_FIERRO}" -eq 1 ]; then
		rm -rf -- "${OUT_DIR}/p2-fleet-${RUN_ID}"
	else
		rm -rf -- "${OUT_DIR}/p2-local-fleet-${RUN_ID}"
	fi
	# THE MUTANT TREE, and its root comes from a variable, so clause 23's escape is
	# the one taken: the directory is validated before the order and the order
	# refuses if it does not hold. Two conditions and both have to be true: the
	# marker file this run wrote is inside it, and the run id has the shape this
	# script deletes by, which was checked the moment it was built.
	barre_mutantes_huerfanos
	if [ -n "${MUT_ROOT}" ] && [ -f "${MUT_MARCA}" ]; then
		rm -rf -- "${MUT_ROOT}"
		[ -d "${MUT_ROOT}" ] && fail "P2.hygiene: the mutant tree survived its own removal"
	elif [ -d "${MUT_ROOT}" ]; then
		fail "P2.hygiene: ${MUT_ROOT} exists and does not carry this run's marker, so it is not removed"
	fi
	if [ -d "${FLEET}" ]; then
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
	if [ "${ES_FIERRO}" -eq 1 ]; then
		rm -rf -- "${OUT_DIR}/p2-fleet-${RUN_ID}"
	else
		rm -rf -- "${OUT_DIR}/p2-local-fleet-${RUN_ID}"
	fi
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
usage: NAYLAMP_P2_LOCAL=1 p2.sh <all|build|pre|provenance|red>    (rehearsal, loopback)
       p2.sh <all|build|pre|provenance|red>                       (IRON, three hosts over ssh)

Five subcommands and not one more. An earlier version of this line advertised
nine, five of which fell through to this message: the phases exist as functions
but only these five are wired, because the rest need the fleet a previous phase
left running and there is no state between invocations. Advertising them cost a
directory under gate/out per attempt, since the artifact was created before the
subcommand was validated.

Without NAYLAMP_P2_LOCAL=1 this script takes the IRON path: it sources
gate/common.sh, which refuses on its own unless NAYLAMP_GATE_HOSTS,
NAYLAMP_GATE_PRIVATE and NAYLAMP_GATE_KEY are all set, and it expects the fleet
already up, which is what gate/p2-preflight.sh hot leaves behind. It cuts the
THREE hosts with echo b > /proc/sysrq-trigger. There is no default subcommand: a
bare invocation is a usage error.
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
	# On iron nothing binds a local socket, so the arrays are empty and this loop
	# has nothing to walk. It is not skipped by an `if`: the emptiness IS the
	# condition, which is one fewer branch that can be wrong.
	for puerto in ${NODE_PORTS[@]+"${NODE_PORTS[@]}"} "${CLIENT_PORT}" ${MUT_PORTS[@]+"${MUT_PORTS[@]}"} ${MUT_CLIENT_PORT:+"${MUT_CLIENT_PORT}"}; do
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
			# The iron run expects THREE more verdicts than the rehearsal, and
			# they are exactly the three the rehearsal declares NOT RUN because
			# loopback cannot stand in for a power cut: the sysrq permission, the
			# canary that measures the cut, and the mutant's own loss reading.
			if [ "${ES_FIERRO}" -eq 1 ]; then
				EXPECTED="P2.build P2.pre.fleet P2.pre.identity P2.pre.sysrq P2.provenance P2.workload.acked P2.cut.fired P2.cut.bytes P2.recover.boots P2.recover.elects P2.recover.acked P2.recover.faithful P2.recover.idem P2.red.mutation P2.red.bites P2.red.daemon P2.red.barrier P2.red.fires P2.hygiene"
			else
				EXPECTED="P2.build P2.pre.fleet P2.pre.identity P2.provenance P2.workload.acked P2.cut.fired P2.recover.boots P2.recover.elects P2.recover.acked P2.recover.faithful P2.recover.idem P2.red.mutation P2.red.bites P2.red.daemon P2.hygiene"
			fi
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
		pre)
			# P2.pre.sysrq only exists where there is a kernel to ask, so the list
			# follows the path. A verdict this run produces and EXPECTED does not
			# name is a verdict nobody reads, and the final block would close green
			# over it.
			EXPECTED="P2.build P2.pre.fleet P2.pre.identity"
			[ "${ES_FIERRO}" -eq 1 ] && EXPECTED="${EXPECTED} P2.pre.sysrq"
			phase_build; phase_pre; COMPLETED=1 ;;
		provenance) EXPECTED="P2.build P2.provenance"; phase_build; phase_provenance; COMPLETED=1 ;;
		red)
			EXPECTED="P2.build P2.red.mutation P2.red.bites P2.red.daemon"
			[ "${ES_FIERRO}" -eq 1 ] && EXPECTED="${EXPECTED} P2.red.barrier P2.red.fires"
			EXPECTED="${EXPECTED} P2.hygiene"
			phase_build; phase_red; phase_hygiene; COMPLETED=1 ;;
	esac
	t_end="$(ahora)"
	T_OVERHEAD="$(delta "${t_start}" "${t_end}")"
	{
		echo "run: ${NOMBRE_CORRIDA}"
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

# NAYLAMP_P2_SOURCE_ONLY=1 defines everything and runs nothing, which is how
# gate/p2-iron-test.sh gets at the predicates of the iron path without a fleet.
# It is not a back door: it cannot make a run happen, only stop one, and a gate
# invoked with it set produces no verdicts and no artifact at all. The bench sets
# it; nothing else in this tree does.
if [ "${NAYLAMP_P2_SOURCE_ONLY:-}" = 1 ]; then
	return 0 2>/dev/null || exit 0
fi

main "$@"
