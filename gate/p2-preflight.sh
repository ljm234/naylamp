#!/usr/bin/env bash
# p2-preflight.sh: the list that runs BEFORE the Phase 2 iron session, so that
# nobody reads prose with three VMs billing.
#
# It is PART of section 10.11 of the Phase 2 gate proposal turned into an order,
# and the word is part and not all, because an earlier version of this line said
# all and a reader counted. Of that section's five points this script covers the
# TLS material, the sysrq bit and the eight ports; the mutant binary rides inside
# the rehearsal of step 5 with no check of its own. The proposal lives in the
# workspace and never in this repository; where the two disagree the proposal is
# the one that argues and this one is the one that answers.
#
# AND POINT 5, THE FLEET, IS NOW COVERED IN PART, WHICH THESE LINES DENIED UNTIL
# 2026-09-07. They said it was not covered at all, naming the region and
# deallocate among the things left out, and that same day the script gained a
# written REGION used in every create and a `cierre` subcommand that deallocates
# the three and reads that they came back deallocated. A reader measured the
# contradiction. What is still NOT covered: the SKU, the static addresses, and
# powering on one at a time.
#
# THREE SUBCOMMANDS, AND THE SPLIT IS THE WHOLE POINT. `cold` runs with the fleet
# POWERED OFF; `hot` needs the three machines up and takes the three OS disk
# snapshots the iron session may not run without; `cierre` shuts the three down,
# retires those snapshots and counts that zero remain. Everything that can be
# answered before spending is answered before spending, so a run that was going
# to die on a precondition dies on this laptop instead of on the fleet. `cold`
# refuses to report ready if anything fails, and the session does not power
# anything on until it does.
#
# WHY IT EXISTS AT ALL, measured on 2026-09-06: gate/out/certs had been expired
# since 2026-08-11 and nobody had noticed, because gate/p1.sh does not use TLS and
# never looks. The Phase 2 gate does, and that would have surfaced with the fleet
# already up. That check is item 1 here and it is first for that reason.
#
# WHAT IT DOES AND DOES NOT DO, and the first version of these two lines said "it
# reads", which is false. `cold` RUNS the rehearsal, so it builds binaries, starts
# eight replicas on loopback, writes their data and kills them. What it does not do
# is power on a VM or deploy anything, and `cold` writes nothing to Azure at all;
# `hot` and `cierre` DO write to Azure, creating and deleting snapshots and
# deallocating machines, and that is said here because the two halves used to be
# described as if neither touched anything. And it writes in three places, not one:
# under gate/out, under the system temp directory (the mutant tree the rehearsal's
# red phase copies, and one snapshot file), and in Go's build cache. The temporary
# ones clean themselves up; saying they do not exist would be another matter.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# THE LIFETIME MARGIN DEMANDED OF THE TLS MATERIAL LIVES IN ONE PLACE, and not for
# looks: if this script and the other two that read the same thing carried
# different numbers there would be a DEAD WINDOW, a stretch in which the
# preflight refuses to start and the documented remedy, re-minting, leaves the
# certificates exactly as they were. A file missing here is a failure and not a
# default value: with no margin there is no check to make, and assuming one would
# be inventing it.
if [ ! -r "${GATE_DIR}/cert-margen.sh" ]; then
	echo "gate: ${GATE_DIR}/cert-margen.sh is missing, and the TLS material margin lives there" >&2
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
CERT_DIR="${OUT_DIR}/certs"

NODE_IDS=(1 2 3)
CLIENT_ID=90
# The eight loopback ports the rehearsal binds, four for the sane fleet and four
# for the mutant one. They are the same eight literals as gate/p2.sh:1048 and
# :1064; if this list and that one drift apart, the preflight stops measuring what
# the rehearsal actually binds.
PUERTOS=(19401 19402 19403 19490 19411 19412 19413 19500)

# THE FLEET, with the region WRITTEN and not inherited. The group `naylamp-gate` lives in
# westus2 and all of its content in centralus, measured with `az group show` on
# 2026-09-07, so an `az ... create` that does not pass -l inherits the group's and
# comes out with RequestDisallowedByAzure by subscription policy. In the single-VM
# test that cost the first snapshot attempt and was free; on iron it would cost
# with all three billing. That is why the region is here and in every create.
GRUPO=NAYLAMP-GATE
REGION=centralus
VMS=(naylamp-1 naylamp-2 naylamp-3)
SNAP_SUFIJO=osdisk-antes-del-gate-p2
# The FAMILY is wider than this session's suffix on purpose: the single-VM arm of
# 2026-09-07 left `naylamp-1-osdisk-antes-de-sysrq`, with another suffix, and a
# label that says "zero gate snapshots" has to count it. The previous version
# counted only `ends_with(SNAP_SUFIJO)` and promised more than it
# measured.
SNAP_FAMILIA=osdisk-antes-de

FALLOS=0
PASOS_MAL=0
declare -a PASOS_NOMBRE=()
declare -a PASOS_FALLA=()

