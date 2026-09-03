#!/usr/bin/env bash
# common_red.sh: the red arm of common.sh, and its proof of safety.
#
# It exercises ask_on, read_on and alive_on against a STUB ssh that runs the
# remote commands for real (bash, coreutils and all) inside fake home dirs,
# with only sudo iptables staged. The rows cover the envelope, the exact
# collapse DEFER-072 names, the election log shape, and OM.hygiene end to end,
# because that verdict has its own subcommand. The other converted sites share
# one of the three shapes these rows prove at the envelope level; their wiring
# is verified by inspection and bash -n, and each gate's first real run proves
# it in anger. That limit is declared, not hidden.
#
# THE STUB IS THE DANGEROUS OBJECT and it is built so it cannot fabricate:
# it answers only for the fake fleet in NAYLAMP_GATE_HOSTS and only under
# NAYLAMP_RED_ARM=1, and it names itself on stderr otherwise, so a real gate
# with this file in front of the real ssh dies loud at its first probe. The
# workspace lives at gate/out/common-red (literal path, ignored, swept by make
# clean), it is rebuilt from zero on every run, and it is removed again when
# the rows are green. Nothing here exports anything to the caller's shell.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED="${GATE_DIR}/out/common-red"
AQUI_GATE="${GATE_DIR}"

FAILURES=0
row() {
	local id="$1" want="$2" got="$3" why="$4"
	if [ "${want}" = "${got}" ]; then
		echo "ROW ${id}: PASS ${why}"
	else
		echo "ROW ${id}: FAIL ${why} (wanted [${want}], got [${got}])"
		FAILURES=$((FAILURES + 1))
	fi
}

cleanup() {
	local rc=$?
	set +e
	if [ "${rc}" -eq 0 ] && [ "${FAILURES}" -eq 0 ]; then
		cd "${GATE_DIR}/out" && rm -rf common-red
		echo "common_red: all rows green; the fake fleet is swept (a kept one would still die at make clean)"
	else
		echo "common_red: ${FAILURES} failing rows or an abort; the workspace is kept at gate/out/common-red for inspection, and make clean sweeps it" >&2
	fi
}
trap cleanup EXIT

# ---- workspace ---------------------------------------------------------------

if [ -d "${RED}" ]; then
	cd "${GATE_DIR}/out" && rm -rf common-red
fi
mkdir -p "${RED}/bin" "${RED}/state"
for n in 1 2 3; do
	mkdir -p "${RED}/home/${n}/naylamp/bin" "${RED}/home/${n}/naylamp/logs" "${RED}/home/${n}/naylamp/data"
	printf 'red-arm fake naylampd, same build everywhere\n' > "${RED}/home/${n}/naylamp/bin/naylampd"
	: > "${RED}/state/rules.${n}"
	: > "${RED}/state/${n}.mode"
done
# Canned node logs: node 1 leads at term 1, the others follow. The election
# shape rows read these byte for byte.
printf '2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:11Z role=candidate leader=0 term=1\n2026-08-25T00:00:12Z role=leader leader=1 term=1\n' > "${RED}/home/1/naylamp/logs/node.log"
printf '2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:13Z role=follower leader=1 term=1\n' > "${RED}/home/2/naylamp/logs/node.log"
printf '2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:13Z role=follower leader=1 term=1\n' > "${RED}/home/3/naylamp/logs/node.log"
: > "${RED}/naylamp-red-key"

export NAYLAMP_RED_DIR="${RED}"
export NAYLAMP_RED_ARM=1
export NAYLAMP_GATE_HOSTS="203.0.113.11,203.0.113.12,203.0.113.13"
export NAYLAMP_GATE_PRIVATE="198.51.100.1,198.51.100.2,198.51.100.3"
export NAYLAMP_GATE_KEY="${RED}/naylamp-red-key"
export PATH="${RED}/bin:${PATH}"

# ---- the stub ssh ------------------------------------------------------------
#
# Parses the option noise, maps user@host to a fake node, and runs the command
# with bash inside that node's fake home, with the stub dir on PATH so sudo
# resolves to the shim. THREE scenarios per node, set by writing "down", "cut"
# or "nolog" into state/<n>.mode: down returns 255 to everything except the bare
# "true" that require_hosts_reachable sends, because the hole DEFER-072 names is
# the transport that dies MID-RUN, not the blackout the reachability probe
# already catches; cut prints a couple of lines and dies, the ssh severed
# mid-cat; and nolog answers everything except a read of the node log, which is
# the state cut cannot produce when the answer is a single line, because then
# read_on's terminator still fits inside the two lines the cut keeps.
cat > "${RED}/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -u
RED="${NAYLAMP_RED_DIR:?stub needs NAYLAMP_RED_DIR}"
host=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o|-i|-l|-p|-F) shift 2 ;;
		-*) shift ;;
		*@*) host="${1##*@}"; shift ;;
		*) break ;;
	esac
done
cmd="$*"
if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
	echo "common_red ssh stub: refusing to answer without NAYLAMP_RED_ARM=1; this is not the real ssh" >&2
	exit 255
fi
n=0
i=0
IFS=',' read -r -a _fleet <<< "${NAYLAMP_GATE_HOSTS:-}"
for h in "${_fleet[@]}"; do
	i=$((i + 1))
	if [ "${h}" = "${host}" ]; then
		n="${i}"
		break
	fi
done
if [ "${n}" -eq 0 ]; then
	echo "common_red ssh stub: ${host:-no-host} is not one of the fake fleet; this is not the real ssh" >&2
	exit 255
fi
mode="$(cat "${RED}/state/${n}.mode" 2>/dev/null || true)"
if [ "${mode}" = down ] && [ "${cmd}" != true ]; then
	exit 255
fi
if [ "${mode}" = nolog ]; then
	case "${cmd}" in
		*node.log*) exit 255 ;;
	esac
