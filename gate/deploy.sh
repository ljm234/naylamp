#!/usr/bin/env bash
# deploy.sh: push the naylampd binary and each host's certificate material to the
# three hosts. Every node gets ca.pem and its own node-<id> pair; host 1 also
# gets the client id 90 pair, because the client runs there. Idempotent:
# re-running overwrites in place.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

if [ ! -f "${OUT_DIR}/naylampd" ] || [ ! -f "${CERT_DIR}/ca.pem" ]; then
	echo "gate: run build.sh first (missing ${OUT_DIR}/naylampd or ${CERT_DIR}/ca.pem)" >&2
	exit 2
fi

for n in "${NODE_IDS[@]}"; do
	echo "gate: preparing host ${n} (${HOSTS[$n]})"
	run_on "$n" 'mkdir -p naylamp/bin naylamp/certs naylamp/data naylamp/logs'
	copy_to "$n" "${OUT_DIR}/naylampd" 'naylamp/bin/naylampd'
	run_on "$n" 'chmod +x naylamp/bin/naylampd'
	copy_to "$n" "${CERT_DIR}/ca.pem" 'naylamp/certs/ca.pem'
	copy_to "$n" "${CERT_DIR}/node-${n}.pem" "naylamp/certs/node-${n}.pem"
	copy_to "$n" "${CERT_DIR}/node-${n}-key.pem" "naylamp/certs/node-${n}-key.pem"
done

echo "gate: copying client (id ${CLIENT_ID}) material to host 1"
copy_to 1 "${CERT_DIR}/node-${CLIENT_ID}.pem" "naylamp/certs/node-${CLIENT_ID}.pem"
copy_to 1 "${CERT_DIR}/node-${CLIENT_ID}-key.pem" "naylamp/certs/node-${CLIENT_ID}-key.pem"

echo "gate: deploy complete"
