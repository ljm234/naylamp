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
# THIS SCRIPT WAS THE REHEARSAL AND NOTHING ELSE UNTIL 2026-09-07, and this
# paragraph said so until 2026-09-08. The iron path exists now: without
# NAYLAMP_P2_LOCAL=1 this script cuts three hosts with sysrq, and the usage block
# at the foot says how. What is still true, and is the reason the rehearsal is not
# a scaffold to be thrown away, is its job: to exercise THIS SCRIPT before it costs
# VM time, and to time three of the five terms the design could not put a number
# on. What the iron path refuses without is its fleet identity, which gate/common.sh
# checks on its own, and that refusal is clause 15's shape: an instrument that
# breaks stops whoever is measuring, and one that answers falsely lets them carry
# on.
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
# LO QUE EL SELLO NECESITA SABER DE LA CORRIDA, y va aqui arriba con el resto del
# estado en vez de dentro de la funcion que lo escribe, por la misma razon que
# VERDICTS: el sello se escribe desde phase_hygiene_fierro y se termina desde
# al_salir, o sea desde dos sitios que no se llaman entre si, y un dato que solo
# existiera en uno de los dos no llegaria al otro. SELLO_ESCRITO_AQUI es la
# bandera de la clausula 30 y su unicidad esta razonada en el bloque del sello.
SELLO_ESCRITO_AQUI=0
SUBCOMANDO=""
ARRANCO_A=""
PROV_HEAD=""
PROV_DIRTY=""
PROV_SHA=""
PID_EN_VUELO=""

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
		# LA LINEA DE CIERRE TAMBIEN TIENE RAMA DE FIERRO, y es la otra mitad de lo
		# que el banner decia mal: una corrida sobre tres maquinas de verdad cerraba
		# diciendo "all rehearsal checks passed". Es la ULTIMA linea del log, que es
		# la que se cita, y estaba mintiendo sobre la unica corrida que no se puede
		# repetir. El texto del ensayo se queda EXACTO, porque hay bancos que lo
		# casan por su literal, y el de fierro dice lo que es.
		if [ "${ES_FIERRO}" -eq 1 ]; then
			echo "gate: all IRON checks passed (${EXPECTED})"
		else
			echo "gate: all rehearsal checks passed (${EXPECTED})"
		fi
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
	#
	# AND IT HAS AN IRON BRANCH SINCE 2026-09-09, which is the most expensive
	# labelling defect this file could have had and it was here from the day the
	# iron path landed. `grep -c ES_FIERRO` inside this function gave ZERO. So a
	# run on three real machines, cutting them with sysrq, printed "This is NOT
	# gate evidence and it seals nothing", "Three directories on 127.0.0.1 play
	# three replicas... there is no fleet" and "Its cut is kill -9", and closed
	# with "all rehearsal checks passed". The design hangs two of its declared
	# exclusions on this banner precisely because it is what whoever cites the
	# result reads. **The log IS the artifact and it cannot be fixed afterwards**:
	# a second run measures a different tree. It was brought by an external reader
	# who was given the design and could not run anything.
	#
	# AND SINCE THE SEAL LANDED IT WAS WORSE, NOT BETTER: that same run now writes
	# a SEALED file into an artifact whose own log says it seals nothing.
	if [ "${ES_FIERRO}" -eq 1 ]; then
		banner_fierro
	else
		banner_ensayo
	fi
}

banner_fierro() {
	cat <<BANNER | tee /dev/stderr
================================================================================
NAYLAMP PHASE 2 GATE, IRON. run id ${NOMBRE_CORRIDA}
THIS IS GATE EVIDENCE. This run seals its artifact and the seal is what keeps it.

WHAT THIS RUN EXERCISES: the property. Three real machines over ssh, the binaries
cross compiled for linux/arm64, a real election, a real filesystem and a real
kernel. The cut is echo b > /proc/sysrq-trigger inside the guest, which reboots
without syncing and takes the guest page cache with it.

WHAT IT DOES NOT EXERCISE, and this is a boundary and not a pending item: a cut
model different from the simulation's. The fleet's three OS disks are
caching: ReadWrite, read on 2026-09-06 with the fleet powered off, so the host
write cache survives the guest reboot. That is the choice, made on 2026-09-06 by
whoever commissions this work, and the reason is that moving the disks to caching
None would move the fleet under which the Phase 1 artifacts were sealed.

AND IT STOPPED BEING A READING ON 2026-09-07: naylamp-1 was powered on, cut with
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
HOSTS: ${NAYLAMP_GATE_HOSTS:-not recorded}
CARRIER: the Raft entry log inside naylampd, which is the half that makes its
directory entry durable. raft.openFreshSegment calls fsyncDir(s.dir)
(engine/raft/storage.go:455 and :460); persist.openActiveSegment returns without
it (engine/persist/wal.go:149), and fsyncDir appears zero times in that file.
That gap is DEFER-028 and this gate does NOT exercise it: persist.DB is out by
name, and no binary in this tree starts one. Outside its own package, persist is
used only for encoding helpers.
WITNESS: the manifest of acked client operations, built on THIS machine, outside
anything that gets cut. A witness inside the cut set is not a witness.
================================================================================
BANNER
}

banner_ensayo() {
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
# LA MAYORIA NO SE RE-DERIVA PARA LA VENTANA ESTRECHA, y la decision es del 9 de
# septiembre de 2026 y de quien encarga. La pregunta la trajo un lector externo:
# con escrituras EN VUELO, un ack puede llegar a un milisegundo del corte, y los
# dos seguidores podrian quedarse legitimamente cortos, con lo que `fieles` daria 1
# de 3 y esta funcion pondria roja la fidelidad.
#
# LA RESPUESTA, con sus palabras: **Raft ackea cuando la MAYORIA ha PERSISTIDO**.
# Un ack a un milisegundo del corte YA tenia mayoria durable, o el motor esta roto.
# Si despues del corte esa mayoria no esta, ese es exactamente el fallo que este
# gate existe para medir, y entra en la politica de rojo como rojo de PROPIEDAD
# legitimo. **Aflojar la mayoria por lo estrecha que sea la ventana retira el caso
# que hace valer al gate**: el unico momento en que la promesa del ack se puede
# romper es justo ese, y un gate que se protege de su propio caso interesante no
# mide nada.
#
# LO QUE ESO OBLIGA A ESCRIBIR, y va aqui porque es donde se lee: si esta funcion
# se pone roja sobre una escritura en vuelo, la conclusion NO es "la ventana era
# estrecha". Es que hubo un ack sin mayoria durable detras.
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
	# EL `sync` GLOBAL NO VUELVE, y su marcha es la mitad B5 de la decision del 9 de
	# septiembre de 2026. `sync` vacia TODA la pagina sucia del host, y ahi dentro va
	# el log de raft: sembrar el testigo asi dejaba en el plato todo lo ackeado antes
	# de cortar, con lo que el brazo positivo no podia ponerse rojo hubiera barrera o
	# no. **Un sync global dentro de un gate de durabilidad es el instrumento
	# anulando lo que mide**, y esta linea es su ejemplar.
	#
	# LO QUE ENTRA ES LO QUE EL DISENO PEDIA: se sincroniza el FICHERO y su
	# DIRECTORIO, y nada mas. El fsync del directorio no es adorno: es la mitad que
	# hace durable la ENTRADA del fichero, y es exactamente el hueco que DEFER-028
	# nombra en persist. Se hace con python3 porque ninguna orden de shell puede
	# pedir un fsync de directorio, y `dd conv=fsync` solo alcanza al fichero.
	#
	# Y SE NIEGA EN VOZ ALTA si python3 no esta, en vez de caerse al `sync` de antes:
	# volver al instrumento que anula la medida por no encontrar el bueno es la clase
	# 15 con otra ropa. La mitad `hot` del preflight comprueba que esta.
	ask_on "${n}" "python3 -c \"
import os
d = os.path.dirname('${TESTIGO_REMOTO}') or '.'
f = os.open('${TESTIGO_REMOTO}', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
os.write(f, b'\\0' * ${TESTIGO_SEMILLA})
os.fsync(f)
os.close(f)
h = os.open(d, os.O_RDONLY)
os.fsync(h)
os.close(h)
\""
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
	# EL -n ES OBLIGATORIO Y NO ES ESTILO, y lo obliga una corrida real y no una
	# precaucion. Esta orden se escribio para el host remoto, donde sudo es
	# passwordless, pero el banco de fierro la ejecuta LOCALMENTE a traves de su stub
	# de ssh, que reescribe /proc/ a una casa de mentira y corre la orden con bash -c.
	# En una maquina de trabajo con tty, un sudo pelado PIDE CONTRASENA y la corrida
	# se para ahi: medido el 14 de septiembre de 2026, y quien lo nombra es el
	# registro del sistema, con TTY=ttys006 y tres intentos fallidos. Con -n falla en
	# el acto en vez de colgarse, y donde sudo SI es passwordless -Azure y el runner
	# de CI- se comporta exactamente igual que sin la bandera, asi que el camino de
	# fierro no cambia. Lo que cambia es que deja de haber un sitio que cuelga.
	run_on "${n}" 'sudo -n sh -c "echo b > /proc/sysrq-trigger"' >/dev/null 2>&1 || true
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
	# -n por la misma razon que el corte. Este sitio NO se alcanza hoy: su unico
	# llamador es phase_red_fierro, que el banco de fierro solo extrae como texto con
	# awk y nunca ejecuta. Se arregla igual porque el dia que esa fase se recorra
	# contra la flota de mentira serian tres sudo pelados mas, y el defecto se
	# descubriria otra vez por un prompt en mitad de una corrida.
	read_on "${n}" "0" "sudo -n sha256sum /proc/\$(cat ${pidfile})/exe 2>/dev/null | cut -d' ' -f1"
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

# ---- el sello, DEFER-098 ------------------------------------------------------
#
# WHY THIS EXISTS, and it is not gate/p1.sh's block copied over: it is the same
# defect measured in THIS file. The iron path creates gate/out/p2-<run id> and
# wrote SEALED zero times; the only appearance of the word above was a comment.
# The Makefile's clean guard has asked by SHAPE since 2026-09-06,
# `p[0-9]-* ! p[0-9]-local-*`, which is on purpose and covers Phase 2, so every
# iron run of this gate left a directory that `make clean` refuses to sweep and
# that nothing ever sealed: neither cleanable nor kept by anyone's decision. Row
# 5b of gate/clean-guard-test.sh had already measured that refusal and certified
# it as correct behaviour, which is exactly how the cost stayed unwritten: the
# half that says "and something has to write the seal" was nobody's row.
#
# AND IT IS BORN FINISHED, which is the half gate/p1.sh had to learn afterwards
# and is why DEFER-098 named it before this was written. Clause 30: an artifact
# sealed while the run is ALIVE has to be TERMINATED when the run ends, or its
# seal describes a run that had not happened yet. p1.sh sealed from phase_hygiene
# and never rewrote, so its three archived artifacts all carry 19 expected against
# 18 verdicts and the missing one is always P1.hygiene, the only check that talks
# about the artifact itself. Worse, a run killed by -9 in that window left exactly
# the same shape as a complete one, so the artifact could not tell them apart.
# Here the seal closes in al_salir from the first day: a complete run leaves the
# two counts equal and a killed one leaves them short.
#
# UNA SOLA BANDERA, y la diferencia con gate/p1.sh va escrita en vez de heredada.
# La clausula 30 pide una bandera que distinga HABER ESCRITO el sello de
# HABERTELO ENCONTRADO. En p1.sh esa distincion es cara y hace falta, porque tiene
# un subcomando, `p1.sh hygiene <run id>`, que ADOPTA el id de otra corrida y
# entra en su directorio: alli, terminar un sello que no escribiste le machaca sus
# diecinueve veredictos con los dos tuyos. Este guion no tiene esa puerta. Sus
# cinco subcomandos son all, build, pre, provenance y red, NINGUNO toma un run id,
# y RUN_ID se acuna con la fecha y el pid de ESTE proceso. Asi que la bandera de
# la escritura es la unica que puede valer algo aqui, y el caso "el sello ya
# estaba" SI es alcanzable, porque seal_artifact se llama dos veces por corrida,
# en phase_hygiene_fierro y en al_salir: se separa EN VOZ ALTA y no con una
# segunda bandera que hoy no podria diferir nunca de la primera. Una guarda contra
# una puerta que no existe es codigo muerto con aspecto de defensa, que es lo que
# p1.sh dice de si mismo al negarse a escribir una rama para p1-local.
#
# THE PREDICATE IS NOT NEW. This script already separates an iron artifact,
# p2-<run id>, from a rehearsal's, p2-local-<run id>, and says in the block that
# builds the two names that the prefix is what decides whether `make clean` sweeps
# the directory or refuses to. Everything below rests on that and invents nothing.
es_artefacto_de_fierro() {
	# $1 is a basename. The rehearsal prefix is excluded FIRST and as its own case
	# arm rather than left to the digit that follows, which would exclude it too.
	# It is written this way because the reason is not the shape: a seal is the
	# mark that says "keep this, it is evidence", and letting one appear inside a
	# p2-local- would undo from the inside the three places that swear a rehearsal
	# can never read as gate evidence.
	#
	# THE FLEET DIRECTORIES FALL OUT OF THE SECOND ARM ON THEIR OWN, because what
	# follows p2- there is not a digit, AND THAT IS NOT THE SAME AS SAFE. A reader
	# measured what it costs and the first version of this comment presented it as
	# a tidy outcome. p2-fleet-<run id> matches the Makefile's refusal pattern,
	# `p[0-9]-* ! p[0-9]-local-*`, and is invisible to this predicate, so a -9
	# between phase_build and the removal in phase_hygiene_fierro leaves a directory
	# that no P2.hygiene line will ever name and that nothing can ever seal. What it
	# does NOT do is block a clean for ever, and saying so would be the opposite
	# error: `make clean UNSEALED_OK=1` takes it, and the Makefile writes down why it
	# refuses in that direction rather than the other, "a predicate that refuses too
	# much costs a run of make clean UNSEALED_OK=1; one that refuses too little costs
	# the artifact". So the cost is one typed override after a killed iron run, it is
	# the declared trade and not an oversight, and it is written here so the next
	# reader does not have to re-derive it. The rehearsal's p2-local-fleet-<run id>
	# is excluded by the Makefile too and costs nothing.
	case "$1" in
		p2-local-*) return 1 ;;
		p2-[0-9]*Z-[0-9]*) return 0 ;;
		*) return 1 ;;
	esac
}