fi
if [ "${mode}" = cut ]; then
	case "${cmd}" in
		*cat\ *|*tail*)
			full="$(cd "${RED}/home/${n}" && PATH="${RED}/bin:${PATH}" NAYLAMP_RED_NODE="${n}" bash -c "${cmd}" 2>/dev/null || true)"
			printf '%s\n' "${full}" | head -n 2
			exit 255
			;;
	esac
fi
cd "${RED}/home/${n}" && PATH="${RED}/bin:${PATH}" NAYLAMP_RED_NODE="${n}" bash -c "${cmd}"
STUB
chmod +x "${RED}/bin/ssh"

# ---- the stub sudo -----------------------------------------------------------
#
# Only `sudo iptables` exists, backed by state/rules.<n> with one "CHAIN PEER"
# line per DROP rule, matched on chain and peer alone (the tcp/dport probes the
# servicehealth gates send read as the same rule; no row here needs them told
# apart). -D exits 1 when the rule is absent, so the delete loops terminate.
cat > "${RED}/bin/sudo" <<'SHIM'
#!/usr/bin/env bash
set -u
RED="${NAYLAMP_RED_DIR:?}"
n="${NAYLAMP_RED_NODE:?}"
rules="${RED}/state/rules.${n}"
[ -f "${rules}" ] || : > "${rules}"
if [ "${1:-}" != iptables ]; then
	echo "common_red sudo stub: only iptables exists here" >&2
	exit 1
fi
shift
op="$1"
shift
chain="${1:-}"
peer=""
while [ $# -gt 0 ]; do
	case "$1" in
		-s|-d) peer="$2"; shift 2 ;;
		*) shift ;;
	esac
done
case "${op}" in
	-C)
		grep -qx "${chain} ${peer}" "${rules}"
		exit $?
		;;
	-D)
		if grep -qx "${chain} ${peer}" "${rules}"; then
			grep -vx "${chain} ${peer}" "${rules}" > "${rules}.next" || true
			mv "${rules}.next" "${rules}"
			exit 0
		fi
		exit 1
		;;
	-I|-A)
		grep -qx "${chain} ${peer}" "${rules}" || echo "${chain} ${peer}" >> "${rules}"
		exit 0
		;;
	-L)
		cat "${rules}"
		exit 0
		;;
	*)
		echo "common_red sudo stub: iptables ${op} is not staged" >&2
		exit 1
		;;
esac
SHIM
chmod +x "${RED}/bin/sudo"

# ---- 0: the instrument on itself ---------------------------------------------

out="$("${RED}/bin/ssh" -o BatchMode=yes root@9.9.9.9 true 2>&1)" && rc=0 || rc=$?
row "0a" "255" "${rc}" "the stub refuses a host outside the fake fleet"
case "${out}" in
	*not\ the\ real\ ssh*) row "0b" "named" "named" "and it names itself doing so" ;;
	*) row "0b" "named" "silent" "and it names itself doing so" ;;
esac

out="$(env -u NAYLAMP_RED_ARM "${RED}/bin/ssh" ubuntu@203.0.113.11 true 2>&1)" && rc=0 || rc=$?
row "0c" "255" "${rc}" "the stub refuses to answer without NAYLAMP_RED_ARM=1"

out="$(env -u NAYLAMP_RED_ARM bash -c "source '${GATE_DIR}/common.sh'" 2>&1)" && rc=0 || rc=$?
row "0d" "2" "${rc}" "common.sh refuses documentation-range hosts without the red-arm variable"
case "${out}" in
	*refusing\ to\ run*) row "0e" "named" "named" "and the refusal says why" ;;
	*) row "0e" "named" "silent" "and the refusal says why" ;;
esac

out="$(bash -c "source '${GATE_DIR}/common.sh'" 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*RED\ ARM\ RUN*) row "0f" "banner" "banner" "under the variable every gate announces the red arm on its output" ;;
	*) row "0f" "banner" "missing" "under the variable every gate announces the red arm on its output" ;;
esac

out="$(env NAYLAMP_GATE_HOSTS="20.9.85.173,23.101.120.59,130.131.217.188" NAYLAMP_GATE_PRIVATE="172.16.0.4,172.16.0.5,172.16.0.6" NAYLAMP_RED_ARM=0 bash -c "source '${GATE_DIR}/common.sh'" 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*RED\ ARM\ RUN*) row "0g" "clean" "banner" "real fleet addresses source clean and silent" ;;
	*) row "0g" "clean" "clean" "real fleet addresses source clean and silent" ;;
esac

export NAYLAMP_RED_NODE=2
"${RED}/bin/sudo" iptables -C INPUT -s 198.51.100.1 -j DROP 2>/dev/null && rc=0 || rc=$?
row "0h" "1" "${rc}" "sudo shim: an absent rule answers 1"
echo "INPUT 198.51.100.1" >> "${RED}/state/rules.2"
"${RED}/bin/sudo" iptables -C INPUT -s 198.51.100.1 -j DROP 2>/dev/null && rc=0 || rc=$?
row "0i" "0" "${rc}" "sudo shim: a present rule answers 0"
"${RED}/bin/sudo" iptables -D INPUT -s 198.51.100.1 -j DROP 2>/dev/null && rc=0 || rc=$?
row "0j" "0" "${rc}" "sudo shim: deleting a present rule answers 0"
"${RED}/bin/sudo" iptables -D INPUT -s 198.51.100.1 -j DROP 2>/dev/null && rc=0 || rc=$?
row "0k" "1" "${rc}" "sudo shim: deleting an absent rule answers 1, so the teardown loops terminate"
unset NAYLAMP_RED_NODE

printf 'down' > "${RED}/state/2.mode"
"${RED}/bin/ssh" ubuntu@203.0.113.12 true >/dev/null 2>&1 && rc=0 || rc=$?
row "0l" "0" "${rc}" "a down node still answers the bare reachability true"
"${RED}/bin/ssh" ubuntu@203.0.113.12 uptime >/dev/null 2>&1 && rc=0 || rc=$?
row "0m" "255" "${rc}" "and dies on the next session, the mid-run transport failure"
printf '' > "${RED}/state/2.mode"