paso() {
	PASOS_NOMBRE+=("$*")
	PASOS_FALLA+=(0)
	printf '\n[%d] %s\n' "${#PASOS_NOMBRE[@]}" "$*"
}
ok()   { printf '    OK    %s\n' "$*"; }
mal()  {
	FALLOS=$((FALLOS + 1))
	local i=$(( ${#PASOS_NOMBRE[@]} - 1 ))
	if [ "${i}" -ge 0 ] && [ "${PASOS_FALLA[$i]}" -eq 0 ]; then
		PASOS_FALLA[$i]=1
		PASOS_MAL=$((PASOS_MAL + 1))
	fi
	printf '    FALLA %s\n' "$*"
}
dato() { printf '          %s\n' "$*"; }

# `az` is not on the PATH of every session on this machine and the session may have
# expired. The two things are told apart from "there are no snapshots", the same way
# the `lsof` step tells "nobody is listening" apart from "it could not be asked".
# EVERY `az` read goes with `|| true` and is judged by its CONTENT, never by its
# direct exit status. Under `set -euo pipefail`, an assignment by command
# substitution inherits the rc of `az`, and a token expiring midway, a throttling 429
# or a transient `ResourceNotFound` kill the whole script WITHOUT printing anything.
# In `cierre` that death falls AFTER the `deallocate` and BEFORE retiring the
# snapshots, so it leaves three snapshots billing and not one line to say so. Measured
# on 2026-09-07: `az vm show` over a VM that does not exist returns rc=3 and the next
# line never runs. The `ssh` reads of this same script already carried it; the
# `az` ones did not, and that was an oversight and not a decision.
az_lee() { "${AZ}" "$@" 2>/dev/null || true; }

AZ=""
hay_az() {
	if [ -n "${AZ}" ]; then return 0; fi
	if command -v az >/dev/null 2>&1; then AZ="$(command -v az)"
	elif [ -x /opt/homebrew/bin/az ]; then AZ=/opt/homebrew/bin/az
	else return 1; fi
	"${AZ}" account show >/dev/null 2>&1 || { AZ=""; return 1; }
	return 0
}
nombre_snap() { printf '%s-%s' "$1" "${SNAP_SUFIJO}"; }

# ---- the COLD half: the fleet powered off, zero cost -------------------------

frio() {
	echo "PHASE 2 IRON SESSION PREFLIGHT, COLD half"
	echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "machine: $(sysctl -n hw.model 2>/dev/null || uname -m), $(uname -sr)"
	echo "tree: ${REPO_DIR}"
	echo "Nothing that follows powers on a VM or costs a cent."

	paso "The tree: clean, signed and with its CI green"
	local sucio head firma
	sucio="$(cd "${REPO_DIR}" && git status --porcelain | wc -l | tr -d ' ')"
	head="$(cd "${REPO_DIR}" && git rev-parse HEAD)"
	firma="$(cd "${REPO_DIR}" && git log -1 --format='%G?')"
	dato "HEAD ${head}"
	if [ "${sucio}" -eq 0 ]; then
		ok "tree clean"
	else
		local plural=s; [ "${sucio}" -eq 1 ] && plural=""
		mal "the tree carries ${sucio} uncommitted path${plural}; the run would be anchored to a tree that exists nowhere"
		( cd "${REPO_DIR}" && git status --porcelain | sed 's/^/          /' )
		dato "they are signed or retired before powering on; this script does not do it"
	fi
	[ "${firma}" = G ] && ok "the signature on HEAD verifies" || mal "git log -1 --format='%G?' returns [${firma}] and not G"
	# CI green is asked for if gh is there and there is network; if not, it is said that it
	# was not checked, instead of hiding it. A step that cannot run is not a green step.
	if command -v gh >/dev/null 2>&1 || [ -x /opt/homebrew/bin/gh ]; then
		local GH concl
		GH="$(command -v gh || echo /opt/homebrew/bin/gh)"
		concl="$("${GH}" run list --limit 20 --json headSha,conclusion 2>/dev/null \
			| /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print(next((r['conclusion'] for r in d if r['headSha']=='${head}'),'no run'))" 2>/dev/null || echo 'could not be asked')"
		[ "${concl}" = success ] && ok "CI green for this HEAD" || mal "CI for this HEAD says [${concl}]"
	else
		dato "gh is not on this machine: CI green was NOT checked, and that is not green"
	fi

	paso "The TLS material, which is the point nobody looks at until the fleet is up"
	dato "it lasts 24 h from the moment it is minted, engine/cluster/tlstest/tlstest.go:55 and :90"
	local id falta=0
	for id in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		[ -f "${CERT_DIR}/node-${id}.pem" ] || { mal "there is no certificate for id ${id}"; falta=1; continue; }
		[ -f "${CERT_DIR}/node-${id}-key.pem" ] || { mal "there is no private key for id ${id}"; falta=1; continue; }
		if ! openssl x509 -in "${CERT_DIR}/node-${id}.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1; then
			mal "the certificate for id ${id} is expired or has fewer than $((CERT_MARGEN_SEG/3600)) hours left"; falta=1
		fi
	done
	if [ -f "${CERT_DIR}/ca.pem" ]; then
		dato "CA valid until $(openssl x509 -in "${CERT_DIR}/ca.pem" -noout -enddate | cut -d= -f2)"
		openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1 \
			|| { mal "the CA is expired or has fewer than $((CERT_MARGEN_SEG/3600)) hours left"; falta=1; }
	else
		mal "there is no CA"; falta=1
	fi
	if [ "${falta}" -eq 1 ]; then
		dato "it is fixed with:  cd ${REPO_DIR} && ./gate/build.sh"
		dato "and this step is re-run; build.sh re-mints the whole set"
	else
		ok "TLS material complete and not expiring in the next $((CERT_MARGEN_SEG/3600)) hours"
	fi

	paso "The EIGHT loopback ports the rehearsal binds"
	# "nobody is listening" IS TOLD APART FROM "it could not be asked", and the first
	# version did not: `lsof` returns 1 with the port free and also fails with 127
	# if it is not installed, and the `if` was false in both cases, so without
	# `lsof` this check said "the eight are free" without having looked. It is the
	# same distinction the CI step three steps above makes.
	if ! command -v lsof >/dev/null 2>&1; then
		mal "lsof is not on this machine, so the ports were NOT checked, and that is not green"
	else
		local p ocupados=0 quien
		for p in "${PUERTOS[@]}"; do
			quien="$(lsof -nP -iTCP:"${p}" -sTCP:LISTEN -Fcp 2>/dev/null | tr '\n' ' ' || true)"
			if [ -n "${quien}" ]; then
				mal "port ${p} is already listening: ${quien}"; ocupados=1
			fi
		done
		[ "${ocupados}" -eq 0 ] && ok "the eight are free"
	fi

	paso "Nothing from the rehearsal alive from a previous run"
	# The snapshot is taken to a file with a command that does NOT carry the pattern
	# inside it, and is filtered afterwards; and the filter is anchored to the binary
	# path. It is clause 24, and the reason is that a substring predicate finds
	# itself. What this form does NOT see is a daemon started by bare name, and that
	# is said because here the false negative is the grave failure.
	# The snapshot carries the pid, and it is read BEFORE being deleted: the first
	# version counted the replicas and threw the evidence away before printing the
	# message, so it said how many there were without saying which ones.
	local instantanea vivos quienes
	instantanea="$(mktemp -t naylamp-p2-pre)"
	ps -Ao pid,args > "${instantanea}"
	vivos="$(grep -cE '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${instantanea}" || true)"
	quienes="$(grep -E '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${instantanea}" | awk '{print $1}' | tr '\n' ' ' || true)"
	rm -f -- "${instantanea}"
	if [ "${vivos}" -eq 0 ]; then
		ok "zero rehearsal replicas running"
	else
		mal "${vivos} rehearsal replicas are still alive, pids: ${quienes}"
		dato "they are killed one by one by literal pid before going on"
	fi

	paso "No snapshot from a previous session left un-retired"
	# The iron session creates THREE and retires them when shutting down. One that
	# survives is a session that did not close, and its storage is still being billed.
	# It is looked at in COLD because here looking costs nothing.
	# THE FAILURE IS HARD AND NOT A WARNING, and the previous version left it in
	# `dato`, which does not touch the counter: `cold` printed READY TO POWER ON in
	# the same run where it had just written "that is not green". And the same
	# precondition is hard in `hot`, with all three billing, so the script denied its
	# own header: what can be answered before spending is answered before spending.
	if ! hay_az; then
		mal "az is not there or its session expired, so neither the snapshots nor the close can run, and that is not green"
		dato "it is fixed with: az login"
	else
		local sobran
		sobran="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv | tr '\n' ' ')"
		if [ -z "${sobran}" ]; then
			ok "zero gate snapshots left un-retired"
		else
			mal "snapshots from a previous session remain: ${sobran}"
			dato "they are retired with: ./gate/p2-preflight.sh cierre"
		fi
	fi

	paso "The localhost rehearsal, GREEN over the tree that is about to be gated"
	dato "running NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all, about two minutes"
	# The extension is .txt and not .log on purpose, and the reason is cleanliness: the
	# Makefile's `clean` rule sweeps what is in gate/out except `certs` and except
	# the `*.log` files, so a preflight log would pile up forever. This is
	# diagnostic and not evidence, so it is named so that the sweep that already
	# exists takes it away, instead of writing a new sweep.
	local log rc
	log="${OUT_DIR}/preflight-$(date -u '+%Y%m%dT%H%M%SZ').txt"
	mkdir -p "${OUT_DIR}"
	set +e
	( cd "${REPO_DIR}" && NAYLAMP_P2_LOCAL=1 ./gate/p2.sh all ) > "${log}" 2>&1
	rc=$?
	set -e
	dato "output in $(basename "${log}")"
	if [ "${rc}" -eq 0 ] && grep -q 'all rehearsal checks passed' "${log}"; then
		ok "the rehearsal closes green: $(grep -c 'gate: verdict .* = pass' "${log}") verdicts in pass and $(grep -c 'gate: NOT RUN' "${log}") declared NOT RUN"
	else
		# The failure NAMES the red verdict, which is one grep away, instead
		# of sending somebody to look at a file.
		local rojos
		rojos="$(grep -oE 'gate: verdict [A-Za-z0-9.]+ = (fail|none)' "${log}" | awk '{print $3}' | tr '\n' ' ' || true)"
		mal "the rehearsal did NOT close green, rc=${rc}; not in pass: ${rojos:-none recorded}"
		dato "the detail is in $(basename "${log}")"
	fi

	# D4: THE REHEARSAL STARTS EIGHT REPLICAS AND KILLS THEM, so the leak check of
	# the previous step goes stale the moment this step runs. It is looked at again,
	# because this script watches a leak that it can itself produce.
	paso "And nothing alive AFTER the rehearsal, which is what this script may have left"
	local ins2 v2 q2
	ins2="$(mktemp -t naylamp-p2-pre)"
	ps -Ao pid,args > "${ins2}"
	v2="$(grep -cE '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${ins2}" || true)"
	q2="$(grep -E '^ *[0-9]+ [^ ]*/(p2-naylampd|naylampd-mutante) node -id ' "${ins2}" | awk '{print $1}' | tr '\n' ' ' || true)"
	rm -f -- "${ins2}"
	[ "${v2}" -eq 0 ] && ok "the rehearsal left no replica alive" || mal "${v2} replicas alive after the rehearsal, pids: ${q2}"

	# THE SUMMARY DOES NOT DIVIDE TWO CLASSES, and the first version did: it counted
	# FAILURES, which are calls to mal(), over STEPS, which are calls to paso(). The
	# two figures do not share a denominator because a single step can record several
	# reasons: the ports step calls mal() inside a loop and with all eight
	# occupied records eight reasons on its own.
	#
	# AND NO CARDINAL GOES HERE ANY MORE, which is the correction of the ninth pass of
	# 2026-09-07 and the third this sentence needs. The two before it declared how
	# many sites call mal() in this file: the first said "fourteen inside loops",
	# which did not give fourteen by either of its halves, and the second said 19 and
	# 13, which was the count of 6 September left un-recounted while the file grew;
	# fixing it the same day gave 31 and 14, and by the end of the pass they were 34
	# and 16, because the corrections themselves add calls. A figure of the file
	# written INSIDE the file goes stale every time somebody touches it, and whoever
	# wants it counts it:
	#   grep -oE '(^|[^A-Za-z_])mal "' gate/p2-preflight.sh | wc -l
	# It is clause 11 of the protocol, the cardinal glued to its own list.
	echo
	echo "COLD HALF SUMMARY"
	echo "    checks: ${#PASOS_NOMBRE[@]}, with failure: ${PASOS_MAL}, reasons recorded: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    READY TO POWER ON."
		echo "    What follows is NOT done by this script: az vm start one at a time, and then"
		echo "    ./gate/p2-preflight.sh hot, which reads sysrq on the three, TAKES THE THREE"
		echo "    SNAPSHOTS and looks at the TLS material again."
	else
		echo "    NOTHING IS POWERED ON. What fails:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