seal_artifact() {
	# THE REHEARSAL NEVER SEALS, and this is the first line for the same reason it
	# is the first line in gate/p1.sh: everything below it would otherwise have to
	# remember. A p2-local- directory is swept by an ordinary make clean and that is
	# what it is for.
	[ "${ES_FIERRO}" -eq 1 ] || return 0
	[ "${RUN_STARTED}" -eq 1 ] || return 0
	es_artefacto_de_fierro "$(basename "${OUT_LOCAL}")" || return 0
	[ -d "${OUT_LOCAL}" ] || return 0
	# EMPTY MEANS NO SEAL, AND THE RUNNING MARKER DOES NOT COUNT AS CONTENT. Both
	# halves are gate/p1.sh's, measured there and inherited here on purpose. A phase
	# that writes no raw output still mkdirs its artifact, and sealing an empty
	# directory would keep it for ever; and the seal is written while the run is
	# alive, so its own marker is still inside, and counting it would let a run that
	# wrote nothing else seal a directory whose only file then disappears, leaving a
	# SEALED EMPTY directory that no sweep can ever take.
	#
	# AND THE OTHER THREE PLACES THAT ASK THE SAME QUESTION ARE
	# artefactos_de_fierro_sin_sello below, veredicto_del_sello below that, and the
	# guard in the Makefile. p1.sh paid twice for having them out of step: a
	# directory whose sole file is RUNNING is empty to the one that would seal it
	# and full to the ones that refuse to clean it, so it becomes neither sealable
	# nor cleanable.
	#
	# THE CARDINAL SAID TWO AND THE SITES WERE THREE, and a reader measured it in the
	# same change that added the third: this comment was inherited from p1.sh at a
	# stage of ITS history that had already been superseded there, so it arrived
	# saying "before adding a fourth" in a file where the fourth was going in
	# fourteen lines below. The four predicates are byte-identical today; what was
	# wrong was the number in front of them. The way to keep them in step is to grep
	# for `ls -A` across this file and the Makefile before adding a fifth, and to
	# re-count rather than to trust this sentence.
	[ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ] || return 0
	if [ -e "${OUT_LOCAL}/SEALED" ]; then
		# LA SEGUNDA LLAMADA DE LA MISMA CORRIDA ES EL CASO NORMAL y sale por aqui en
		# silencio: phase_hygiene_fierro sella, y al_salir vuelve a llamar por las
		# corridas que nunca llegan a la higiene. Lo que NO es normal es encontrarse
		# un sello en el propio directorio sin haberlo escrito, porque RUN_ID se acuna
		# por corrida y nadie mas puede haber estado ahi; se dice y no se toca nada.
		[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] && return 0
		echo "gate: ${OUT_LOCAL}/SEALED exists and THIS run did not write it, so nothing here is touched and no seal is completed" >&2
		return 0
	fi
	{
		echo "Phase 2 iron gate artifact, sealed by gate/p2.sh."
		echo
		echo "run id:      ${RUN_ID}"
		echo "subcommand:  ${SUBCOMANDO:-unknown}"
		echo "started:     ${ARRANCO_A:-not recorded}"
		echo "sealed:      $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "HEAD:        ${PROV_HEAD:-not recorded}"
		echo "uncommitted: ${PROV_DIRTY:-not recorded}"
		echo "hosts:       ${NAYLAMP_GATE_HOSTS:-not recorded}"
		echo "naylampd:    ${PROV_SHA:-not recorded}"
		echo "expected:    ${EXPECTED:-not recorded}"
		echo "verdicts:    ${VERDICTS# }"
		echo
		echo "This file is what keeps make clean from taking the directory. It is"
		echo "written on RED as well as on green, because a red run is evidence and"
		echo "this house archives the output of a red arm. The verdicts line above is"
		echo "rewritten once, when the run closes, and the closed: line is that"
		echo "moment: a seal with no closed: line was written by a run that did not"
		echo "reach its own end. Remove this file when the run stops being cited,"
		echo "which is a decision for a person and not for make clean."
	} > "${OUT_LOCAL}/SEALED" || true
	# EL `|| true` ES POR PORTABILIDAD Y NO POR DESCUIDO. Medido en el bash 3.2 de
	# esta maquina, un grupo `{ ...; } > fichero` cuya redireccion falla devuelve 1 y
	# NO dispara `set -e`; en el bash 5 del runner esa semantica no esta medida, y de
	# las dos posibles la mala es que aborte, porque esta llamada corre dentro de
	# phase_hygiene_fierro, que no lleva `set +e`, y un aborto ahi se llevaria por
	# delante la fase entera. Con el `|| true` la respuesta es la misma en los dos
	# shells y la decide la comprobacion de abajo, que es donde tiene que decidirse.
	#
	# Y SE COMPRUEBA QUE EL SELLO ESTA, en vez de darlo por hecho porque la
	# redireccion no se quejo. Medido en el bash 3.2 de esta maquina: un grupo
	# `{ ...; } > fichero` cuyo destino no se puede crear imprime su error, devuelve
	# 1 y NO dispara `set -e`. Sin esta comprobacion, la bandera se ponia a 1 y la
	# consola decia "sealed the artifact" sin que existiera fichero ninguno, que es
	# la clase 15 entera: un instrumento que contesta en falso es peor que uno que se
	# rompe. Y el caso a medias, con el fichero creado y la escritura cortada por
	# disco lleno, es peor todavia, porque un SEALED vacio pasa cualquier `-e` y la
	# corrida cerraria verde sobre un sello sin contenido: por eso la pregunta es
	# `-s` y no `-e`.
	if [ ! -s "${OUT_LOCAL}/SEALED" ]; then
		rm -f -- "${OUT_LOCAL}/SEALED"
		echo "gate: the seal could NOT be written at ${OUT_LOCAL}/SEALED, so this run's artifact is unsealed and make clean will refuse to sweep gate/out" >&2
		return 0
	fi
	SELLO_ESCRITO_AQUI=1
	note "sealed the artifact: ${OUT_LOCAL}/SEALED"
}