printf 'cut' > "${RED}/state/1.mode"
out="$("${RED}/bin/ssh" ubuntu@203.0.113.11 'cat naylamp/logs/node.log; echo __TERMINATOR__' 2>/dev/null)" && rc=0 || rc=$?
case "${out}" in
	*__TERMINATOR__*) got="terminator" ;;
	*) got="no-terminator" ;;
esac
row "0n" "no-terminator/255" "${got}/${rc}" "a cut stream loses its terminator and the status says 255"
printf '' > "${RED}/state/1.mode"

# nolog is the third scenario and it earns its row for the same reason the other
# two have theirs: a mode nobody exercises is a mode that can rot. It exists
# because cut cannot produce this state for a one-line answer, and that is not
# an argument, it is the row below: with the log unreadable the bare probe still
# answers, so the host is ALIVE, and only the log read fails.
printf 'nolog' > "${RED}/state/2.mode"
"${RED}/bin/ssh" ubuntu@203.0.113.12 true >/dev/null 2>&1 && rc=0 || rc=$?
row "0o" "0" "${rc}" "a nolog node is alive: the bare probe still answers"
out="$("${RED}/bin/ssh" ubuntu@203.0.113.12 'grep -E "role=" naylamp/logs/node.log | tail -1' 2>/dev/null)" && rc=0 || rc=$?
row "0p" "255/" "${rc}/${out}" "and only its log read fails, which is what separates an unreadable log from a dead host"
printf '' > "${RED}/state/2.mode"

# ---- the envelope, sourced once ----------------------------------------------

source "${GATE_DIR}/common.sh"

# ---- A: ask_on ----------------------------------------------------------------

ask_on 1 "true" && rc=0 || rc=$?
row "A1" "0" "${rc}" "ask_on: a true probe answers YES"
ask_on 1 "false" && rc=0 || rc=$?
row "A2" "1" "${rc}" "ask_on: a false probe answers NO"
printf 'down' > "${RED}/state/2.mode"
ask_on 2 "true" && rc=0 || rc=$?
row "A3" "2" "${rc}" "ask_on: a down host is UNREADABLE, never a NO"
ask_on 1 "echo probe-noise-on-purpose; true" && rc=0 || rc=$?
row "A4" "0" "${rc}" "ask_on: probe chatter cannot pollute the answer word"

if run_on 2 "test -e naylamp/never-there"; then old=present; else old=absent; fi
ask_on 2 "test -e naylamp/never-there" && rc=0 || rc=$?
row "A5" "absent/2" "${old}/${rc}" "the DEFER-072 collapse, one host: the old idiom reads a dead host as absent, ask_on reads it as unreadable"
printf '' > "${RED}/state/2.mode"

# ---- B: read_on ---------------------------------------------------------------

out="$(read_on 1 "0" "printf '5\\n'")" && rc=0 || rc=$?
row "B1" "0/5" "${rc}/${out}" "read_on: a whole answer arrives with its value"
out="$(read_on 1 "0 1" "echo v; false")" && rc=0 || rc=$?
row "B2" "0/v" "${rc}/${out}" "read_on: an accepted non-zero status is still an answer (the grep -c case)"
out="$(read_on 1 "0" "echo v; false")" && rc=0 || rc=$?
row "B3" "2" "${rc}" "read_on: a status outside the list is not an answer"
printf 'down' > "${RED}/state/2.mode"
out="$(read_on 2 "0" "printf x")" && rc=0 || rc=$?
row "B4" "2" "${rc}" "read_on: a down host is unreadable"
printf '' > "${RED}/state/2.mode"
printf 'cut' > "${RED}/state/1.mode"
out="$(read_on 1 "0" "cat naylamp/logs/node.log")" && rc=0 || rc=$?
row "B5" "2" "${rc}" "read_on: a stream cut mid-cat loses the terminator and is unreadable, the OM.election case"
printf '' > "${RED}/state/1.mode"
out="$(read_on 1 "0" "true")" && rc=0 || rc=$?
row "B6" "0/" "${rc}/${out}" "read_on: an empty answer is a valid answer when the command succeeded"
out="$(read_on 1 "0" "cd naylamp && cat logs/node.log")" && rc=0 || rc=$?
want="$(cat "${RED}/home/1/naylamp/logs/node.log")"
row "B7" "0/$(printf '%s' "${want}" | shasum -a 256 | cut -c1-16)" "${rc}/$(printf '%s' "${out}" | shasum -a 256 | cut -c1-16)" "read_on: the election pull arrives byte for byte"
out="$(read_on 3 "0" "cd naylamp && cat logs/absent.log")" && rc=0 || rc=$?
row "B8" "2" "${rc}" "read_on: a missing log is unreadable, not an empty one"

# ---- C: alive_on --------------------------------------------------------------

printf '%s' "$$" > "${RED}/home/1/naylamp/naylampd.pid"
alive_on 1 && rc=0 || rc=$?
row "C1" "0" "${rc}" "alive_on: a live pid answers alive"
sleep 0 & deadpid=$!
wait "${deadpid}" 2>/dev/null || true
printf '%s' "${deadpid}" > "${RED}/home/1/naylamp/naylampd.pid"
alive_on 1 && rc=0 || rc=$?
row "C2" "1" "${rc}" "alive_on: a dead pid answers dead"
alive_on 3 && rc=0 || rc=$?
row "C3" "1" "${rc}" "alive_on: no pidfile answers dead, not unreadable"
printf 'down' > "${RED}/state/2.mode"
alive_on 2 && rc=0 || rc=$?
row "C4" "2" "${rc}" "alive_on: a down host is unreadable"
printf '' > "${RED}/state/2.mode"

# ---- D: OM.hygiene end to end, the one converted verdict with a subcommand ---

