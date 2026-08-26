#!/usr/bin/env bash
# common.sh: shared configuration and helpers for the gate scripts. Sourced by
# every script that touches the hosts: deploy, cluster, partition, checkquorum,
# faithlog, omnibus, readindex, servicehealth, tls and p1 (build.sh is
# standalone because it does not touch the hosts). It validates the four
# environment variables the gate needs, failing loudly and naming the missing
# one, and builds the host tables the other scripts index by node id.
#
# It also carries the rule that keeps a remote READ honest (DEFER-072):
# questions go through ask_on, read_on or alive_on and never through run_on,
# and a host that cannot answer is recorded as unreadable, never as clean.
# run_on stays for actions, whose failure already reports itself.
set -euo pipefail

# GATE_DIR is the directory this file lives in, so the scripts work from any cwd.
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${GATE_DIR}/out"
CERT_DIR="${OUT_DIR}/certs"

# NODE_IDS are the three replica ids; CLIENT_ID is the routing client. The client
# always runs on host 1: the nodes dial it back by address, so a fixed host keeps
# that address stable, and it is wired at node launch.
NODE_IDS=(1 2 3)
CLIENT_ID=90
NODE_PORT=9401
CLIENT_PORT=9490

require_env() {
	local name="$1"
	if [ -z "${!name:-}" ]; then
		echo "gate: environment variable ${name} is required" >&2
		exit 2
	fi
}

require_env NAYLAMP_GATE_HOSTS
require_env NAYLAMP_GATE_PRIVATE
require_env NAYLAMP_GATE_KEY
: "${NAYLAMP_GATE_USER:=ubuntu}"

if [ ! -f "${NAYLAMP_GATE_KEY}" ]; then
	echo "gate: NAYLAMP_GATE_KEY ${NAYLAMP_GATE_KEY} is not a file" >&2
	exit 2
fi

# The red arm of these helpers (gate/common_red.sh) runs the gates against a
# stub ssh and a fake fleet drawn from the documentation ranges (RFC 5737). No
# real fleet lives there, so a documentation address in NAYLAMP_GATE_HOSTS is
# either the red arm or a mistake, and only one of those may proceed. The red
# arm names itself with NAYLAMP_RED_ARM=1, and when that variable is set every
# gate announces it on both streams, so a run under a stubbed ssh can never
# read as sealing evidence.
case ",${NAYLAMP_GATE_HOSTS}," in
	*,192.0.2.*|*,198.51.100.*|*,203.0.113.*)
		if [ "${NAYLAMP_RED_ARM:-}" != 1 ]; then
			echo "gate: NAYLAMP_GATE_HOSTS holds a documentation-range address (RFC 5737), which only gate/common_red.sh may use; refusing to run" >&2
			exit 2
		fi
		;;
esac
if [ "${NAYLAMP_RED_ARM:-}" = 1 ]; then
	echo "gate: RED ARM RUN (NAYLAMP_RED_ARM=1): ssh may be stubbed and the hosts fake; nothing this run prints is gate evidence" >&2
	echo "gate: RED ARM RUN (NAYLAMP_RED_ARM=1): ssh may be stubbed and the hosts fake; nothing this run prints is gate evidence"
fi

# Split the comma lists into arrays indexed 1..3 by node id (index 0 unused). The
# order of both lists is ids 1,2,3.
IFS=',' read -r -a _pub <<< "${NAYLAMP_GATE_HOSTS}"
IFS=',' read -r -a _priv <<< "${NAYLAMP_GATE_PRIVATE}"
if [ "${#_pub[@]}" -ne 3 ] || [ "${#_priv[@]}" -ne 3 ]; then
	echo "gate: NAYLAMP_GATE_HOSTS and NAYLAMP_GATE_PRIVATE must each list exactly 3 comma separated addresses in id order 1,2,3" >&2
	exit 2
fi

declare -a HOSTS
declare -a PRIV
for _i in 0 1 2; do
	HOSTS[$((_i + 1))]="${_pub[$_i]}"
	PRIV[$((_i + 1))]="${_priv[$_i]}"
