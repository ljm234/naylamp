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