out="$(bash "${GATE_DIR}/omnibus.sh" hygiene 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*OM.hygiene:\ no\ partition\ rule\ remains*) got="pass" ;;
	*) got="no-pass" ;;
esac
row "D1" "0/pass" "${rc}/${got}" "OM.hygiene over a clean fleet still passes"

echo "INPUT 198.51.100.1" >> "${RED}/state/rules.2"
out="$(bash "${GATE_DIR}/omnibus.sh" hygiene 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*OM.hygiene:\ node\ 2\ still\ drops\ input\ from\ node\ 1*) got="fail-leftover" ;;
	*) got="other" ;;
esac
row "D2" "fail-leftover" "${got}" "a leftover DROP rule is still caught, named with its pair"
: > "${RED}/state/rules.2"

printf 'down' > "${RED}/state/2.mode"
out="$(bash "${GATE_DIR}/omnibus.sh" hygiene 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*OM.hygiene:\ no\ partition\ rule\ remains*) got="passes-anyway" ;;
	*unreadable*|*did\ not\ answer*|*could\ not\ be\ read*) got="fail-unreadable" ;;
	*) got="other" ;;
esac
row "D3" "fail-unreadable" "${got}" "the DEFER-072 row: an unreadable host can never be hygiene-clean again"
printf '' > "${RED}/state/2.mode"

printf 'red-arm fake naylampd, a DIFFERENT build on node 3\n' > "${RED}/home/3/naylamp/bin/naylampd"
out="$(bash "${GATE_DIR}/omnibus.sh" hygiene 2>&1)" && rc=0 || rc=$?
case "${out}" in
	*no\ longer\ carry\ the\ same\ naylampd*) got="fail-digest" ;;
	*) got="other" ;;
esac
row "D4" "fail-digest" "${got}" "the digest half, which already failed closed, still does"
printf 'red-arm fake naylampd, same build everywhere\n' > "${RED}/home/3/naylamp/bin/naylampd"

# ---- E: tls.sh health_check, the seventh and last of the run_on questions -----
#
# THE FUNCTION IS EXTRACTED FROM tls.sh BY TEXT and evaluated here, so these rows
# run the real body and cannot drift from a copy of it. tls.sh is not run end to
# end the way omnibus.sh hygiene is above, and the reason is declared rather than
# hidden: its four checks need tcpdump, openssl, a capture host and minted
# certificates, so the largest unit this stub can drive is the function itself.
#
# The extraction carries its own anti-vacuity guard, which is the class the hook
# guard already writes down: an awk that stopped matching would define nothing,
# the rows below would call whatever else answered to that name, and the arm
# would go green having tested nothing at all.
hc_src="$(awk '/^health_check\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${GATE_DIR}/tls.sh")"
hc_lines="$(printf '%s\n' "${hc_src}" | grep -c . || true)"
case "${hc_src}" in *read_on*) hc_form=si ;; *) hc_form=no ;; esac
if [ "${hc_lines}" -lt 10 ] || [ "${hc_form}" != si ]; then
	echo "common_red: health_check did not come whole out of tls.sh (${hc_lines} lines, read_on ${hc_form})" >&2
	echo "common_red: the E rows would call something else or nothing, so this is a failure and not a skip" >&2
	exit 1
fi
eval "${hc_src}"

# E1 is the control, and without it a function that answered 2 to everything
# would score exactly as well as the fixed one.
out="$(health_check 2>&1)" && rc=0 || rc=$?
row "E1" "0" "${rc}" "health_check: three readable nodes with a leader among them answer 0"

# E2 and E3 are one state read twice, the VALUE and the LINE, because the
# collapse was in both at once: the caller got an empty string and the operator
# got a sentence claiming the node had no role line.
printf 'nolog' > "${RED}/state/2.mode"
out="$(health_check 2>&1)" && rc=0 || rc=$?
row "E2" "0" "${rc}" "health_check: a leader was found, so an unreadable third host does not change the answer"
said="$(printf '%s\n' "${out}" | grep -c 'node 2: role line COULD NOT BE READ' || true)"
lied="$(printf '%s\n' "${out}" | grep -c 'node 2: no role line yet' || true)"
row "E3" "1/0" "${said}/${lied}" "health_check: the unreadable node is NAMED unreadable, and no longer reported as having no role line"

# E4 carries the whole point. Node 1 is the only leader in the canned logs, so it
# is rewritten to a follower for these two rows and put back byte for byte after.
cp "${RED}/home/1/naylamp/logs/node.log" "${RED}/state/node1.log.kept"
printf '2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:13Z role=follower leader=1 term=1\n' > "${RED}/home/1/naylamp/logs/node.log"
out="$(health_check 2>&1)" && rc=0 || rc=$?
row "E4" "2" "${rc}" "health_check: no leader found AND a host unreadable answers 2, which is not the same as a fleet that has no leader"

# E5 is what stops the third value from swallowing the second: with every host
# readable and still no leader, the answer has to be 1 and not 2.
printf '' > "${RED}/state/2.mode"
out="$(health_check 2>&1)" && rc=0 || rc=$?
row "E5" "1" "${rc}" "health_check: no leader with every host readable is still a plain no, and answers 1"
cp "${RED}/state/node1.log.kept" "${RED}/home/1/naylamp/logs/node.log"