done

# ssh and scp with a non-interactive host key policy: a fresh instance is trusted
# on first contact and its key recorded, so the scripts never block on a prompt.
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "${NAYLAMP_GATE_KEY}")

# run_on <node id> <command string>: run a command on that host over ssh.
run_on() {
	local n="$1"
	shift
	ssh "${SSH_OPTS[@]}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}" "$@"
}

# ask_on <node id> <probe>: ask a yes/no question on that host and report THREE
# outcomes, never two. The probe runs with both streams dropped and picks only
# the branch, and the remote shell prints the branch it took as a word:
#
#	return 0  the host answered YES (the probe exited 0)
#	return 1  the host answered NO (the probe exited non-zero)
#	return 2  the host COULD NOT BE READ
#
# The word is the payload because the status channel cannot carry three cases:
# ssh returns 255 on its own transport failures and run_on passes that 255 up
# the same channel as the probe's exit code, so "if run_on node test -e X"
# reads a dead host as "absent". That collapse is DEFER-072: it let fifteen
# sites declare clean what nobody could check. A reply that is neither word,
# or no reply at all, returns 2, and an unreadable answer is a finding, never
# a clean bill. The probe is interpolated raw into the remote condition, so it
# must be a fixed fragment written by the caller; never build one from data
# the run does not control, because a stray brace would close the group early
# and the branch it lands on could read as a YES.
ask_on() {
	local n="$1" probe="$2"
	local out
	out="$(run_on "${n}" "if { ${probe}; } >/dev/null 2>&1; then echo __ASK_ON_YES__; else echo __ASK_ON_NO__; fi" 2>/dev/null || true)"
	case "${out}" in
		__ASK_ON_YES__) return 0 ;;
		__ASK_ON_NO__)  return 1 ;;
		*)              return 2 ;;
	esac
}

# read_on <node id> <ok statuses> <command>: read a value from that host, prove
# the answer came back WHOLE, and accept only the listed exit statuses as a
# real answer. The remote shell appends a terminator carrying the command's own
# exit status; the terminator is the proof, because an ssh cut mid-stream loses
# it, and a truncated answer that passes for a complete one is the OM.election
# half of DEFER-072. Prints the command's stdout without the terminator and:
#
#	return 0  the answer arrived whole and the command exited with one of the
#	          listed statuses (grep-flavoured reads list "0 1": no match is a
#	          valid empty answer, an error is not)
#	return 2  the host could not be read, the stream was cut, or the command
#	          exited with any other status
read_on() {
	local n="$1" okrc="$2"
	shift 2
	local out rc payload
	out="$(run_on "${n}" "$*; __read_on_rc=\$?; echo __READ_ON_EOF__\${__read_on_rc}" 2>/dev/null || true)"
	rc="${out##*__READ_ON_EOF__}"
	if [ "${rc}" = "${out}" ]; then
		return 2
	fi
	case " ${okrc} " in
		*" ${rc} "*) ;;
		*) return 2 ;;
	esac
	payload="${out%__READ_ON_EOF__*}"
	if [ -n "${payload}" ]; then
		printf '%s\n' "${payload%$'\n'}"
	fi
	return 0
}

# alive_on <node id>: three-valued liveness of the naylampd process on that
# host, read from the pidfile the launcher writes. Returns 0 alive, 1 dead, 2
# unreadable. The gate scripts grew this probe in two flavours; the probe that
# decides whether a verdict may trust a log is exactly the probe DEFER-072
# counts fail-open, and twins that can diverge get unified.
alive_on() {
	ask_on "$1" 'pid=$(cat naylamp/naylampd.pid 2>/dev/null); [ -n "${pid}" ] && kill -0 "${pid}"'
}

# copy_to <node id> <local src> <remote dst relative to home>: scp a file up.
copy_to() {
	local n="$1" src="$2" dst="$3"
	scp "${SSH_OPTS[@]}" "${src}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:${dst}"
}