# EL SELLO SE TERMINA EN al_salir, y nace terminandose. gate/p1.sh llego a esta
# funcion el 8 de septiembre de 2026 despues de tres artefactos archivados que no
# la tenian; este guion la trae desde su primer sello porque DEFER-098 lo exigio
# por nombre antes de que existiera ninguno.
#
# LO QUE NO ARREGLA, dicho aqui para que el bloque no se lea como un cierre: la
# ventana SIGUE EXISTIENDO. Un -9 entre el sello que escribe phase_hygiene_fierro
# y la entrada en la trampa deja el sello a medias igual, y ademas deja el
# marcador RUNNING puesto, que es la otra mitad de la evidencia. Esto no cierra la
# ventana: la hace legible desde el artefacto, que es lo que la clausula 30 pide.
completa_el_sello() {
	[ "${SELLO_ESCRITO_AQUI}" -eq 1 ] || return 0
	[ -f "${OUT_LOCAL}/SEALED" ] || return 0
	# UNA SOLA FORMA DE NOMBRE, y no dos. El ensayo no llega hasta aqui porque
	# seal_artifact devuelve en su primera linea con ES_FIERRO distinto de 1, asi
	# que la bandera se queda en cero y una rama para p2-local seria codigo muerto
	# con aspecto de defensa. Lo que no sea el nombre de fierro lo dice en voz alta.
	case "${OUT_LOCAL}" in
		"${OUT_DIR}/p2-${RUN_ID}") ;;
		*)
			echo "gate: the seal was written but NOT completed: ${OUT_LOCAL} is not p2-${RUN_ID}" >&2
			return 0 ;;
	esac
	local esperada marca linea vistas
	# UN .a-medias HUERFANO SE BARRE ANTES, y existe: si el proceso muere a mitad de
	# la escritura de al lado, el fichero temporal sobrevive dentro de un artefacto
	# que el sello protege de make clean. No hace dano, porque el sello quedo
	# intacto, pero se queda para siempre. Medido en p1.sh con `ulimit -f`.
	rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
	esperada="$(grep -m1 '^expected:' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)"
	marca="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	# SE RECONSTRUYE LEYENDO, no con un sed sobre el sitio. Un sed en el sitio no es
	# atomico: si muere a medias deja el sello truncado, y un sello truncado sigue
	# frenando a make clean mientras pierde lo que decia. Aqui se escribe al lado,
	# se comprueba, y solo entonces se mueve encima de una sola vez.
	#
	# Y SE ESCRIBE CON UNA REDIRECCION Y NO CON UNA SUSTITUCION DE COMANDO, que es
	# la clausula 31: un `case` dentro de `$( )` es un error de sintaxis en bash 3.2
	# que `bash -n` NO caza, porque el cuerpo de una sustitucion no se parsea hasta
	# que se ejecuta, y al correr no mata el guion: el error va a stderr, la
	# sustitucion devuelve el texto suelto de detras del parentesis y la ejecucion
	# sigue con rc 0. Se cometio en p1.sh el 8 de septiembre y lo unico que evito
	# publicar un sello de basura fue la comprobacion de `expected:` de abajo.
	#
	# EL `|| [ -n "${linea}" ]` NO SOBRA. Sin el, `read` devuelve falso en una
	# ultima linea que no termina en salto y el bucle la TIRA; y el `closed:` que se
	# anade compensa exactamente el uno que se pierde, asi que el recuento de lineas
	# da el visto bueno y el sello se publica con una linea de menos.
	vistas=0
	{
		while IFS= read -r linea || [ -n "${linea}" ]; do
			case "${linea}" in
				verdicts:*)
					vistas=$((vistas + 1))
					printf 'verdicts:    %s\n' "${VERDICTS# }"
					printf 'closed:      %s\n' "${marca}" ;;
				closed:*) ;;
				*) printf '%s\n' "${linea}" ;;
			esac
		done < "${OUT_DIR}/p2-${RUN_ID}/SEALED"
	} > "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" || true
	# EL `|| true` ES EL MISMO DE seal_artifact Y POR LA MISMA RAZON: que la respuesta
	# a una redireccion que falla no dependa de la version del shell. Aqui hay ademas
	# un `set +e` en la trampa que llama, pero apoyarse en eso es apoyarse en el
	# llamador, y esta funcion tiene mas de uno.
	#
	# EL ORDEN DE ESTAS PREGUNTAS IMPORTA. Primero si hay fichero de al lado, porque
	# con el directorio sin permiso de escritura la redireccion falla, el bucle no
	# corre y `vistas` se queda en cero: preguntar por `vistas` antes anunciaria que
	# el sello NO TIENE linea de veredictos, que es falso y ademas describe mal la
	# causa. Luego que trae, y solo al final si cuadra.
	#
	# Y LA DE `expected:` ES LA QUE IMPORTA de las dos ultimas: es la linea por la
	# que dos sellos se comparan para decir que uno sustituye a otro, asi que esta
	# reescritura no puede tocarla. Tiene que salir identica byte a byte.
	if [ ! -s "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: nothing could be written beside it, so that seal now looks like one from a run that did not reach its end, and there is no way to say otherwise from inside a directory that cannot be written" >&2
	elif [ "${vistas}" -eq 0 ]; then
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal has no verdicts line, so it was left exactly as it was and carries no closed line" >&2
	elif [ "$(grep -m1 '^expected:' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" = "${esperada}" ] \
		&& [ "$(grep -c '' "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" 2>/dev/null)" -ge "$(grep -c '' "${OUT_DIR}/p2-${RUN_ID}/SEALED" 2>/dev/null)" ]; then
		# Y EL `mv` SE COMPRUEBA, que es la unica de las cuatro salidas que no decia
		# nada cuando fallaba. Un `mv` que falla deja el `.a-medias` DENTRO de un
		# artefacto que el sello protege de make clean, y ahi se queda para siempre:
		# el barrido de huerfanos de arriba no puede volver a alcanzarlo, porque
		# RUN_ID es unico por corrida y ninguna otra entrara en este directorio.
		# Heredado tal cual de gate/p1.sh y corregido aqui.
		if ! mv -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias" "${OUT_DIR}/p2-${RUN_ID}/SEALED"; then
			rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
			echo "gate: the seal could not be completed; the rewrite was correct but could not be moved on top of it, and the leftover beside it was removed" >&2
		fi
	else
		rm -f -- "${OUT_DIR}/p2-${RUN_ID}/SEALED.a-medias"
		echo "gate: the seal could not be completed; it keeps the verdicts the hygiene phase wrote" >&2
		echo "gate: the rewrite did not match the seal it came from, so nothing was moved on top of it" >&2
	fi
}