# ---- F: find_leader's third value, and the note that used to lie -------------
#
# THE STATE THAT MAKES THE OLD NOTES LIE is one state and not a family: a host
# that is ALIVE and whose node log cannot be read, with the office on it. The
# old code read that as the empty string, printed the word "none", and so said
# there is no leader when there is one nobody could read. The nolog mode of the
# stub above is exactly that state, which is why it was built.
#
# find_leader comes in TWO code shapes and both are exercised: omnibus.sh runs an
# alive_on guard ahead of the read, servicehealth.sh does not. The guarded shape
# has TWO ways to reach its third value, an unreadable LIVENESS probe and an
# unreadable ROLE LINE, and both get a row, because the first version of this
# section only reached the second and a mutant that deleted the first stayed
# green. A DEAD node gets a row too, for the opposite reason: it must NOT raise
# the third value, or the shape's whole purpose is gone.
#
# fl_take extracts a function BY TEXT and leaves it in fl_src. THE CHECK RUNS IN
# THE MAIN SHELL and not inside a substitution, which is where the first version
# of this guard was wrong: `eval "$(guard ...)"` runs the guard's exit in a
# subshell, eval takes an empty string, set -e never sees a status, and the
# PREVIOUS definition stays in scope. A guard written against a dead instrument,
# dead itself.
fl_src=""
fl_take() { # $1 fichero, $2 funcion, $3 minimo de lineas, $4 texto obligatorio
	fl_src="$(awk -v fn="^$2\\\\(\\\\) \\\\{" '$0 ~ fn {f=1} f{print} f&&/^\}$/{exit}' "$1")"
	if [ "$(printf '%s\n' "${fl_src}" | grep -c . || true)" -lt "$3" ] || ! printf '%s' "${fl_src}" | grep -q -- "$4"; then
		echo "common_red: ${2} did not come whole out of ${1}; the F rows would test nothing" >&2
		return 1
	fi
	return 0
}

# El cajon de la seccion: los tres nodos con pid VIVO, para que alive_on conteste
# 0 salvo donde el modo diga otra cosa, y las filas monten su estado a mano.
cp "${RED}/home/1/naylamp/logs/node.log" "${RED}/state/node1.log.f"
cp "${RED}/home/2/naylamp/logs/node.log" "${RED}/state/node2.log.f"
cp "${RED}/home/3/naylamp/logs/node.log" "${RED}/state/node3.log.f"
cp "${RED}/home/1/naylamp/naylampd.pid" "${RED}/state/node1.pid.f"
for n in 1 2 3; do printf '%s' "$$" > "${RED}/home/${n}/naylamp/naylampd.pid"; done
SEGUIDOR='2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:13Z role=follower leader=2 term=2\n'
LIDER='2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:12Z role=leader leader=%s term=2\n'

fl_take "${GATE_DIR}/omnibus.sh" leader_role 4 read_on || exit 1
eval "${fl_src}"
fl_take "${GATE_DIR}/omnibus.sh" find_leader 14 'unread=1' || exit 1
eval "${fl_src}"

# El nodo 2 lleva la oficina y su log no se puede leer; los otros dos, seguidores.
printf "${SEGUIDOR}" > "${RED}/home/1/naylamp/logs/node.log"
printf "${LIDER}" 2 > "${RED}/home/2/naylamp/logs/node.log"
printf "${SEGUIDOR}" > "${RED}/home/3/naylamp/logs/node.log"
printf 'nolog' > "${RED}/state/2.mode"
lr=0; leader_role 2 >/dev/null || lr=$?
row "F1" "2" "${lr}" "leader_role: a live host whose log cannot be read answers 2, which is the value the OM.kill branch reads"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F2" "2/" "${rc}/${out}" "find_leader, guarded shape, unreadable ROLE LINE: no leader found AND a host unreadable answers 2, not the 1 that means there is none"
printf '' > "${RED}/state/2.mode"

# La otra via de la forma con guarda: la sonda de VIVEZA es la que no se puede leer.
printf 'down' > "${RED}/state/2.mode"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F3" "2/" "${rc}/${out}" "find_leader, guarded shape, unreadable LIVENESS: the other way into the third value, which no row reached before"
printf '' > "${RED}/state/2.mode"

# Y el contrario, que es lo que la guarda existe para no confundir: un nodo MUERTO
# no levanta el tercer valor, porque un nodo muerto no tiene oficina y eso se sabe.
sleep 0 & muerto=$!
wait "${muerto}" 2>/dev/null || true
printf '%s' "${muerto}" > "${RED}/home/3/naylamp/naylampd.pid"
# Y el nodo 2 pasa a seguidor, que las filas de arriba lo dejaron con la oficina:
# con un lider vivo delante la funcion devuelve 0 antes de mirar al muerto, y esta
# fila estaria midiendo el hallazgo en vez de la ausencia del hallazgo.
printf "${SEGUIDOR}" > "${RED}/home/2/naylamp/logs/node.log"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F4" "1/" "${rc}/${out}" "find_leader, guarded shape: a DEAD node does not raise the third value, which is the distinction the guard exists for"
printf '%s' "$$" > "${RED}/home/3/naylamp/naylampd.pid"

# La forma SIN guarda, que llevan tres de los cinco, sobre el mismo estado.
fl_take "${GATE_DIR}/servicehealth.sh" find_leader 12 'unread=1' || exit 1
eval "${fl_src}"
printf "${LIDER}" 2 > "${RED}/home/2/naylamp/logs/node.log"
printf 'nolog' > "${RED}/state/2.mode"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F5" "2/" "${rc}/${out}" "find_leader without the guard: the same state gives the same 2, so the two code shapes agree"
printf '' > "${RED}/state/2.mode"

# El 2 no se traga al 1: con todo legible y sin lider, sigue siendo un no llano.
printf "${SEGUIDOR}" > "${RED}/home/2/naylamp/logs/node.log"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F6" "1/" "${rc}/${out}" "find_leader: no leader with every host readable is still a plain no, and answers 1"

# Y un lider encontrado es un lider aunque otro host no se lea, con el ilegible
# DELANTE del lider en el recorrido, que es el unico orden que prueba la frase:
# con el ilegible detras, la funcion devuelve antes de llegar a el.
printf 'nolog' > "${RED}/state/1.mode"
printf "${LIDER}" 3 > "${RED}/home/3/naylamp/logs/node.log"
rc=0; out="$(find_leader 2>/dev/null)" || rc=$?
row "F7" "0/3" "${rc}/${out}" "find_leader: a leader found AFTER an unreadable host is still a leader, which is the order that proves it"
printf '' > "${RED}/state/1.mode"

# ---- F8: LA NOTA, punta a punta, por el camino que acaba en VERDE ------------
#
# Esta es la fila que prueba lo que la clasificacion afirma y no solo el
# mecanismo: el bucle imprime su nota, un redibujado posterior encuentra lider,
# la funcion devuelve 0 y la corrida SIGUE, o sea que la frase entra en un
# artefacto verde. El cluster.sh falso es lo que hace posible el redibujado: su
# "start" devuelve el log del nodo 2 a legible, que es lo que haria un arranque
# de verdad. Sin esa recuperacion la funcion devolveria 1 y esta fila estaria
# midiendo el camino que NO mete la mentira en el sello.
#
# Se capturan LOS DOS canales, y la razon es un hallazgo: la nota no nombra al
# host, lo nombra find_leader por el canal de error. Contar solo la nota habria
# dejado la fila afirmando un nombrado que no ocurre en el canal que mira.
mkdir -p "${RED}/fakegate"
cat > "${RED}/fakegate/cluster.sh" <<'FAKE'
#!/usr/bin/env bash
[ "${1:-}" = start ] && : > "${NAYLAMP_RED_DIR}/state/2.mode"
exit 0
FAKE
chmod +x "${RED}/fakegate/cluster.sh"
# Y find_leader vuelve a ser el de omnibus.sh, que es de donde sale la funcion
# que esta fila corre: dejarla con el de servicehealth.sh que cargo la F5 haria
# que ensure_leader_off_1 de un guion corriera con el find_leader de otro, y la
# linea de error que la fila cuenta es distinta en las dos formas.
fl_take "${GATE_DIR}/omnibus.sh" find_leader 14 'unread=1' || exit 1
eval "${fl_src}"

# LOS TRES LOGS SE FIJAN, y no solo los dos que esta fila mira: la F7 dejo la
# oficina en el nodo 3, y con un lider legible ahi el bucle no llega a entrar,
# devuelve 0 en la primera vuelta y la fila mide una nota que nunca se imprimio.
printf "${SEGUIDOR}" > "${RED}/home/1/naylamp/logs/node.log"
printf "${LIDER}" 2 > "${RED}/home/2/naylamp/logs/node.log"
printf "${SEGUIDOR}" > "${RED}/home/3/naylamp/logs/node.log"
printf 'nolog' > "${RED}/state/2.mode"
nota_out="$(
	set +e
	exec 2>&1
	GATE_DIR="${RED}/fakegate"
	RESTART_TRIES=3
	RELOCATE_SETTLE_S=0
	note() { echo "gate: $*"; }
	wait_for_leader() { return 0; }
	eval "$(awk '/^ensure_leader_off_1\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${AQUI_GATE}/omnibus.sh")"
	ensure_leader_off_1
	echo "rc=$?"
)"
dice="$(printf '%s\n' "${nota_out}" | grep -c 'could NOT BE NAMED' || true)"
nombra="$(printf '%s\n' "${nota_out}" | grep -c 'find_leader: node 2 .*could not be read' || true)"
miente="$(printf '%s\n' "${nota_out}" | grep -c 'leader is on node none' || true)"
verde="$(printf '%s\n' "${nota_out}" | grep -c '^rc=0$' || true)"
row "F8" "1/1/0/1" "${dice}/${nombra}/${miente}/${verde}" "the run says the leader could not be named AND names the host on stderr, never says none, and the loop RECOVERS so the run goes on to seal"
printf '' > "${RED}/state/2.mode"
cp "${RED}/state/node1.log.f" "${RED}/home/1/naylamp/logs/node.log"
cp "${RED}/state/node2.log.f" "${RED}/home/2/naylamp/logs/node.log"
cp "${RED}/state/node3.log.f" "${RED}/home/3/naylamp/logs/node.log"
cp "${RED}/state/node1.pid.f" "${RED}/home/1/naylamp/naylampd.pid"