# ---- the HOT half: it demands the three up -----------------------------------

caliente() {
	echo "PHASE 2 IRON SESSION PREFLIGHT, HOT half"
	echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "This DEMANDS the three VMs up, which means it is already being paid for."
	: "${NAYLAMP_GATE_HOSTS:?the hot half needs NAYLAMP_GATE_HOSTS}"
	: "${NAYLAMP_GATE_KEY:?the hot half needs NAYLAMP_GATE_KEY}"
	: "${NAYLAMP_GATE_USER:=ubuntu}"

	local hosts h i=0
	IFS=',' read -r -a hosts <<< "${NAYLAMP_GATE_HOSTS}"

	# THE NUMBER OF HOSTS IS COUNTED, and it was not assumed: with a single entry in
	# the variable, the previous version printed "host 1 answers" and closed with the
	# preconditions met, with the fleet billing.
	paso "The variable carries THREE hosts"
	if [ "${#hosts[@]}" -eq 3 ]; then
		ok "three hosts: ${hosts[*]}"
	else
		mal "NAYLAMP_GATE_HOSTS carries ${#hosts[@]} and not 3; the quorum run needs three"
	fi

	paso "The three hosts answer"
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		# ConnectTimeout bounds the CONNECTION and not the execution: a host that accepts TCP
		# and hangs in the shell would leave this blocked with the fleet paying. The
		# two live-server guards put the bound that was missing, which is what
		# clause 24 of the protocol demands: a wait carries a bound.
		if ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" true 2>/dev/null; then
			ok "host ${i} (${h}) answers"
		else
			mal "host ${i} (${h}) does not answer over ssh"
		fi
	done

	paso "The sysrq reboot bit on the three, which is what makes the cut cut"
	dato "Ubuntu documents 176 by default, and that is a quotation and not a measurement of these machines"
	# THE VALUE IS NOT A PURE BITMASK, and the first version of this guard treated it
	# as if it were. /proc/sys/kernel/sysrq is 0 for DISABLED, 1 for ALL the
	# functions enabled, and only above 1 is a bitmask. With sysrq=1 the reboot is
	# allowed and 1 & 128 gives 0, so the old predicate would have said "WITHOUT the
	# reboot bit" over a host that does cut, and with all three billing. The 1 is
	# checked separately and first.
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		local v
		v="$(ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'cat /proc/sys/kernel/sysrq 2>/dev/null' 2>/dev/null || true)"
		case "${v}" in
			''|*[!0-9]*)
				mal "host ${i}: /proc/sys/kernel/sysrq could not be read or did not return a number, it gave [${v}]" ;;
			0)
				mal "host ${i}: sysrq=0, sysrq is DISABLED entirely; the cut would not cut and the gate would be an empty green" ;;
			1)
				ok "host ${i}: sysrq=1, which is ALL the functions enabled, so the reboot is allowed" ;;
			*)
				if [ $(( v & 128 )) -ne 0 ]; then
					ok "host ${i}: sysrq=${v}, the reboot bit is there"
				else
					mal "host ${i}: sysrq=${v}, WITHOUT the reboot bit; the cut would not cut and the gate would be an empty green"
				fi ;;
		esac
	done

	# THE THREE SNAPSHOTS, AND THEY ARE NOT OPTIONAL. The decision is from 2026-09-07
	# and comes from a measurement that is NOT this script's, which is why it goes with
	# its source: the single-VM test run read `Total Regional vCPUs: 6 de 6` and is
	# archived in corridas/naylamp-sysrq-1vm-20260907T0013Z.txt. This script reads no
	# quota anywhere, and the previous version of this comment attributed that reading
	# to itself. What the figure says is that a rescue VM did not fit that day. The gate cuts all THREE at once, so
	# none is left healthy to look from, nor room to raise one. The snapshot
	# is the only thing that gives the fleet back under which the Phase 1 artifacts
	# were sealed. The single-VM test had margin this session does not have.
	#
	# AND THEY GO WITH THEIR REGION WRITTEN, for what the constants block says.
	#
	# WHAT THESE SNAPSHOTS ARE AND WHAT THEY ARE NOT: they are taken with the three
	# POWERED ON, so they are crash-consistent and not application-consistent, which is
	# exactly what one would want to restore after a cut. The one from the 7 September
	# test was taken with the machine off and was clean; this one is not, and that is
	# said here instead of being discovered the day something has to be restored.
	paso "The THREE OS disk snapshots, before gating anything"
	if ! hay_az; then
		mal "az is not there or its session expired, so the snapshots were NOT taken, and without them there is no gating"
	else
		local v disco snap hechos=0
		for v in "${VMS[@]}"; do
			snap="$(nombre_snap "${v}")"
			# "IT ALREADY EXISTS" IS NOT "IT IS GOOD", and the previous version took it on
			# trust with `--query name`, which succeeds with any snapshot that exists,
			# whether it is ten minutes or a week old and whether it is `Succeeded` or
			# `Failed`. With the `cold` guard dodged, that path reached `hechos=3` without
			# having taken one, and the gate cuts the three trusting old disks. The state
			# and the date are read, and only one that is good and from today counts.
			local estado_snap fecha_snap
			estado_snap="$(az_lee snapshot show -g "${GRUPO}" -n "${snap}" --query provisioningState -o tsv)"
			fecha_snap="$(az_lee snapshot show -g "${GRUPO}" -n "${snap}" --query timeCreated -o tsv)"
			if [ -n "${estado_snap}" ]; then
				if [ "${estado_snap}" = Succeeded ] && [ "${fecha_snap%%T*}" = "$(date -u '+%Y-%m-%d')" ]; then
					ok "${snap} already exists, ${estado_snap}, from ${fecha_snap%%T*}"
					hechos=$((hechos + 1))
				else
					mal "${snap} exists but is [${estado_snap}] and is from [${fecha_snap%%T*}]; it is retired with cierre and taken again"
				fi
				continue
			fi
			disco="$(az_lee vm show -g "${GRUPO}" -n "${v}" --query "storageProfile.osDisk.managedDisk.id" -o tsv)"
			if [ -z "${disco}" ]; then
				mal "the OS disk of ${v} could not be read"; continue
			fi
			if "${AZ}" snapshot create -g "${GRUPO}" -n "${snap}" -l "${REGION}" \
				--source "${disco}" --sku Standard_LRS --incremental true \
				--query provisioningState -o tsv 2>/dev/null | grep -q '^Succeeded$'; then
				ok "${snap} created in ${REGION}"
				hechos=$((hechos + 1))
			else
				mal "${snap} could not be created; without the three there is no gating"
			fi
		done
		[ "${hechos}" -eq 3 ] || mal "there are ${hechos} snapshots out of 3, and the decision is that the THREE go"
	fi

	# THE GAP 10.11 NAMES AND NOBODY COVERED: time passes between running build.sh
	# and starting the run, and the material lasts 24 h from the moment it is minted.
	# Here it is looked at again with the fleet already up, the last useful moment.
	paso "The TLS material, RE-READ now that the fleet is up"
	local id2 caduca=0
	for id2 in "${NODE_IDS[@]}" "${CLIENT_ID}"; do
		openssl x509 -in "${CERT_DIR}/node-${id2}.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1 \
			|| { mal "the certificate for id ${id2} expires within $((CERT_MARGEN_SEG/3600)) hours or has already expired"; caduca=1; }
	done
	openssl x509 -in "${CERT_DIR}/ca.pem" -noout -checkend "${CERT_MARGEN_SEG}" >/dev/null 2>&1 \
		|| { mal "the CA expires within $((CERT_MARGEN_SEG/3600)) hours or has already expired"; caduca=1; }
	if [ "${caduca}" -eq 0 ]; then
		ok "the material is still valid: CA until $(openssl x509 -in "${CERT_DIR}/ca.pem" -noout -enddate | cut -d= -f2)"
		dato "that date has to be LATER than the expected end of the run, and nobody has timed a Phase 2 one"
	fi

	# ---- B3 AND B4: THE GAP THIS SCRIPT NAMED AND DID NOT COVER -------------------
	#
	# THE THREE STEPS THAT FOLLOW ENTER ON 2026-09-09, and an external reader brought
	# them: the section 10 design was handed to that reader with a single condition,
	# that it could run nothing. Its finding: `hot` did not deploy, did not clean and
	# did not raise the fleet, and yet the header of `gate/p2.sh` states that the
	# fleet arrives up, "which is what gate/p2-preflight.sh hot
	# leaves behind". Both things could not be true at once and the one that failed
	# was the statement.
	#
	# WHAT IT COST, measured against the script and not assumed. `P2.pre.identity` on
	# iron compares `sha256sum naylamp/bin/naylampd` of the hosts, BYTE BY BYTE, with
	# the binary that same run has just cross-compiled: without a fresh
	# deployment it can never match. And the TLS material lasts 24 h from minting,
	# so whatever is on the hosts from another session is expired and the fleet does
	# not elect a leader. The run died in `pre` with the three VMs on and its three
	# snapshots taken, and spent the ONLY re-run that section 10.12
	# authorises for an infrastructure red on a step that was missing from the list.
	# THE TOOL THE WITNESS IS SEEDED WITH, checked here and not
	# discovered at the cut. Since 2026-09-09 the witness is
	# synchronised with `python3`, because no shell command can ask for a DIRECTORY
	# fsync and `dd conv=fsync` only reaches the file. The script REFUSES if it is not
	# there, instead of falling back to the global `sync` of before, which is the
	# instrument that annuls what it measures. If it is missing, it is better to know
	# here, with the three up and nothing cut, than at the instant of the cut.
	paso "python3 on the three, which is what the witness uses to sync file and directory"
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		if ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'python3 -c "import os; os.fsync(os.open(\".\", os.O_RDONLY))"' >/dev/null 2>&1; then
			ok "host ${i}: python3 is there and can fsync a directory"
		else
			mal "host ${i}: python3 is missing or cannot fsync a directory; without it the witness cannot be seeded as the design demands, and the gate must not fall back to the global sync"
		fi
	done

	# THE SUDO OF THE CUT, EXERCISED BEFORE THE CUT. It is the lesson section 10.13
	# paid for and wrote with these words, "sudo is exercised HERE and not at the
	# cut", and the iron gate had not inherited it: `corta_en` throws the output and
	# the state away on purpose, because its oracle is the boot id, so a host where
	# `sudo` asks for a password does not cut and is discovered in `P2.cut.fired` with
	# the load already made. It is asked with `-n`, which is what fails instead of
	# waiting for a password nobody is going to type.
	paso "sudo WITHOUT a password and /proc/sysrq-trigger writable on the three"
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		if ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'sudo -n test -w /proc/sysrq-trigger' >/dev/null 2>&1; then
			ok "host ${i}: sudo -n works and /proc/sysrq-trigger is writable"
		else
			mal "host ${i}: sudo -n failed or /proc/sysrq-trigger is not writable; the cut would not cut and corta_en throws its state away on purpose, so nobody would find out until P2.cut.fired"
		fi
	done

	paso "The binary and the TLS material, DEPLOYED on the three"
	if "${GATE_DIR}/deploy.sh" >/dev/null 2>&1; then
		ok "deploy.sh left the binary and the certificates on the three hosts"
	else
		mal "deploy.sh failed; without it, P2.pre.identity cannot match the binary fingerprint and the fleet does not elect a leader with expired certificates"
	fi

	# B4: THE STARTING STATE, AND IT IS A PRECONDITION AND NOT A TOLERANCE.
	#
	# `gate/omnibus.sh` and `gate/servicehealth.sh` do `rm -rf data logs` before
	# running; `gate/p2.sh` did it nowhere, and on iron it retires only
	# `data-mutante` and the witness, and at the end. What that cost is the worst
	# a dirty state can cost: `verifylog` calls a ghost every committed id
	# that this run's manifest did not emit, and the manifest is
	# 33 operations. Any commit from a previous session comes out as a ghost in the
	# THREE cold copies, `P2.recover.faithful` goes red, and section 10.12 says
	# that a PROPERTY red is NEVER re-run. The session would close with an
	# artifact that says the engine lost fidelity when what was there was
	# old state. The conclusion inverted and without a remedy.
	#
	# IT IS MEASURED, CLEANED AND MEASURED AGAIN, in that order, and all three are
	# said. Cleaning without measuring first hides where one started; measuring
	# without cleaning leaves the operator manual work the eve of an expensive run;
	# and cleaning without measuring again is exactly the tolerance this decision forbids.
	# IT IS COUNTED WITH `find -mindepth 1` AND NOT WITH `ls -A`, and this is a correction
	# from the third reader round. POSIX forces `ls` to print a
	# `directory:` header per operand when there is more than one, so `ls -A a b c` gives
	# THREE lines over THREE COMPLETELY EMPTY directories. Measured on this machine:
	# three. With that, `antes` was 3 over a flawless host, it was cleaned, `despues`
	# was 3 again, and the step closed with the most expensive message in the design over a
	# healthy fleet, with all three on and billing. **And it was blind in the other
	# direction too**: clean gave 3 and dirty gave 3+N, and both fell into the same
	# red, so the step that declared itself "a precondition and not a tolerance"
	# distinguished nothing. `find -mindepth 1` counts ENTRIES and gives zero over empty.
	#
	# AND `data-mutante` WITH THEM, which this morning's fix left out and a reader
	# brought in the second round. The whole reasoning applies to it just the same: a
	# `data-mutante` surviving from another run already carries its committed `id 7`,
	# so `phase_red_fierro` would read `perdidas=0` and publish that the mutant WITHOUT
	# a barrier did not lose its acked write on any host, which means the green of the
	# healthy fleet attests nothing. It is the same red wearing the face of a property
	# red, over the only control of the whole session. With it go also the mutant
	# binary, its pid and the witness, which are the other three things a run leaves
	# on the hosts and that only a hygiene that had reached the end would retire.
	paso "naylamp/data, naylamp/logs and naylamp/data-mutante EMPTY on the three, checked and not assumed"
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		local antes despues
		antes="$(ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1 2>/dev/null | grep -c . ; echo __FIN__' 2>/dev/null || true)"
		case "${antes}" in
			*__FIN__*) antes="${antes%%__FIN__*}" ;;
			*) mal "host ${i}: it did not answer when asked about naylamp/data, and not answering is not being empty"; continue ;;
		esac
		antes="$(printf '%s' "${antes}" | tr -d '[:space:]')"
		[ -n "${antes}" ] || antes=0
		if [ "${antes}" -eq 0 ]; then
			ok "host ${i}: naylamp/data and naylamp/logs were already empty"
			continue
		fi
		dato "host ${i}: there were ${antes} entries in naylamp/data and naylamp/logs, from a previous session; they are retired"
		ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'cd naylamp && rm -rf data logs data-mutante && rm -f bin/naylampd-mutante naylampd-mutante.pid testigo-corte.bin && mkdir -p data logs' >/dev/null 2>&1 || true
		despues="$(ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'find naylamp/data naylamp/logs naylamp/data-mutante -mindepth 1 2>/dev/null | grep -c . ; echo __FIN__' 2>/dev/null || true)"
		case "${despues}" in
			*__FIN__*) despues="${despues%%__FIN__*}" ;;
			*) mal "host ${i}: it did not answer when asked again about naylamp/data after cleaning it"; continue ;;
		esac
		despues="$(printf '%s' "${despues}" | tr -d '[:space:]')"
		[ -n "${despues}" ] || despues=0
		if [ "${despues}" -eq 0 ]; then
			ok "host ${i}: naylamp/data and naylamp/logs empty, re-read after cleaning"
		else
			mal "host ${i}: ${despues} entries remain in naylamp/data or naylamp/logs after cleaning; an old entry comes out as a ghost in the three cold copies and turns P2.recover.faithful red wearing the face of a property red"
		fi
	done

	# B3, SECOND HALF: THE FLEET UP, AND WITH A LEADER.
	#
	# Starting is not forming a cluster. `cluster.sh start` launches the three daemons;
	# what decides whether the run can begin is that they ELECT A LEADER, and that is
	# what is measured, because the symptom of an expired certificate or of crossed
	# identities is not a dead daemon, it is a cluster that never elects and that is
	# slow to diagnose with all three billing.
	paso "The fleet UP on the three, and with a leader"
	if "${GATE_DIR}/cluster.sh" start >/dev/null 2>&1; then
		ok "cluster.sh start did not fail"
	else
		mal "cluster.sh start failed, so the fleet is not up"
	fi
	local vivos=0 lider=""
	i=0
	for h in "${hosts[@]}"; do
		i=$((i + 1))
		if ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
			-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
			-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
			'pid=$(cat naylamp/naylampd.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"' 2>/dev/null; then
			vivos=$((vivos + 1))
		fi
	done
	if [ "${vivos}" -eq 3 ]; then
		ok "the three daemons are alive"
	else
		mal "there are ${vivos} daemons alive out of 3"
	fi
	# THE THREE ARE ASKED, AND WITH A BOUND, and the first version asked only host
	# 1 and without waiting. Both halves were brought by a reader in the third round
	# and both are expensive. **Only the node that WINS writes that line**, so from a
	# cold start of three, host 1 wins roughly one time in three,
	# and the other two thirds produced a red naming the wrong cause
	# -expired TLS material or crossed identities- over a healthy fleet with the
	# three powered on. And there was no wait: the `grep` ran glued to the `cluster.sh
	# start`, whose only pause is one `sleep 1` per node, so even with host 1 winning
	# the line might not be there yet. Clause 24 unpaid, in the step that was
	# added precisely to pay it.
	# AND THE LITERAL IS THE ONE THE ENGINE WRITES, which until the fourth round it was not.
	# This wait matched `became leader`, a phrase that DOES NOT EXIST in engine/: the
	# daemon writes `role=%v leader=%v term=%d`, that is `role=leader` in the one
	# that wins and `role=follower` in the other two. With the wrong literal the `case`
	# never matched, the 40 turns ran out every time, and the step closed with `mal`
	# naming expired TLS material over a healthy fleet that had elected a leader
	# in one second. Twenty seconds of waiting and a false diagnosis, with the three
	# VMs billing. The shape of the defect is clause 22 turned around:
	# a guard that declares itself exercised by its INTENT and not by the object it
	# matches. checkquorum.sh already matched `role=leader` from its first day, so
	# the house had the right literal written next door.
	#
	# IT GOES IN A VARIABLE SO THAT IT CAN BE CAST: the iron bench pulls it out of
	# here and looks for it in engine/, so renaming the engine's line turns a row
	# red instead of leaving this wait lying for another twenty seconds.
	local LITERAL_LIDER='role=leader'
	local espera=0 quien=""
	while [ "${espera}" -lt 40 ]; do
		i=0
		for h in "${hosts[@]}"; do
			i=$((i + 1))
			lider="$(ssh -i "${NAYLAMP_GATE_KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
				-o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
				-o StrictHostKeyChecking=accept-new "${NAYLAMP_GATE_USER}@${h}" \
				"grep -h -o '${LITERAL_LIDER}' naylamp/logs/node.log 2>/dev/null | head -1; echo __FIN__" 2>/dev/null || true)"
			case "${lider}" in
				*"${LITERAL_LIDER}"*) quien="${i}"; break ;;
			esac
		done
		[ -n "${quien}" ] && break
		sleep 0.5
		espera=$((espera + 1))
	done
	if [ -n "${quien}" ]; then
		ok "the fleet elected a leader, and host ${quien} wrote it with ${LITERAL_LIDER}; the three were asked because only the one that WINS leaves that line"
	else
		mal "the fleet is up and has NOT elected a leader in 20 s, asking all THREE; that is the symptom of expired TLS material or of crossed identities, and it is slow to diagnose with all three billing"
	fi

	echo
	echo "HOT HALF SUMMARY"
	echo "    checks: ${#PASOS_NOMBRE[@]}, with failure: ${PASOS_MAL}, reasons recorded: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    WHAT THIS HALF LOOKS AT HOLDS, and they are five things and not the whole list:"
		echo "    three hosts in the variable, the three answer, the reboot bit on the three,"
		echo "    the THREE snapshots taken, and the TLS material still valid. What it does NOT look at,"
		echo "    and remains the operator's own: the SKU and the region of the VMs, that the IPs are"
		echo "    the usual ones, and that they were powered on one at a time. Shutting down is no longer in this"
		echo "    list because 'cierre' does it, and the snapshots are retired there."
	else
		echo "    There are failures. With the fleet on, the decision to go on or shut down is the"
		echo "    operator's, and this script does not take it. What fails:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

