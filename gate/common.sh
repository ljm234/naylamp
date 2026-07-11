#!/usr/bin/env bash
# common.sh: shared configuration and helpers for the Phase 4 gate scripts.
# Sourced by deploy.sh, cluster.sh, and partition.sh (build.sh is standalone
# because it does not touch the hosts). It validates the four environment
# variables the gate needs, failing loudly and naming the missing one, and
# builds the host tables the other scripts index by node id.
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

# copy_to <node id> <local src> <remote dst relative to home>: scp a file up.
copy_to() {
	local n="$1" src="$2" dst="$3"
	scp "${SSH_OPTS[@]}" "${src}" "${NAYLAMP_GATE_USER}@${HOSTS[$n]}:${dst}"
}