# ---- G: wait_converged's third value, the tenth site and the widest path -----
#
# cluster_converged used to read every node through role_of and leaderfield_of,
# which flatten an unreadable host to the empty string, so ONE unreadable node
# made it answer "not converged" about a fleet that was converged. That 1 came
# out of wait_converged into a note that ASSERTS the cluster did not reconverge,
# in a run whose only verdict is registered before it: a false line inside a
# GREEN artifact. And it was the WIDE path, not a race: with a host unreadable
# the answer is never 0, so that branch is where a reader lands.
# Y el leader_role de ESTE guion, que si no las filas G correrian el
# cluster_converged de checkquorum.sh contra el leader_role de omnibus.sh que
# dejo la seccion F. Hoy los cinco cuerpos son identicos byte a byte y el
# numero saldria igual, pero la fila afirmaria de un fichero una propiedad que
# esta leyendo de otro, y un mutante sobre el de checkquorum.sh pasaria verde.
fl_take "${GATE_DIR}/checkquorum.sh" leader_role 4 read_on || exit 1
eval "${fl_src}"
fl_take "${GATE_DIR}/checkquorum.sh" cluster_converged 18 'return 2' || exit 1
eval "${fl_src}"
fl_take "${GATE_DIR}/checkquorum.sh" wait_converged 16 'return 2' || exit 1
eval "${fl_src}"
POLL_S=0

CONV='2026-08-25T00:00:01Z role=follower leader=0 term=0\n2026-08-25T00:00:13Z role=%s leader=1 term=2\n'
printf "${CONV}" leader   > "${RED}/home/1/naylamp/logs/node.log"
printf "${CONV}" follower > "${RED}/home/2/naylamp/logs/node.log"
printf "${CONV}" follower > "${RED}/home/3/naylamp/logs/node.log"
rc=0; wait_converged 0 || rc=$?
row "G1" "0" "${rc}" "wait_converged: one leader and all three naming it is converged, which is the control"