# EL BARRIDO, y mira SOLO los artefactos de esta phase. Podria mirar cualquier
# p<n>-, que es lo que hace la guarda del Makefile, y no lo hace: esa guarda
# decide si BORRAR, asi que un nombre que no reconoce tiene que pararla; esta
# funcion produce un VEREDICTO de Phase 2, y hacer que P2.hygiene se ponga roja
# por como haya quedado el archivo de Phase 1 seria colgar el veredicto de una
# corrida de la limpieza de otra. Lo que la casa no pierde por eso esta medido:
# el Makefile sigue negandose ante cualquier p<n>- sin sello, y gate/p1.sh barre
# los suyos con la funcion gemela.
#
# IMPRIME LA CUENTA DE LOS QUE VISITO, y no es decoracion: sin ella la frase "todos
# los artefactos de fierro llevan su sello" se publica igual habiendo visitado
# NINGUNO, que es una afirmacion exhaustiva sobre el conjunto vacio con la misma
# forma que la de verdad. Vuelve por la salida y no por una global porque quien la
# llama la lee dentro de una sustitucion, o sea en un subshell donde una
# asignacion global no sobreviviria.
artefactos_de_fierro_sin_sello() {
	local d b out="" vistos=0
	if [ -d "${OUT_DIR}" ]; then
		for d in "${OUT_DIR}"/*; do
			[ -d "${d}" ] || continue
			b="$(basename "${d}")"
			es_artefacto_de_fierro "${b}" || continue
			# LA MISMA PREGUNTA SOBRE EL VACIO QUE seal_artifact, y el marcador se
			# descuenta aqui tambien. Con una de las dos fuera de paso, un directorio
			# cuyo unico fichero es RUNNING queda ni sellable ni limpiable.
			[ -n "$(ls -A "${d}" 2>/dev/null | grep -vx RUNNING)" ] || continue
			vistos=$((vistos + 1))
			[ -e "${d}/SEALED" ] && continue
			out="${out} ${b}"
		done
	fi
	printf '%s%s' "${vistos}" "${out}"
}

# EL ORDEN ES TODO EL PUNTO Y POR ESO ES UNA FUNCION Y NO DOS LINEAS SUELTAS:
# SELLAR PRIMERO, BARRER DESPUES, para que el barrido incluya el sello que esta
# misma corrida acaba de escribir. Una corrida que no consigue sellarse se pone
# roja AQUI y AHORA, en la misma invocacion, en vez de que la evidencia se
# descubra ausente meses despues cuando alguien vaya a citarla. Es la razon por la
# que gate/p1.sh sella desde phase_hygiene y no solo desde su trampa, y la
# heredamos entera.
#
# LA LLAMAN LAS DOS HIGIENES, la de fierro y la del ensayo, y no hacen lo mismo
# dentro: en el ensayo seal_artifact devuelve en su primera linea y lo unico que
# corre es el barrido. Eso es deliberado. El barrido es lo que convierte un
# artefacto de fierro sin sello en una linea roja, y un ensayo que corre en esta
# maquina todos los dias es quien mas veces va a pasar por delante de uno.
# ---- el techo de los artefactos de ENSAYO -------------------------------------
#
# POR QUE EXISTE, y la medida va delante de la decision. El 8 de septiembre de 2026
# habia bajo gate/out DOS JORNADAS de ensayos acumulados y una flota huerfana, del 7
# de septiembre a las 02:19 al 8 a las 12:14 en hora local. Cuantos eran, con la
# orden que lo cuenta, esta en ../corridas/naylamp-signing-readiness-20260916T1629Z.txt:
# la forma que no caduca es que la acumulacion eran dos jornadas y no una sesion.
# Ninguno lleva sello y ninguno puede llevarlo: seal_artifact
# devuelve en su primera linea con ES_FIERRO distinto de 1. Nada los vigilaba y nada
# los retiraba.
#
# Y LO QUE NO ERA CIERTO, dicho porque la decision se tomo sobre lo contrario y la
# medida la corrigio: NO estaban protegidos por el sello, ni antes ni despues del
# arreglo de esta manana. La guarda de `make clean` excluye `p[0-9]-local-*` por
# FORMA, asi que se los llevaria a todos de una vez. Lo que faltaba no era la
# distincion entre ensayo y fierro, que ya vive en TRES sitios -aqui, en
# es_artefacto_de_fierro y en el Makefile-, sino un techo del lado del ensayo.
#
# POR QUE UN TECHO Y NO LA REGLA DE DEFER-097. Ese item dice que ningun barrido de
# limpieza toca gate/out mientras siga abierto, y esa regla se escribio para lo que
# cuesta VM y no se puede reconstruir: un artefacto de FIERRO mide un arbol y una
# segunda corrida mide otro. Un ensayo de localhost no es eso, y lo que cuesta lo
# dice el reloj y no una cifra recitada aqui: minutos de reloj de esta maquina y
# ningun dinero. El reloj, con sus tres ejes, sale de
# `NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all` y esta en
# ../corridas/naylamp-signing-readiness-20260916T1629Z.txt. La regla se lee
# ahora como lo que protege, el fierro, y el ensayo queda fuera. La decision es de
# quien encarga y esta fechada el 8 de septiembre de 2026.
#
# POR QUE CINCO, con la medida al lado y no por simetria con el banco. Cada
# artefacto ocupa una fraccion pequena de lo que ocupaba el conjunto, y la medida de
# hoy, con su orden, esta en ../corridas/naylamp-signing-readiness-20260916T1629Z.txt: la forma
# que no caduca es que el techo se elige por un orden de magnitud y no al filo. Las
# dos jornadas medidas corrieron mas ensayos que cinco, o sea que
# cinco NO cubre una sesion entera, y eso es deliberado: para lo que se miran estos
# artefactos, que son los logs de los nodos de una corrida que acaba de ponerse
# roja, la ventana es de minutos y la de la sesion de al lado ya no sirve porque el
# arbol se movio.
#
# LO QUE EL TECHO CUESTA, dicho y no escondido: reproducir un ensayo da una corrida
# contra el arbol de HOY, no contra el que midio el que se retiro. Lo que se pierde
# no es el tiempo de un ensayo, sino la posibilidad de leer un ensayo de un
# arbol que ya no existe. Es el intercambio que se acepta a proposito, y es el mismo
# que esta casa NO acepta para el fierro.
# ---- EL MARCADOR MANDA SOBRE EL TECHO ----------------------------------------
#
# ESTA FUNCION EXISTE POR UN INCIDENTE QUE YA VA POR LA TERCERA VEZ, y las dos
# primeras estan escritas en el Makefile: el 28 de agosto de 2026 un `make clean`
# se llevo el directorio de un ensayo VIVO a mitad de un recall de 50k, y el 7 de
# septiembre lo hizo otra vez. De ahi salio el marcador RUNNING y la guarda que lo
# respeta. **La tercera la escribi con el techo de los ensayos**, que borraba por
# antiguedad sin mirar el marcador. Medido y no razonado: con un artefacto viejo
# que llevaba dentro un RUNNING con un pid VIVO, y seis mas nuevos por delante, el
# techo se lo llevo. Un mecanismo nuevo que repite el incidente que otro mecanismo
# ya aprendio a evitar es peor que el incidente, porque la leccion estaba escrita a
# dos ficheros de distancia.
#
# EL PREDICADO ES EL PROCESO Y NO EL FICHERO, que es la forma exacta que usa la
# guarda del Makefile y se copia a proposito. Un marcador cuyo proceso murio NO
# protege: si protegiera, una corrida matada con -9 bloquearia el techo para
# siempre, y asi es como una defensa se acaba quitando por estorbar. Se dice al
# barrerlo, en vez de barrerlo en silencio.
#
# Y `kill -0` NO BASTA, que es la otra mitad que el Makefile pago: devuelve
# no-cero por EPERM igual que por ESRCH, asi que un proceso vivo de OTRO usuario
# se leia como muerto y se barria con un mensaje tranquilizador. Se pregunta
# tambien a `ps`, y solo se llama muerto a un pid que NINGUNO de los dos ve.
#
# TRES RESPUESTAS Y NO DOS: vivo, muerto, y sin marcador. La de en medio es la que
# se dice en voz alta, porque un directorio que se retira llevando dentro los
# restos de una corrida que no termino es informacion, no ruido.
marcador_de() {
	local d="$1" pid
	[ -f "${d}/RUNNING" ] || { printf 'sin-marcador'; return 0; }
	pid="$(sed -n 's/^pid: //p' "${d}/RUNNING" 2>/dev/null | head -n1)"
	case "${pid}" in
		''|0|*[!0-9]*) printf 'ilegible'; return 0 ;;
	esac
	if kill -0 "${pid}" 2>/dev/null || ps -p "${pid}" >/dev/null 2>&1; then
		printf 'vivo'
	else
		printf 'muerto'
	fi
}

CONSERVA_ENSAYOS=5

barre_ensayos_viejos() {
	# SOLO EN EL ENSAYO. Una corrida de fierro cuesta horas de VM y no esta ahi para
	# hacer limpieza; y lo unico que este barrido borra son nombres de ensayo, asi
	# que en fierro no tendria nada que hacer de todas formas. Se dice con una guarda
	# en vez de dejarlo a que los patrones no casen.
	#
	# Y LA SALIDA TEMPRANA IMPRIME SU CERO, que la primera version no hacia: devolvia
	# rc 0 y NADA por la salida, asi que quien la leyera recibia una cadena vacia
	# donde el resto de los caminos le da un numero. Lo caza la fila 17z del banco,
	# que esperaba `0` y recibia ``. Una funcion que a veces contesta una cifra y a
	# veces nada obliga a todo el que la llame a defenderse de las dos formas, y esa
	# defensa es justo la que se olvida un dia.
	[ "${ES_FIERRO}" -eq 1 ] && { printf '0'; return 0; }
	local nombre d n=0 retirados=0 propio
	propio="$(basename "${OUT_LOCAL}")"
	# EL BUCLE PARTE NOMBRES Y NO RUTAS, que es una mejora sobre la version de
	# gate/p2-guard-test.sh y no una copia. Alli el `for` parte la salida de `ls -dt`
	# sobre rutas enteras, y esa forma asume que ningun componente del camino lleva un
	# espacio; la suposicion va escrita alli. Aqui el `ls` corre DENTRO del directorio
	# y lo que se parte son nombres, que este guion valida por forma antes de crear
	# nada, asi que la suposicion desaparece en vez de declararse.
	for nombre in $(cd "${OUT_DIR}" 2>/dev/null && ls -dt p2-local-[0-9]*Z-[0-9]* 2>/dev/null); do
		d="${OUT_DIR}/${nombre}"
		[ -d "${d}" ] || continue
		# EL DE ESTA CORRIDA NUNCA, y se excluye POR NOMBRE y no por confiar en que
		# sea el mas reciente. El banco se apoya en que el suyo es el mas nuevo; eso
		# es cierto hasta el dia que dos corridas se solapan, y entonces una borra el
		# artefacto vivo de la otra. Una exclusion explicita no tiene ese dia.
		[ "${nombre}" = "${propio}" ] && continue
		n=$((n + 1))
		[ "${n}" -le "${CONSERVA_ENSAYOS}" ] && continue
		# EL MARCADOR MANDA SOBRE EL TECHO, y esta es la linea que faltaba. Un
		# artefacto cuya corrida sigue VIVA no se retira por viejo: el techo es una
		# regla sobre lo que ya termino. Y el que lleva un marcador cuyo proceso murio
		# se retira, pero diciendolo, porque sus restos son informacion. La cuenta del
		# techo NO se le devuelve al vivo: ocupa su sitio en la ventana igual que
		# cualquier otro, y lo unico que cambia es que no se borra.
		case "$(marcador_de "${d}")" in
			vivo)
				echo "gate: NO retiro ${d}: su corrida sigue viva, con marcador y pid vivo dentro" >&2
				continue ;;
			ilegible)
				echo "gate: NO retiro ${d}: lleva un marcador con un pid que no se puede leer, y eso no es lo mismo que estar muerto" >&2
				continue ;;
			muerto)
				echo "gate: retiro ${d} por el techo: lleva el marcador de una corrida que no termino" >&2 ;;
		esac
		# Clausula 23: la ruta se compone de OUT_DIR mas un nombre que se acaba de
		# comprobar contra la forma exacta por la que este guion borra, y lo que no
		# sea esa forma se dice en voz alta en vez de borrarse.
		case "${nombre}" in
			p2-local-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${nombre}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NO retiro ${d}: no es un artefacto de ensayo de este gate" >&2 ;;
		esac
	done
	# Y LAS FLOTAS HUERFANAS, que es un invariante y no un segundo techo: una flota
	# NUNCA sobrevive a su artefacto. limpia_flota retira la de la corrida en curso,
	# asi que una que siga ahi es de una corrida muerta; si su artefacto ya no esta,
	# lo que queda no lo cita nadie. Hay una en el arbol desde el 7 de septiembre de
	# 2026, p2-local-fleet-20260907T161431Z-86419, y es la prueba de que el caso
	# ocurre.
	local flota id
	for flota in $(cd "${OUT_DIR}" 2>/dev/null && ls -d p2-local-fleet-[0-9]*Z-[0-9]* 2>/dev/null); do
		[ -d "${OUT_DIR}/${flota}" ] || continue
		id="${flota#p2-local-fleet-}"
		[ -d "${OUT_DIR}/p2-local-${id}" ] && continue
		case "${flota}" in
			p2-local-fleet-[0-9]*Z-[0-9]*)
				rm -rf -- "${OUT_DIR}/${flota}"
				retirados=$((retirados + 1)) ;;
			*)
				echo "gate: NO retiro ${OUT_DIR}/${flota}: no es una flota de ensayo de este gate" >&2 ;;
		esac
	done
	printf '%s' "${retirados}"
}

veredicto_del_sello() {
	seal_artifact
	# LA CONDICION PREGUNTA SI HABIA ALGO QUE SELLAR. Sin eso, una corrida de fierro
	# que murio antes de escribir un solo fichero crudo se pondria roja diciendo
	# "esta corrida escribio un artefacto", que no es verdad. Un artefacto vacio es
	# el unico caso en que no sellar es lo correcto.
	# LA PREGUNTA ES POR EL FICHERO Y NO POR LA BANDERA, y la primera version de esta
	# linea preguntaba por la bandera. La diferencia la trajo un lector con su caso:
	# si el artefacto YA lleva un sello que esta corrida no escribio, seal_artifact
	# se niega en voz alta y deja la bandera en cero, y con la bandera como predicado
	# esta linea gritaba "esta corrida no sello" sobre un artefacto que SI esta
	# sellado. Veredicto equivocado y remedio equivocado. gate/p1.sh no cae en eso
	# porque en su sitio pregunta por SEALED_THIS_RUN, que tambien vale 1 cuando el
	# sello simplemente se encuentra; aqui, con una sola bandera, la salida limpia es
	# no preguntar por ninguna y mirar el objeto.
	if [ "${ES_FIERRO}" -eq 1 ] && [ ! -e "${OUT_LOCAL}/SEALED" ] \
		&& [ -d "${OUT_LOCAL}" ] && [ -n "$(ls -A "${OUT_LOCAL}" 2>/dev/null | grep -vx RUNNING)" ]; then
		fail "P2.hygiene: this run wrote an artifact and did not seal it, so make clean will refuse to sweep gate/out until somebody seals it by hand"
	fi
	local sin vistos
	sin="$(artefactos_de_fierro_sin_sello)"
	vistos="${sin%% *}"
	sin="${sin#"${vistos}"}"
	if [ -n "${sin}" ]; then
		fail "P2.hygiene: p2 iron artifacts under gate/out with no SEALED file, which make clean will refuse to sweep:${sin}"
	elif [ "${vistos}" -eq 0 ]; then
		note "P2.hygiene: there is no p2 iron artifact under gate/out, so this phase attests nothing about seals. A rehearsal writes p2-local-* and this is its normal answer"
	else
		note "P2.hygiene: all ${vistos} p2 iron artifacts under gate/out carry their seal, counted one by one"
	fi
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
	# Y SE GUARDAN, porque el sello los cita y el sello se escribe dos fases mas
	# tarde. Se guarda lo que ya se derivo aqui en vez de que seal_artifact vuelva a
	# leer provenance.txt: un fichero se puede quedar a medias, y entonces el sello
	# describiria la corrida por un crudo roto en vez de por lo que la corrida midio.
	# Las tres quedan vacias en los subcomandos que no pasan por esta fase, y el
	# sello imprime "not recorded" con el subcomando al lado para que se sepa cual.
	PROV_HEAD="${head}"
	PROV_DIRTY="${dirty}"
	note "HEAD ${head}"
	note "uncommitted entries: ${dirty}"
	note "toolchain $(go version)"
	note "run id ${NOMBRE_CORRIDA}"
	# LA HUELLA SE CALCULA UNA VEZ Y SE USA DOS, y no dos veces por dos sitios: el
	# crudo y el sello tienen que decir el mismo numero, y dos lecturas del mismo
	# binario separadas por una fase admiten un dia en que no lo digan.
	# EL `|| true` NO SOBRA, y su ausencia era una regresion de esta misma pasada.
	# `VAR="$(tuberia)"` toma el estado de la tuberia, y con `pipefail` un `shasum`
	# que falla lo vuelve no-cero, o sea que bajo `set -e` mata la corrida entera y
	# la deja sin un solo veredicto: la forma que la clausula 15 llama peor que una
	# rotura, y que el comentario de doce lineas mas arriba prohibe con esas
	# palabras. Lo que habia antes vivia dentro de un `echo`, donde el estado de la
	# sustitucion se descarta; sacarlo a una asignacion lo convirtio en fatal. Las
	# dos lecturas de arriba llevan su `|| true` por lo mismo, y esta faltaba.
	PROV_SHA="$(shasum -a 256 "${BIN}" 2>/dev/null | cut -d' ' -f1 || true)"
	{
		echo "run: ${NOMBRE_CORRIDA}"
		echo "head: ${head}"
		echo "uncommitted: ${dirty}"
		echo "toolchain: $(go version)"
		echo "repo: ${REPO_DIR}"
		echo "naylampd sha256: ${PROV_SHA}"
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
# ---- B5: LA MITAD DEL ACK QUE NUNCA SE EJERCITABA -----------------------------
#
# LA DECISION ES DEL 9 DE SEPTIEMBRE DE 2026 Y ES DE QUIEN ENCARGA, y cambia lo
# que este gate mide, asi que va escrita entera y no como un arreglo.
#
# LO QUE UN LECTOR EXTERNO MIDIO, y es el hallazgo mas caro que ha tenido este
# fichero: **la corrida de fierro habria salido VERDE sin haber medido la
# propiedad, por el camino por defecto**. Dos cosas a la vez.
#
#   UNA. `testigo_siembra` hacia `head -c N /dev/zero > fichero && sync`. `sync`
#   es GLOBAL: vacia toda la pagina sucia del host, y ahi dentro va el log de
#   raft. El diseno no pedia eso, pedia sincronizar el FICHERO y su DIRECTORIO.
#
#   DOS. No habia ninguna escritura EN VUELO en el instante del corte. La carga
#   termina sus 33 operaciones, devuelve, y solo entonces se corta.
#
# Con las dos juntas, en el instante del `echo b` todo lo ackeado estaba en el
# plato HAYA BARRERA O NO, y `P2.recover.acked` y `P2.recover.faithful` en verde
# significaban "lo que se sincronizo a mano sobrevivio a un reinicio", que no es la
# propiedad. **Un oraculo que no puede fallar no es un oraculo.**
#
# Y ES UN EJEMPLAR QUE SE ANOTA POR SU CLASE, no por su instancia: **un `sync`
# global dentro de un gate de durabilidad es el instrumento anulando lo que mide.**
# No es una orden de mas: es la orden que borra la pregunta. La misma forma que la
# clausula 15 describe, llevada al unico sitio donde no deja rastro, porque el
# resultado sigue saliendo y sale verde.
#
# LA MITAD DEL ACK, dicha como la dijo quien decide: la propiedad es "ack implica
# durable", y sin escrituras en vuelo nunca se ejercita la mitad del ack, porque
# el mutante solo pierde algo si el corte cae ENTRE el ack y la barrera. Con la
# carga cerrada antes del corte, esa ventana no existe y el brazo rojo no tiene
# donde morder.

# EL RANGO DE IDS EN VUELO ES PROPIO Y NO SE SOLAPA con el de la carga, que usa
# del 1 al 30. Se separan para que un id en vuelo no pueda confundirse con uno de
# la carga al leer el manifiesto ni al leer el log.
# EL RANGO SE ELIGE CONTRA vec_for Y NO CONTRA LOS IDS, y la primera version lo
# eligio contra los ids. Lo trajo un lector externo y es el defecto de la seccion
# 10.9 REABIERTO: `vec_for` compone su vector con `(id >> j) & 1` para j en 0..DIM-1
# con DIM=8, o sea que **solo depende de `id mod 256`**. Con el rango en 500 y una
# cota de 200, el id 512 daba el VECTOR CERO y los ids 513 a 542 daban exactamente
# los mismos vectores que los ids 1 a 30 de la carga. `P2.recover.acked` busca por
# el VECTOR con `-k 1` y exige que vuelva su id: en cuanto la carga y el vuelo
# comparten punto, sale un rojo que nombra la causa equivocada.
#
# La correccion que 10.9 escribio, la expansion binaria, se invalida en cuanto un id
# pasa de 255, y nadie lo dijo entonces porque entonces ningun id pasaba. El rango
# vive ahora ENTERO por debajo de 256 y por encima de los ids de la carga, asi que
# no envuelve y no puede colisionar. Y no se deja escrito como un comentario: se
# comprueba, abajo, con una funcion que se niega en voz alta.
ID_EN_VUELO_DESDE=100
# LA COTA, que la clausula 24 obliga: sin ella el bucle sigue intentando contra
# tres maquinas que ya no contestan hasta que alguien lo mate. Se para por dos
# vias, la cuenta y los fallos seguidos, y la segunda es la que de verdad lo cierra
# porque es la que dice que la conexion murio.
EN_VUELO_MAX=120
EN_VUELO_FALLOS_SEGUIDOS=3
# LA COTA DE LA ESPERA DEL PRIMER ACK, en cuartos de segundo. Doce son tres segundos,
# que caben en VENTANA_MAX de cinco dejando margen para los tres cortes en paralelo.
# No es el tiempo que tarda un ack: es lo que esta fase puede gastar sin invalidar la
# otra cota, y por eso la de aqui se derivo de aquella y no al reves.
EN_VUELO_ESPERA_MAX=12

# veredicto_en_vuelo: LA DECISION VIVE EN SU PROPIA FUNCION Y NO DENTRO DE LA FASE,
# y eso es una correccion del barrido de mutantes: dentro de `phase_cut_fierro` no
# habia forma de ejercitarla sin tres maquinas, asi que ponerla a verde por las
# bravas no tumbaba ninguna fila. Es la tercera vez en esta sesion que una fila
# prueba la PIEZA y no el CIRCUITO, y la salida es siempre la misma, sacar la
# decision a un sitio donde se la pueda llamar.
veredicto_en_vuelo() {
	# NO HAY `begin_check` AQUI, y haberlo puesto fue la QUINTA vez que esta casa
	# comete el mismo defecto, en la funcion escrita para acabar con el. `begin_check`
	# pone CHECK_FAILED a CERO, y esta funcion se llamaba desde DENTRO del bloque
	# abierto de P2.cut.fired: borraba todos sus FAIL acumulados, incluido el de un
	# nodo que no armo su testigo, el de uno que nunca dejo de contestar al ssh -o sea
	# que NO se corto- y el de la frontera ausente. P2.cut.fired podia registrar PASS
	# con sus propios FAIL impresos encima en el mismo log.
	#
	# Y ES EXACTAMENTE LO QUE ESTE FICHERO YA DOCUMENTA VEINTE LINEAS MAS ARRIBA, en
	# el comentario que cuenta como P2.cut.bytes abrio su propio begin_check y leyo
	# un corte seco donde no lo habia. Se cerro moviendo aquel detras del end_check y
	# se reabrio metiendo este por delante. Lo trajo un lector externo en su tercera
	# vuelta, y lo que lo escondia era, otra vez, que la fila del banco llama a esta
	# funcion SOLA, donde funciona: llamar a la pieza es justo lo que tapa que el
	# circuito esta roto.
	#
	# QUIEN ABRE Y CIERRA SU BLOQUE ES QUIEN LLAMA, y esta funcion se invoca DESPUES
	# de `end_check P2.cut.fired`.
	begin_check
	local acks_en_vuelo
	acks_en_vuelo="$(grep -c '^ack ' "${OUT_LOCAL}/en-vuelo.txt" 2>/dev/null || true)"
	[ -n "${acks_en_vuelo}" ] || acks_en_vuelo=0
	if [ "${acks_en_vuelo}" -gt 0 ]; then
		pass "P2.cut.envuelo: ${acks_en_vuelo} write(s) were acknowledged in flight and the power went while the writer was still going, so the ack half of the property was exercised"
		end_check P2.cut.envuelo
	else
		not_run P2.cut.envuelo "not one write was acknowledged in flight before the cut, so the ack half was never exercised: whatever the workload's acks did below is a fact about a thirty second journal timer and not about a barrier"
	fi
}

# pliega_en_vuelo_sin_ack: todo id que se ENVIO y no dejo su linea `confirmed` en el
# manifiesto entra como `uncertain`. Es idempotente y se puede llamar dos veces: la
# segunda no encuentra nada que plegar. La llama el escritor al cerrar y la trampa
# de salida, para que ni un aborto pueda dejar un id comprometido fuera del
# manifiesto, que es lo unico que verifylog llama fantasma.
pliega_en_vuelo_sin_ack() {
	local enviados="${OUT_LOCAL}/en-vuelo-enviados.txt"
	[ -f "${enviados}" ] || return 0
	local id vec
	while read -r id vec; do
		[ -n "${id}" ] || continue
		grep -q "^put ${id} ${vec} confirmed\$" "${MANIFEST}" 2>/dev/null && continue
		grep -q "^put ${id} ${vec} uncertain\$" "${MANIFEST}" 2>/dev/null && continue
		echo "put ${id} ${vec} uncertain" >> "${MANIFEST}"
	done < "${enviados}"
}

# escritor_en_vuelo: escribe SIN PARAR contra el host 1 hasta que la conexion
# muere, que es lo que el corte hace. Corre en ESTA maquina, que es donde vive el
# testigo, porque un testigo dentro del conjunto cortado no es un testigo.
#
# CADA OPERACION DEJA SU LINEA EN EL MANIFIESTO Y SOLO UNA, y cual de las dos
# depende de lo que el cliente contesto:
#
#   rc 0  -> `confirmed`. El ack llego, asi que su AUSENCIA del log es un
#            veredicto: eso es exactamente la propiedad.
#   rc !=0 -> `uncertain`. Se envio y no volvio respuesta, asi que pudo
#            comprometerse o no, y ninguna de las dos cosas es un defecto. Sin
#            esta linea, un id comprometido cuyo ack se perdio con la conexion
#            saldria FANTASMA y pondria roja la fidelidad por hacer justo lo que
#            se le pidio.
#
# NINGUN ID RECIBE LAS DOS LINEAS, y eso es a proposito: el comprobador marca
# AMBIGUO todo id que toque una operacion sin respuesta, y un id ambiguo no se
# compara por valor. Escribir las dos habria costado la comparacion de valor de
# todos los ids en vuelo, incluidos los que si volvieron con su ack.
#
# Y LA LINEA `uncertain` SE ESCRIBE DESPUES Y NO ANTES, que es lo contrario de lo
# que la prudencia sugiere y es lo correcto aqui: el bucle corre en esta maquina y
# sobrevive al corte, asi que siempre llega a anotar lo que paso. Anotarlo antes
# habria marcado ambiguos tambien a los que acabaron con ack.
# comprueba_rango_en_vuelo: que ningun vector del rango en vuelo coincida con uno
# de la carga ni con el vector cero. NO es un comentario: es la orden que lo mide,
# y se corre antes de escribir la primera operacion. Un rango elegido bien hoy deja
# de estarlo el dia que alguien mueva DIM, la cota o los ids de la carga, y ese dia
# el sintoma seria un rojo de propiedad que nombra la causa equivocada.
comprueba_rango_en_vuelo() {
	local id v choques=0 cero=0
	local -a carga=()
	local c
	for c in $(seq 1 30); do carga+=("$(vec_for "${c}")"); done
	id="${ID_EN_VUELO_DESDE}"
	while [ "${id}" -lt $(( ID_EN_VUELO_DESDE + EN_VUELO_MAX )) ]; do
		v="$(vec_for "${id}")"
		case "${v}" in
			*[1-9]*) ;;
			*) cero=$(( cero + 1 )) ;;
		esac
		for c in "${carga[@]}"; do
			[ "${v}" = "${c}" ] && choques=$(( choques + 1 ))
		done
		id=$(( id + 1 ))
	done
	printf '%s %s' "${choques}" "${cero}"
}

escritor_en_vuelo() {
	local id="${ID_EN_VUELO_DESDE}" tope=$(( ID_EN_VUELO_DESDE + EN_VUELO_MAX ))
	local out vec seguidos=0 choques
	# LA GUARDA DEL RANGO SE CORRE ANTES DE ESCRIBIR NADA, y se niega en voz alta.
	choques="$(comprueba_rango_en_vuelo)"
	if [ "${choques}" != "0 0" ]; then
		echo "gate: refusing to write in flight: the id range ${ID_EN_VUELO_DESDE}..$(( ID_EN_VUELO_DESDE + EN_VUELO_MAX - 1 )) gives [${choques}] collisions and zero vectors against the workload's, and a search by vector would then answer with the wrong id" >&2
		: > "${OUT_LOCAL}/en-vuelo.txt"
		return 0
	fi
	: > "${OUT_LOCAL}/en-vuelo.txt"
	# LO QUE SE ENVIA SE ANOTA ANTES DE ENVIARLO, en un fichero APARTE del manifiesto.
	# La ventana la trajo un lector: entre que el cliente vuelve y que se anota su
	# linea hay un instante, y una muerte ahi -un Ctrl-C, que va al grupo de procesos
	# entero- deja un id COMPROMETIDO y AUSENTE del manifiesto, que es lo que
	# verifylog llama fantasma. Antes de este brazo un aborto no podia contaminar el
	# oraculo; con el si podia. Se anota la INTENCION antes, y lo que no vuelva con
	# ack se pliega al manifiesto como `uncertain` al cerrar, aqui o en la trampa.
	: > "${OUT_LOCAL}/en-vuelo-enviados.txt"
	while [ "${id}" -lt "${tope}" ]; do
		vec="$(vec_for "${id}")"
		printf '%s %s\n' "${id}" "${vec}" >> "${OUT_LOCAL}/en-vuelo-enviados.txt"
		out="$(client_op -op put -id "${id}" -vec "${vec}")"
		if committed "${out}"; then
			echo "put ${id} ${vec} confirmed" >> "${MANIFEST}"
			printf 'ack %s %s\n' "${id}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${OUT_LOCAL}/en-vuelo.txt"
			seguidos=0
		else
			printf 'sin-ack %s %s\n' "${id}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "${OUT_LOCAL}/en-vuelo.txt"
			seguidos=$(( seguidos + 1 ))
			[ "${seguidos}" -ge "${EN_VUELO_FALLOS_SEGUIDOS}" ] && break
		fi
		id=$(( id + 1 ))
	done
	pliega_en_vuelo_sin_ack
	# EL INSTANTE QUE SE ARCHIVA, y es la frontera entera de este brazo: el ultimo
	# ack recibido ANTES del corte. Todo lo que este por encima de esa linea tiene
	# que sobrevivir; lo que este por debajo no dice nada. Va al artefacto y no solo
	# a la consola, porque es lo que se cita cuando la consola ya no esta.
	{
		echo "el manifiesto en vuelo se cierra con el ULTIMO ack recibido antes del corte"
		echo "ultimo ack:      $(grep '^ack ' "${OUT_LOCAL}/en-vuelo.txt" | tail -1)"
		echo "primer sin-ack:  $(grep '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt" | head -1)"
		echo "acks:            $(grep -c '^ack ' "${OUT_LOCAL}/en-vuelo.txt" || true)"
		echo "sin ack:         $(grep -c '^sin-ack ' "${OUT_LOCAL}/en-vuelo.txt" || true)"
	} > "${OUT_LOCAL}/en-vuelo-frontera.txt"
}

phase_cut_fierro() {
	local n antes despues rc t_arma t_corte ventana v id_antes id_despues linea_frontera
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
		# EN ESTA SALIDA EL ESCRITOR NO LLEGO A ARRANCAR, asi que su veredicto no es
		# `none` por no haber ackeado: es que la fase se fue antes de crearlo. Se dice
		# con esa razon y no con la otra, que describiria mal la causa.
		not_run P2.cut.envuelo "the phase left before the canaries were in place, so the in-flight writer never started and there was nothing to acknowledge"
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
	# EL ESCRITOR ARRANCA ANTES DE ARMAR, y las tres armas van EN PARALELO. Las dos
	# cosas son la misma cuenta y la trajo la cuarta vuelta del lector: la ventana
	# medida va de `t_arma` al corte y su cota es VENTANA_MAX, cinco segundos. Contra
	# esa cota, la tercera vuelta metio DOS gastos nuevos dentro de la ventana sin
	# tocar la cota: el fsync de directorio en la siembra del testigo, y la espera de
	# hasta EN_VUELO_ESPERA_MAX cuartos de segundo -tres segundos- a que el escritor
	# en vuelo devolviera su primer ack. Con las tres armas EN SERIE, tres sesiones
	# ssh nuevas contra Azure, mas tres segundos de espera, el presupuesto se pasaba
	# de cinco antes de que el corte se disparara. Y pasarse no falla ruidosamente:
	# `ventana_dentro` da falso y P2.cut.bytes sale NOT RUN, o sea que la lectura
	# central de esta fase -si el corte fue seco- se anula sobre una flota sana.
	#
	# LA CUENTA DESPUES: el escritor arranca fuera de la ventana y para cuando las
	# armas vuelven ya tiene ack, con lo que el bucle de espera sale en su primera
	# vuelta y cuesta cero. Las armas pasan de tres viajes ssh en serie a uno en
	# paralelo. Queda un viaje de armar mas el abanico del corte, que ya iba en
	# paralelo desde antes. Es la misma correccion que se le hizo a los cortes el
	# 7 de septiembre y que a las armas no se le hizo entonces.
	#
	# Y EL RELOJ SE SELLA ANTES DE LAS ARMAS Y NO DESPUES, que es lo conservador: la
	# semilla mas vieja es la que mas tiempo lleva expuesta a que el escritor de
	# fondo la baje al plato por su cuenta, y la cota tiene que cubrir a esa.
	note "starting the in-flight writer against host 1; the manifest closes at the last ack received before the cut"
	escritor_en_vuelo &
	PID_EN_VUELO=$!

	t_arma="$(ahora)"
	declare -a TESTIGO_ARMADO=()
	local armados=0 pids_arma="" rc_arma
	for n in "${NODE_IDS[@]}"; do
		# EL `if` VA DENTRO DE LA SUBCAPA Y NO ES ESTILO: es la exencion de errexit,
		# y la primera version de este arreglo la perdio. El bucle de antes decia
		# `if testigo_arma "$n"; then`, y una llamada dentro de la condicion de un
		# `if` esta EXENTA de `set -e`. Al paralelizar se escribio
		# `( testigo_arma "$n"; echo $? > ... ) &`, donde la llamada ya no esta en
		# ninguna condicion: con un arma que falla, errexit mata la subcapa ANTES del
		# `echo`, el fichero de rc no se escribe nunca, `wait` devuelve distinto de
		# cero y errexit se lleva el gate entero. O sea que el arreglo cambiaba
		# "se anota que el nodo 2 no armo y se sigue" por "la corrida de fierro muere
		# sin decir por que", que es peor que el defecto que venia a arreglar. Se midio
		# con un guion de cuatro lineas antes de dejarlo puesto, y la fila 17id lo
		# ejercita con un arma que falla de verdad.
		# AND THE REDIRECT GOES ON THE ECHO AND NOT ON THE COMPOUND, which was the second
		# defect this line carried and was measured before it was fixed, with row 17if:
		# a redirect written after the `fi` covers the whole compound, so the condition
		# is inside it and whatever testigo_arma prints on stdout lands in the status
		# file. The reader compares the whole file against 0, so one line of noise in
		# front of the digit reads as "this node did not arm", and the phase reddens
		# over a healthy fleet with P2.cut.bytes NOT RUN. The payload is silent today
		# -ask_on captures run_on and prints nothing- so the failure was latent, and a
		# status channel that the payload can dirty is not a status channel. Redirecting
		# each echo keeps the channel at one line per node and sends what the payload
		# prints to the log, which is where a reader wants it.
		( if testigo_arma "$n"; then echo 0 > "${OUT_LOCAL}/arma-rc-${n}"; else echo 1 > "${OUT_LOCAL}/arma-rc-${n}"; fi ) &
		pids_arma="${pids_arma} $!"
	done
	wait ${pids_arma}
	for n in "${NODE_IDS[@]}"; do
		rc_arma="$(cat "${OUT_LOCAL}/arma-rc-${n}" 2>/dev/null || echo 1)"
		if [ "${rc_arma}" = 0 ]; then
			TESTIGO_ARMADO[$n]=1
			armados=$((armados + 1))
		else
			TESTIGO_ARMADO[$n]=0
			fail "P2.cut.fired: node ${n} would not arm its canary, so nothing it says about the cut is evidence"
		fi
	done
	if [ "${armados}" -eq 0 ]; then
		# EL ESCRITOR YA ESTA VIVO EN ESTE CAMINO, que antes no lo estaba: se para y
		# lo que dejo enviado se pliega, porque un id enviado y ausente del manifiesto
		# es lo que verifylog llama fantasma y contamina el oraculo de la corrida
		# entera. Salir por aqui sin plegar seria dejar el brazo nuevo envenenando el
		# camino que existe para abortar limpio.
		kill "${PID_EN_VUELO}" 2>/dev/null || true
		wait "${PID_EN_VUELO}" 2>/dev/null || true
		pliega_en_vuelo_sin_ack
		PID_EN_VUELO=""
		end_check P2.cut.fired
		not_run P2.cut.envuelo "no canary was armed, so the phase returns without cutting; the in-flight writer was stopped and what it had sent was folded into the manifest as uncertain, and with no cut there is no ack half to judge"
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
	# EL ESCRITOR EN VUELO ARRANCA AQUI, justo antes del corte y despues de armar los
	# testigos, y esa posicion es la decision entera. La propiedad es "ack implica
	# durable", y sin escrituras en vuelo la mitad del ack no se ejercita nunca: el
	# mutante solo pierde algo si el corte cae ENTRE el ack y la barrera. Con la
	# carga cerrada antes del corte esa ventana no existe.
	#
	# CORRE EN SEGUNDO PLANO Y EN ESTA MAQUINA. En segundo plano porque el corte
	# tiene que caer MIENTRAS escribe, no despues; y en esta maquina porque es donde
	# vive el testigo, y un testigo dentro del conjunto cortado no es un testigo.
	# Se para solo, por su cota y por sus fallos seguidos, que es como se entera de
	# que la conexion murio.
	# EL ESCRITOR ARRANCA Y SE LE ESPERA SU PRIMER ACK ANTES DE CORTAR, con cota. La
	# version anterior lo arrancaba y cortaba en el mismo instante, y un lector midio
	# que el caso ESPERADO era cero acks: el corte es UN viaje ssh, y el primer ack
	# necesita ssh mas arranque de binario mas handshake TLS mutuo, que la seccion
	# 10.7 cifra en segundos, y no en decimas, en localhost SIN ssh. Las tres morian antes de que el
	# primero volviera, `P2.cut.envuelo` salia `none`, y como esta en la lista de
	# fierro la corrida entera cerraba NOT A SUCCESS por una causa que es el
	# instrumento y no la propiedad.
	#
	# LA COTA ES CORTA A PROPOSITO, y lo que decide su valor es la otra cota: la
	# ventana entre armar el testigo y cortar tiene que caber en VENTANA_MAX. Esperar
	# aqui GASTA esa ventana, asi que se espera lo justo para tener UNA escritura
	# ackeada con edad casi cero, que es toda la poblacion que este brazo necesita.
	# Si no llega ni una, se corta igual y el veredicto lo dice: no cortar seria
	# perder la sesion por no poder medir la mitad del ack.
	#
	# Y EL ARRANQUE YA NO ESTA AQUI, sino ARRIBA, antes de armar. Estuvo aqui hasta
	# la cuarta vuelta, y ahi esta espera caia ENTERA dentro de la ventana en vez de
	# solaparse con las armas. Lo que queda aqui es la espera, que ahora sale en su
	# primera vuelta porque el primer ack suele haber vuelto ya mientras se armaba.
	local espera_ack=0
	while [ "${espera_ack}" -lt "${EN_VUELO_ESPERA_MAX}" ]; do
		grep -q '^ack ' "${OUT_LOCAL}/en-vuelo.txt" 2>/dev/null && break
		kill -0 "${PID_EN_VUELO}" 2>/dev/null || break
		sleep 0.25
		espera_ack=$(( espera_ack + 1 ))
	done
	if grep -q '^ack ' "${OUT_LOCAL}/en-vuelo.txt" 2>/dev/null; then
		note "the in-flight writer has at least one acknowledged write; cutting now, so its age at the cut is as close to zero as this gate can put it"
	else
		note "the in-flight writer has NOT acknowledged anything within $(( EN_VUELO_ESPERA_MAX / 4 )) s; cutting anyway, and P2.cut.envuelo will say the ack half was not exercised"
	fi
	note "cutting the THREE with echo b > /proc/sysrq-trigger, fired in parallel"
	local pids_corte=""
	for n in "${NODE_IDS[@]}"; do
		corta_en "$n" &
		pids_corte="${pids_corte} $!"
	done
	# SE ESPERA A LOS CORTES Y NO A TODO, y esta linea era un `wait` desnudo hasta
	# que el escritor en vuelo entro detras. Un `wait` sin argumentos espera a TODOS
	# los trabajos de fondo, o sea que habria esperado tambien a que el escritor se
	# rindiera, unos treinta segundos despues, y `t_corte` se habria tomado ahi. La
	# ventana entre armar el testigo y cortar es la COTA que decide si el resultado
	# de la barrera significa algo: falsearla por treinta segundos, contra una cota
	# de cinco, habria puesto `ventana_dentro` en falso y con ella los veredictos en
	# `none` sin que nada dijera por que.
	# shellcheck disable=SC2086
	wait ${pids_corte}
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
	# Y AHORA SI SE RECOGE EL ESCRITOR EN VUELO, que para entonces ya se ha rendido
	# solo: sus tres fallos seguidos llegan en cuanto las tres dejan de contestar. Se
	# espera aqui, con la ventana ya medida, para leer su frontera antes de decidir
	# nada sobre lo que sobrevivio.
	wait "${PID_EN_VUELO}" 2>/dev/null || true
	PID_EN_VUELO=""
	pliega_en_vuelo_sin_ack
	if [ -s "${OUT_LOCAL}/en-vuelo-frontera.txt" ]; then
		while IFS= read -r linea_frontera; do
			note "en vuelo: ${linea_frontera}"
		done < "${OUT_LOCAL}/en-vuelo-frontera.txt"
	else
		fail "P2.cut.fired: the in-flight writer left no boundary file, so this run cannot say which acks it had received when the power went"
	fi

	# P2.cut.envuelo: EL VEREDICTO QUE FALTABA, y sin el todo este brazo era un
	# instrumento sin lectura. Lo trajo un lector externo en su segunda vuelta y su
	# pregunta era exacta: que pasa si el escritor en vuelo no consigue ackear NADA.
	# La respuesta era NADA: la unica guarda miraba que el fichero de frontera
	# EXISTIERA, y ese fichero se escribe siempre, tambien con `acks: 0`.
	#
	# POR QUE IMPORTA, y es toda la razon de este brazo. La propiedad es "ack implica
	# durable", y la mitad del ack solo se ejercita si el corte cae ENTRE un ack y su
	# barrera. Con cero acks en vuelo, la corrida mide lo mismo que media antes del
	# arreglo: si lo ackeado por la carga sobrevivio, y eso puede ser cierto por el
	# temporizador del diario, que en esta flota vuelca solo a los treinta segundos.
	# Cero acks en vuelo NO es un fallo del motor, asi que no es un rojo: es que la
	# corrida no llego a hacer la pregunta, y eso se dice con `none`.
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

	# EL VEREDICTO EN VUELO VA DETRAS DEL end_check DE ESTA FASE, nunca dentro: abre
	# su propio bloque con su propio begin_check, y compartirlo era borrar los FAIL
	# de P2.cut.fired.
	veredicto_en_vuelo

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
# EL ESTADO DE LA LINEA DECIDE, y hasta el 9 de septiembre de 2026 este bucle no lo
# miraba. Lo trajo un lector externo en su segunda vuelta y era BLOQUEANTE: el
# escritor en vuelo anota `uncertain` los envios que no volvieron con ack, y esas
# lineas entraban aqui como si fueran ackeadas. `P2.recover.acked` las exigia
# presentes, no podian estarlo porque se enviaron contra tres maquinas ya muertas,
# y la corrida salia ROJA diciendo que el motor perdio una escritura ackeada. Bajo
# la seccion 10.12 eso es un rojo de PROPIEDAD y no se re-corre NUNCA: la unica
# corrida autorizada se habria quemado publicando la conclusion invertida.
#
# Y ES EXACTAMENTE LA CLASE QUE EL ARREGLO ANTERIOR CERRO POR OTRA PUERTA. El
# manifiesto tiene DOS consumidores y solo uno sabia de los estados: verifylog.go
# separa `confirmed` de `ambiguous` desde que se escribio; este python no.
#
# UNA LINEA SIN MARCADOR ES CONFIRMED, que es lo que deja parsear un manifiesto
# anterior a los estados sin cambiarlo, y es la misma regla que verifylog.go aplica.
CONFIRMADO, INCIERTO = 'confirmed', 'uncertain'
vivos = []
for renglon in open(sys.argv[1], encoding='utf-8'):
    p = renglon.split()
    if not p:
        continue
    estado = CONFIRMADO
    if p[-1] in (CONFIRMADO, INCIERTO):
        estado, p = p[-1], p[:-1]
    if not p:
        continue
    if estado == INCIERTO:
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
		"${BIN}" verify-log -id "${n}" -peers "$(peers_of "$n")" -dir "${copia}" -manifest "${MANIFEST}" -dim "${DIM}" -durable \
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
		pass "P2.recover.faithful: ${fieles} of ${#NODE_IDS[@]} cold copies verify faithful against a manifest of $(grep -vc ' uncertain$' "${MANIFEST}") acknowledged operations plus $(grep -c ' uncertain$' "${MANIFEST}" || true) sent without an answer, and a majority is ${mayoria}"
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
# never calls, so it finds nothing to complain about by construction and the
# verdict published "no node left running and the fleet directory is gone" about a
# local directory that never held anything. Meanwhile the three hosts kept naylamp/bin/naylampd-mutante,
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
	# EL rc SE CAPTURA DENTRO DE LA SUSTITUCION Y NO CON UN `$?` DETRAS, y esta linea
	# es una correccion del 8 de septiembre de 2026 que se lleva por delante toda la
	# fase. `ask_on` tiene TRES salidas, 0 si, 1 no, 2 ilegible, y aqui la respuesta
	# NORMAL es 1: el paso de arriba acaba de matar esos daemons, asi que ninguno
	# esta vivo. Escrita como orden desnuda seguida de `rc_a=$?`, ese 1 es un fallo
	# a los ojos de `set -e` y **mataba el guion en la primera vuelta del bucle**,
	# antes de asignar `rc_a` siquiera. Todo lo que hay debajo era codigo muerto en
	# fierro: los pasos 2, 3 y 4, el barrido del sello, la linea de PASS y el propio
	# `end_check`, con lo que P2.hygiene salia `none` y la corrida cerraba diciendo
	# que aborto. Reproducido en el bash 3.2 de esta maquina con una funcion que
	# devuelve 1: el bucle muere en la vuelta uno sin imprimir nada.
	#
	# LA FORMA ES LA QUE ESTE MISMO FICHERO YA USA BIEN mas arriba, en el censo de
	# hosts vivos: la sustitucion corre en un subshell y lo que se lee es lo que
	# `echo $?` imprime, no el estado de la orden. De los ocho `ask_on` de este
	# guion, seis estaban ya en forma segura (dentro de un `if`, con `|| true`, o
	# como ultima orden de su funcion) y este era el unico desnudo.
	for n in "${NODE_IDS[@]}"; do
		rc_a="$(ask_on "$n" 'pid=$(cat naylamp/naylampd-mutante.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'; echo $?)"
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
	# 5. AND THE SEAL, which is the half of this claim that faces THIS machine.
	#    Points 1 to 3 say the three hosts carry nothing this run put there; without
	#    this one, nothing says that what the run produced HERE survives the next
	#    make clean. The order inside is the whole point and it is written in the
	#    function: seal first, then sweep, so the sweep includes the artifact this
	#    very run just wrote and a run that fails to seal itself reddens here.
	veredicto_del_sello
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.hygiene: the three hosts carry nothing this run put there, no mutant daemon is alive, the sane fleet is back up on ${levantados} of ${#NODE_IDS[@]}, and this run's artifact carries its seal"
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
	local pids_corte_rojo=""
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
		# EL CLIENTE DEL MUTANTE CORRE EN EL HOST 1 Y NO EN ESTE PORTATIL, y hasta
		# 2026-09-09 corria aqui. Es EXACTAMENTE el defecto que la seccion 10.16 del
		# diseno declara cerrado para `client_op`, y a `client_op` si se le aplico:
		# va por `run_on 1`. A este no. Lo trajo un lector externo del diseno.
		#
		# LO QUE COSTABA, y es todo el brazo rojo. `"${BIN}"` es el binario DARWIN;
		# `${PRIV[1]}` es una direccion privada de la flota que esta maquina no
		# tiene, asi que el `-listen` no puede atarse; y los certificados que
		# nombraba son los locales y no los del host. Los cuarenta intentos fallaban
		# los cuarenta, `P2.red.barrier` salia roja diciendo que la flota mutante
		# nunca ackeo, y `P2.red.fires` quedaba NOT RUN. Y eso ocurre DESPUES de
		# haber parado la flota sana y despues de los dos cortes: la sesion se
		# cerraba con los verdes del brazo positivo y sin ningun control que los
		# sostuviera. Sumado a que el brazo positivo no podia ponerse rojo, la
		# corrida entera no tenia un solo camino por el que la propiedad fallara.
		out="$(run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=certs/node-${CLIENT_ID}.pem NAYLAMP_TLS_KEY=certs/node-${CLIENT_ID}-key.pem NAYLAMP_TLS_CA=certs/ca.pem ./bin/naylampd client -listen ${PRIV[1]}:${MUT_CLIENT_PORT_FIERRO} -group '${mgroup}' -dim ${DIM} -op put -id 7 -vec '$(vec_for 7)' ; echo __RC__=\$?" 2>&1)"
		# EL ESTADO ES LA ULTIMA LINEA Y TIENE QUE SER LA LINEA ENTERA, que es la
		# misma guarda que `client_op` lleva y por la misma razon: un canal de estado
		# que cualquier carga util puede falsificar no es un canal de estado.
		case "$(printf '%s' "${out}" | tail -1)" in
			__RC__=0) ok=1 ;;
		esac
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
		pids_corte_rojo="${pids_corte_rojo} $!"
	done
	# SE ESPERA A LOS CORTES Y NO A TODO, igual que en phase_cut_fierro y por la
	# misma razon. Aqui hoy no hay ningun trabajo de fondo pendiente, asi que el
	# `wait` desnudo no muerde; se cambia igual porque es la FORMA que el arreglo de
	# la otra fase acaba de declarar capaz de falsear una ventana en treinta segundos
	# contra una cota de cinco, y esta ventana gobierna P2.red.barrier, que es el
	# UNICO control de toda la sesion. Arreglar la instancia y dejar la clase es
	# justo lo que este registro persigue con nombre propio. Lo trajo un lector.
	# shellcheck disable=SC2086
	wait ${pids_corte_rojo}
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
		"${BIN}" verify-log -id "${n}" -peers "$(peers_of "$n")" -dir "${copia_m}" -manifest "${OUT_LOCAL}/manifest-mutante.txt" -dim "${DIM}" -durable \
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
	local n
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
		node_alive "$n" && fail "P2.hygiene: node ${n} is still running"
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
	fi
	# Y EL BARRIDO DE SELLOS TAMBIEN AQUI. En el ensayo seal_artifact devuelve en su
	# primera linea, asi que lo unico que corre es el barrido, y eso es deliberado:
	# el barrido es lo que convierte un artefacto de fierro sin sello en una linea
	# roja, y el ensayo es lo que mas veces pasa por delante de gate/out.
	veredicto_del_sello
	# EL VERDE CUELGA DE CHECK_FAILED, y hasta este cambio colgaba de un contador
	# propio, `left`, que solo subia en los sitios que cuentan nodos. Los dos decian
	# lo mismo mientras cada sitio que lo subia llamaba tambien a fail, que era el
	# caso; el barrido de sellos de arriba rompe esa igualdad, porque falla sin
	# tocar ningun nodo. Con la condicion vieja, una corrida con un artefacto de
	# fierro sin sello habria impreso su linea de PASS justo encima de su propio
	# veredicto rojo. El contador se ha ido entero en vez de quedarse asignado y sin
	# leer: fail ya lleva la cuenta que decide, y una segunda que nadie lee es la
	# clase de adorno que este fichero le quita a otros.
	[ "${CHECK_FAILED}" -eq 0 ] && pass "P2.hygiene: no node left running, the fleet directory is gone, and no p2 iron artifact is left unsealed"
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
	# `set +e` EN LA TRAMPA, y entra el 8 de septiembre de 2026 con el sello. No es
	# relajar la guardia: es que una trampa que se muere a mitad es peor que una que
	# sigue. Sin esta linea, `completa_el_sello` puede matar la salida: su
	# `esperada="$(grep -m1 '^expected:' ...)"` es una ASIGNACION cuya sustitucion
	# falla si el sello no lleva esa linea, y bajo `set -e` eso mata al shell DENTRO
	# de la trampa, o sea que se saltan `retira_running` y el bloque de veredictos y
	# la corrida se cierra sin decir nada. `cleanup` de gate/p1.sh lleva este `set +e`
	# desde su primera version y por esta misma razon; esta trampa no lo llevaba
	# porque hasta hoy ninguna de sus lineas podia fallar.
	#
	# LO QUE NO LO VIGILA, dicho: ninguna fila de banco. gate/p2-guard-test.sh corre
	# cada copia con `set -e` puesto y llegaria hasta aqui, pero el sello NO se
	# escribe en el ensayo, asi que la rama no se alcanza desde alli; y
	# gate/p2-iron-test.sh sourcea este fichero bajo su propio `set -uo pipefail`,
	# sin `-e`, o sea que reproduce la version indulgente. Va escrito en vez de
	# fingir que una fila lo cubre.
	set +e
	limpia_flota
	# EL SELLO DE RESPALDO, y es un respaldo y no el sitio al que el sello
	# pertenece. phase_hygiene_fierro sella primero, con la corrida viva, para que
	# la corrida pueda comprobar su propio sello y ponerse roja. Esto recoge las
	# corridas que nunca llegan a la higiene: todos los subcomandos menos all y red,
	# mas cualquier aborto. Sellar tambien aqui es por lo que una corrida que muere a
	# mitad de fase conserva lo que alcanzo a escribir.
	#
	# Y VA DESPUES DE limpia_flota A PROPOSITO, con la razon corregida por un lector:
	# esa funcion COPIA los logs de los nodos dentro del artefacto, no los mueve, y
	# lo que la ordena antes no es el valor de esos logos como cita. Es la prueba del
	# VACIO: seal_artifact se niega a sellar un artefacto cuyo unico fichero sea el
	# marcador, asi que una corrida que murio antes de escribir nada propio solo
	# tiene algo que sellar DESPUES de que los logs esten dentro. En los caminos
	# `all` y `red` esto no decide nada, porque el sello ya lo escribio
	# phase_hygiene_fierro; decide en los que nunca llegan a la higiene, que son
	# justo los que este respaldo existe para recoger.
	#
	# EL MARCADOR SE RETIRA AL FINAL Y NO AL PRINCIPIO, que es la forma de p1.sh y
	# su razon es la ventana: entre la retirada y el sello el artefacto no lleva
	# ninguna de las dos guardas, ni marcador vivo ni sello, y un barrido que caiga
	# ahi se lo lleva. Hoy esa ventana son tres llamadas; el dia que al_salir crezca,
	# y en fierro crecera, deja de ser gratis.
	# LO ENVIADO EN VUELO SE PLIEGA ANTES DE SELLAR, porque el manifiesto viaja
	# dentro del artefacto: un id que se envio, se comprometio y no dejo linea seria
	# un fantasma para siempre en la evidencia que se cita.
	# EL ESCRITOR EN VUELO SE MATA ANTES DE PLEGAR Y DE SELLAR, y hasta hoy nadie lo
	# mataba: `limpia_flota` solo conoce los pids de pids.txt, que escribe la rama del
	# ensayo. Un aborto entre su arranque y su recogida dejaba un proceso anadiendo
	# lineas al manifiesto DESPUES de que el sello se hubiera escrito con su linea de
	# veredictos, y podia darle a un mismo id las dos lineas a la vez. Es el caro "sin
	# via de aborto que deje un estado conocido" ascendido por este mismo brazo: antes
	# de el, un aborto no dejaba ningun proceso de fondo vivo.
	if [ -n "${PID_EN_VUELO:-}" ]; then
		kill "${PID_EN_VUELO}" 2>/dev/null || true
		wait "${PID_EN_VUELO}" 2>/dev/null || true
	fi
	pliega_en_vuelo_sin_ack 2>/dev/null || true
	seal_artifact
	completa_el_sello
	retira_running
	# Y EL TECHO DE LOS ENSAYOS, AL FINAL DEL TODO Y NO ANTES. Va detras del sello y
	# de la retirada del marcador por dos razones que se separan: el sello es lo que
	# decide si el artefacto de ESTA corrida se queda, y barrer antes de sellar seria
	# barrer con la pregunta a medio contestar; y el marcador es lo que dice a un
	# `make clean` concurrente que aqui hay una corrida viva, asi que se retira
	# cuando ya no queda nada que proteger. En fierro esta llamada devuelve en su
	# primera linea.
	local retirados_ensayo
	retirados_ensayo="$(barre_ensayos_viejos)"
	if [ "${retirados_ensayo:-0}" -ne 0 ]; then
		note "rehearsal artifacts retired by the ceiling: ${retirados_ensayo}; the ceiling is ${CONSERVA_ENSAYOS} plus this run's own"
	fi
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
	# LAS DOS COSAS QUE EL SELLO CITA DE LA INVOCACION, y se guardan JUNTO a
	# RUN_STARTED y no antes: un sello solo se escribe cuando la corrida empezo, asi
	# que estos dos datos no pueden existir en una invocacion que no llego a
	# empezar. La hora es la del arranque en UTC y no `ahora`, que devuelve
	# segundos epoch con tres decimales para restar tiempos y no para leerse.
	SUBCOMANDO="${sub}"
	ARRANCO_A="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	RUN_STARTED=1
	case "${sub}" in
		all)
			# The iron run expects THREE more verdicts than the rehearsal, and
			# they are exactly the three the rehearsal declares NOT RUN because
			# loopback cannot stand in for a power cut: the sysrq permission, the
			# canary that measures the cut, and the mutant's own loss reading.
			if [ "${ES_FIERRO}" -eq 1 ]; then
				EXPECTED="P2.build P2.pre.fleet P2.pre.identity P2.pre.sysrq P2.provenance P2.workload.acked P2.cut.fired P2.cut.bytes P2.cut.envuelo P2.recover.boots P2.recover.elects P2.recover.acked P2.recover.faithful P2.recover.idem P2.red.mutation P2.red.bites P2.red.daemon P2.red.barrier P2.red.fires P2.hygiene"
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