# ---- the SHUTDOWN, which was prose and now runs -------------------------------

cierre() {
	echo "PHASE 2 IRON SESSION CLOSE"
	echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "It shuts the three down, retires the three snapshots and checks that ZERO remain."

	# The warning goes INSIDE a step, and not before one exists: the previous
	# version came out with "checks: 0, with failure: 0, reasons recorded: 1", which
	# means the run that most needs to shout that nothing was shut down was the one
	# that said it worst.
	paso "az available, which is what shutting down and retiring need"
	if ! hay_az; then
		mal "az is not there or its session expired: NOTHING was shut down and NOTHING was retired, and the three are still billing"
		dato "it is fixed with: az login, and this same subcommand is run again"
		echo
		echo "CLOSE SUMMARY"
		echo "    checks: ${#PASOS_NOMBRE[@]}, with failure: ${PASOS_MAL}, reasons recorded: ${FALLOS}"
		echo "    THE CLOSE DID NOT RUN. What fails:"
		echo "      - ${PASOS_NOMBRE[0]}"
		return 1
	fi
	ok "az answers and the session is good"

	paso "Shutting the three down with deallocate, which is what stops the billing"
	local v estado
	for v in "${VMS[@]}"; do
		if "${AZ}" vm deallocate -g "${GRUPO}" -n "${v}" >/dev/null 2>&1; then
			ok "${v} deallocated"
		else
			mal "${v} could not be deallocated, and stopped it keeps billing its compute"
		fi
	done

	# IT IS READ, not assumed. On 2026-08-26 the shutdown was taken for granted and
	# somebody had to go and check it afterwards.
	paso "And it is READ that the three were left deallocated"
	for v in "${VMS[@]}"; do
		estado="$(az_lee vm show -d -g "${GRUPO}" -n "${v}" --query powerState -o tsv)"
		[ "${estado}" = "VM deallocated" ] && ok "${v}: ${estado}" \
			|| mal "${v} says [${estado}] and not [VM deallocated]"
	done

	# WHAT IS RETIRED IS WHAT THE COUNT COUNTS, and not a list of three names. The
	# previous version walked `VMS` and counted with a wider pattern, so a
	# snapshot of the family with another name was detected by `cold`, seen again by
	# step 4 here, and NOBODY deleted it: the remedy the script names did not retire
	# what the script detects. Now `az` is asked which ones there are and those are deleted.
	paso "Retire the snapshots of the gate family"
	local snap listado
	listado="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv)"
	if [ -z "${listado}" ]; then
		ok "there was none to retire"
	else
		while IFS= read -r snap; do
			[ -n "${snap}" ] || continue
			# The name comes from `az` and not from here, so its shape is validated before
			# deleting by it. No delete command runs against a free string.
			case "${snap}" in
				*"${SNAP_FAMILIA}"*) ;;
				*) mal "the name [${snap}] is not of the family this script deletes by"; continue ;;
			esac
			if "${AZ}" snapshot delete -g "${GRUPO}" -n "${snap}" >/dev/null 2>&1; then
				ok "${snap} retired"
			else
				mal "${snap} could not be retired, and its storage keeps being billed"
			fi
		done <<< "${listado}"
	fi

	paso "And ZERO remain, counted and not assumed"
	local quedan
	quedan="$(az_lee snapshot list -g "${GRUPO}" --query "[?contains(name,'${SNAP_FAMILIA}')].name" -o tsv | tr '\n' ' ')"
	[ -z "${quedan}" ] && ok "zero gate snapshots in ${GRUPO}" \
		|| mal "there are still some left: ${quedan}"

	echo
	echo "CLOSE SUMMARY"
	echo "    checks: ${#PASOS_NOMBRE[@]}, with failure: ${PASOS_MAL}, reasons recorded: ${FALLOS}"
	if [ "${FALLOS}" -eq 0 ]; then
		echo "    THE SESSION IS CLOSED: three deallocated read one by one and zero snapshots."
	else
		echo "    THE CLOSE IS NOT CLEAN, and whatever stays on or stored is billed. What fails:"
		local k
		for k in "${!PASOS_NOMBRE[@]}"; do
			[ "${PASOS_FALLA[$k]:-0}" -eq 1 ] && echo "      - ${PASOS_NOMBRE[$k]}"
		done
	fi
	return "$(( FALLOS > 0 ? 1 : 0 ))"
}

case "${1:-}" in
	cold)   frio ;;
	hot)    caliente ;;
	cierre) cierre ;;
	*)
		cat >&2 <<'USAGE'
usage: p2-preflight.sh <cold|hot|cierre>

  cold    with the fleet POWERED OFF and zero cost: tree clean, signed and with CI green;
          TLS material with the margin of gate/cert-margen.sh ahead of it; the eight ports free; nothing
          from the rehearsal alive; no gate snapshot left un-retired; and the rehearsal on
          localhost green over this tree.
  hot     with the three VMs UP: that they answer over ssh, the sysrq reboot bit
          on the three, the THREE OS disk snapshots taken, and the
          TLS material re-read.
  cierre  at the end: deallocates the three, READS that they were left deallocated, retires
          the three snapshots and checks that zero remain.

Nothing is powered on until `cold` comes out with 0. Powering on remains a manual
step, with az vm start one at a time, and this script does not do it. Shutting down it DOES with
`cierre`, because on 2026-08-26 it was taken for granted and somebody had to go and look.
USAGE
		exit 2
		;;
esac