printf 'nolog' > "${RED}/state/3.mode"
rc=0; wait_converged 0 || rc=$?
row "G2" "2" "${rc}" "wait_converged: a fleet that IS converged with one host unreadable answers 2, where it used to answer 1 and the note said it had not reconverged"
printf '' > "${RED}/state/3.mode"

printf "${CONV}" follower > "${RED}/home/1/naylamp/logs/node.log"
rc=0; wait_converged 0 || rc=$?
row "G3" "1" "${rc}" "wait_converged: no leader with every host readable is still a plain no, so the 2 does not swallow the 1"

# ---- H: las TRES ramas del if que la clasificacion llamo decimo sitio --------
#
# G1..G3 disparan wait_converged. Estas disparan lo que se HACE con su respuesta,
# que es otra cosa y es donde vivia la mentira: un if de f1_red cuyas tres ramas
# son notas y ninguna registra veredicto. Una fila por rama, porque una rama sin
# estado en el brazo es una rama que puede pudrirse, y porque la version anterior
# de este arreglo reescribio una de las tres y dejo intacta la que mas se pisa.
#
# El bloque se saca POR TEXTO del guion real, desde el comentario del if hasta su
# fi, y se corre con wait_converged forzado a cada uno de sus tres valores.
h_src="$(awk '/# AND THE ELSE OF THIS IF WAS THE WIDE PATH/{f=1} f{print} f&&/^\tfi$/{exit}' "${GATE_DIR}/checkquorum.sh")"
if [ "$(printf '%s\n' "${h_src}" | grep -c . || true)" -lt 12 ] || ! printf '%s' "${h_src}" | grep -q 'wc}" -eq 2'; then
	echo "common_red: el bloque de las tres ramas no salio entero de checkquorum.sh; las filas H no medirian nada" >&2
	exit 1
fi
w_src="$(awk '/^wait_converged\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${GATE_DIR}/checkquorum.sh")"
if [ "$(printf '%s\n' "${w_src}" | grep -c . || true)" -lt 20 ] || ! printf '%s' "${w_src}" | grep -q 'unread=0'; then
	echo "common_red: wait_converged no salio entera de checkquorum.sh; H6 y H7 no medirian nada" >&2
	exit 1
fi

h_rama() { # $1 lo que devuelve wait_converged, $2 lo que devuelve find_leader
	(
		set +e
		CONVERGE_TIMEOUT_S=1
		note() { echo "gate: $*"; }
		eval "wait_converged() { return $1; }"
		eval "find_leader() { [ ${2} -eq 0 ] && printf '1'; return ${2}; }"
		eval "_h_bloque() {
${h_src}
}"
		_h_bloque
	)
}
got="$(h_rama 0 0 | grep -c 'reconverged after heal, leader is node 1' || true)"
row "H1" "1" "${got}" "the if names the leader when wait_converged answers 0, which is the branch a green run lands in normally"
got="$(h_rama 2 0 | grep -c 'could NOT BE TOLD' || true)"
lie="$(h_rama 2 0 | grep -c 'did not reconverge' || true)"
row "H2" "1/0" "${got}/${lie}" "and with 2 it says the answer could not be told, where it used to assert the cluster had not reconverged: the tenth site, on the branch that is the WIDE path"
got="$(h_rama 1 0 | grep -c 'did not reconverge' || true)"
row "H3" "1" "${got}" "and with 1 it still says the cluster did not reconverge, because that one is true and the fix must not swallow it"

# H4 y H5: el if INTERNO, el de find_leader, cuyas otras dos ramas no tenia
# ninguna fila. Se pueden borrar enteras y el brazo se queda verde, que es lo
# mismo que le paso al if de fuera antes de las tres de arriba.
got="$(h_rama 0 2 | grep -c 'could NOT BE NAMED because' || true)"
row "H4" "1" "${got}" "the inner if names the read as unreadable when find_leader answers 2, instead of reporting no leader"
got="$(h_rama 0 1 | grep -c 'no node reports the leader role' || true)"
row "H5" "1" "${got}" "and with 1 it says no node reports it, which is the true one and must survive the fix"

# H6: que wait_converged NO se rinde a la primera lectura ilegible, que es lo
# que su comentario promete y lo que ninguna fila media: G1 a G3 la llaman con
# presupuesto CERO, o sea una sola vuelta, y el bucle entero queda sin tocar.
# Aqui cluster_converged va sustituido a proposito, porque lo que se mide es la
# POLITICA del bucle y no la lectura; va dicho para que la fila no se lea como
# que dispara el guion entero.
h_bucle() { # $1 el valor de la primera vuelta, $2 el de las siguientes
	(
		set +e
		POLL_S=0
		eval "i=0; cluster_converged() { i=\$((i + 1)); [ \"\${i}\" -ne 1 ] || return $1; return $2; }"
		eval "${w_src}"
		wait_converged 1
		echo "rc=$?"
	)
}
got="$(h_bucle 2 1 | tail -1)"
row "H6" "rc=1" "${got}" "wait_converged does not let one unreadable read taint the budget: the latch describes the LAST read, not the history"
got="$(h_bucle 2 2 | tail -1)"
row "H7" "rc=2" "${got}" "and when the budget really runs out with a read still missing, it does answer 2"

# H8 y H9: las dos ramas nuevas de la precondicion de F0, que no tenian fila
# ninguna: un mutante que mata su condicion dejaba el brazo entero verde.
p_src="$(awk '/^precondition\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${GATE_DIR}/checkquorum.sh")"
if [ "$(printf '%s\n' "${p_src}" | grep -c . || true)" -lt 25 ] || ! printf '%s' "${p_src}" | grep -q 'rl0rc}" -ne 0'; then
	echo "common_red: precondition no salio entera de checkquorum.sh; las filas H8 y H9 no medirian nada" >&2
	exit 1
fi
h_pre() { # $1 lo que devuelve leader_role, $2 lo que devuelve wait_converged
	(
		set +e
		CONVERGE_TIMEOUT_S=1
		NODE_IDS=(1 2 3)
		note() { :; }
		stop() { echo "STOP $*"; exit 3; }
		alive_on() { return 0; }
		role_line_count() { printf '7'; return 0; }
		find_leader() { printf '1'; return 0; }
		eval "leader_role() { [ ${1} -eq 0 ] && printf 'role=leader leader=1'; return ${1}; }"
		eval "wait_converged() { return ${2}; }"
		eval "${p_src}"
		precondition
	)
}
got="$(h_pre 2 0 | grep -c 'answers alive but its role line could not be read' || true)"
row "H8" "1" "${got}" "F0 stops naming the unreadable role line instead of claiming the node has none, which is what used to make the branch below unreachable"
got="$(h_pre 0 2 | grep -c 'could not be told' || true)"
row "H9" "1" "${got}" "and F0's own third value has a row, which it did not: a mutant killing its condition left the whole arm green"

cp "${RED}/state/node1.log.f" "${RED}/home/1/naylamp/logs/node.log"
cp "${RED}/state/node2.log.f" "${RED}/home/2/naylamp/logs/node.log"
cp "${RED}/state/node3.log.f" "${RED}/home/3/naylamp/logs/node.log"

# ---- T: the tripwire, DEFER-073's instrument ----------------------------------
#
# The two banned shapes are run_on in a condition and run_on piped into a
# local grep -q, the two forms the fifteen sites used to collapse. A grep
# cannot parse nested quoting, so pipes inside the remote string (which run on
# the host, like the -test.list count in p1.sh) are out of its reach by
# construction; the item declares that limit.
#
# The alarm judges NOTHING. The sweep has no exclusions, not comments and not
# this file, and its output must equal gate/common_red_pins.txt byte for byte.
# A pin is file plus EXACT TEXT, never a line number: three of the five pins
# live in files edited every day, and a line anchor there fires on any edit
# above the pin, the false-alarm class this project's register already
# retired once. The text is the identity: a new hit, a touched text, a
# deleted pin or a duplicated one all break the equality and come out red
# with nobody reading anything, while an edit that merely moves a pin inside
# its file does not, because a place is not a class event. Re-pinning is a
# deliberate act: run the sweep, look at the diff, rewrite the pins file. The
# pins live outside the *.sh glob so the pinned text itself is never swept.
BANNED_RE='\b(if|while|until)[[:space:]]+!?[[:space:]]*run_on[[:space:]]|run_on.*\|[[:space:]]*grep -q'
PINS="${GATE_DIR}/common_red_pins.txt"
sweep() {
	local f
	for f in $(cd "${GATE_DIR}" && printf '%s\n' *.sh | LC_ALL=C sort); do
		(cd "${GATE_DIR}" && grep -HE "${BANNED_RE}" -- "${f}" || true)
	done | LC_ALL=C sort
}
hits="$(sweep)"
if [ "${hits}" = "$(cat "${PINS}")" ]; then
	eq=equal
else
	# THE ONLY FIRING THIS TRIPWIRE CAN GIVE WAS THE ONE NOBODY COULD READ, and
	# the cause was one line. diff exits 1 when the files differ, which is the
	# only branch this code runs in; under set -o pipefail that 1 became the
	# pipeline's status, an assignment takes the status of its command
	# substitution, and set -e killed the script right here. The row below was
	# never printed, the diff just computed was thrown away, and the exit trap
	# announced "0 failing rows or an abort" because FAILURES was still zero.
	# Measured on a minimal copy of these lines: rc=1, nothing printed after.
	#
	# And the status is kept rather than swallowed with a bare || true, because
	# diff answers THREE things and not two. 0 and 1 are answers about the files;
	# 2 is diff saying it could not compare them, which under a blanket || true
	# would print an empty MISMATCH indistinguishable from a one-line difference.
	# That is the collapse DEFER-072 names, in the instrument this time.
	diff_out="$(diff <(printf '%s\n' "${hits}") "${PINS}" 2>&1)" && diff_rc=0 || diff_rc=$?
	# THE TRIM NEEDS ITS OWN GUARD, and this is the same defect one floor down.
	# The first fix pulled diff out of the pipeline and left printf | head inside
	# a command substitution: head exits after its lines, printf takes EPIPE, and
	# with pipefail that 141 becomes the substitution's status, so set -e kills
	# the script here again and the row goes unprinted a second time. Not
	# reachable with the five pins of today and reachable the day that file grows:
	# measured on these lines with a diff of 170889 bytes, rc=141, nothing after.
	# A bare || true is right HERE and wrong one floor up, and the difference is
	# what the status means: diff's status is an answer about the files, head's is
	# an accident of how much got trimmed.
	if [ "${diff_rc}" -gt 1 ]; then
		eq="UNREADABLE: diff could not compare the sweep against ${PINS} (status ${diff_rc}): $(printf '%s' "${diff_out}" | head -n 1 || true)"
	else
		eq="MISMATCH: $(printf '%s\n' "${diff_out}" | head -n 4 | tr '\n' ';' || true)"
	fi
fi
row "T1" "equal" "${eq}" "tripwire: the sweep over the gates equals the pinned set byte for byte, nobody judges a hit"

staged="${RED}/state/tripwire-stage.sh"
printf 'if run_on 1 "test -e x"; then :; fi\nrun_on 1 "cat f" 2>/dev/null | grep -q yes\n' > "${staged}"
hits="$(grep -cE "${BANNED_RE}" "${staged}" || true)"
row "T2" "2" "${hits}" "tripwire, red of the tripwire: the two banned shapes are caught when staged"

printf '# if run_on 1 "test -e x"; then :; fi\n' > "${staged}"
hits="$(grep -cE "${BANNED_RE}" "${staged}" || true)"
row "T3" "1" "${hits}" "tripwire: a comment naming the idiom shows in the sweep like any other line, so it can only live as a pin, never as a judgment call"

# ---- verdict ------------------------------------------------------------------

echo "common_red: ${FAILURES} failing rows"
[ "${FAILURES}" -eq 0 ]
