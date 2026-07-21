#!/usr/bin/env bash
# build.sh: build the binaries and mint the certificates the gate needs, all on
# this machine. naylampd is cross compiled for linux/arm64 as a static binary
# (CGO_ENABLED=0), ready to scp to an EC2 host. The demo naylamp is built
# natively only to mint certificates with its gencerts subcommand. Certificates
# are minted once and reused, so re-running does not rotate identities.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${GATE_DIR}/.." && pwd)"
OUT_DIR="${GATE_DIR}/out"
CERT_DIR="${OUT_DIR}/certs"

mkdir -p "${OUT_DIR}"

echo "gate: building the native demo (only for gencerts)"
( cd "${REPO_DIR}" && go build -o "${OUT_DIR}/naylamp" ./engine/cmd/naylamp )

echo "gate: cross compiling naylampd for linux/arm64 (static, CGO_ENABLED=0)"
( cd "${REPO_DIR}" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "${OUT_DIR}/naylampd" ./engine/cmd/naylampd )

mint_certs() {
	echo "gate: minting certificates for ids 1,2,3,90 into ${CERT_DIR}"
	"${OUT_DIR}/naylamp" gencerts -dir "${CERT_DIR}" -ids 1,2,3,90
}

# Reuse the certificates only when they are present and still valid with room to
# spare. The gate mints short-lived certificates, and a run that reuses an expired
# or nearly-expired set fails as a broken mutual TLS handshake with no leader, not
# as an obvious certificate error, which is a slow thing to diagnose on the hosts.
# checkend 7200 rejects any certificate that is already expired or expires within
# the next two hours, wide enough that one cannot lapse in the middle of a run. The
# private keys (node-*-key.pem) are not certificates, so they are skipped.
if [ ! -f "${CERT_DIR}/ca.pem" ]; then
	mint_certs
else
	stale=""
	for pem in "${CERT_DIR}/ca.pem" "${CERT_DIR}"/node-*.pem; do
		case "${pem}" in *-key.pem) continue ;; esac
		if ! openssl x509 -in "${pem}" -checkend 7200 -noout >/dev/null 2>&1; then
			stale="${pem}"
			break
		fi
	done
	if [ -n "${stale}" ]; then
		echo "gate: certificate ${stale} is expired or expires within 2 hours; re-minting the whole set into ${CERT_DIR}"
		rm -rf "${CERT_DIR}"
		mint_certs
	else
		echo "gate: certificates already present in ${CERT_DIR} and valid for at least 2 hours, keeping them"
	fi
fi

echo "gate: naylampd binary is"
file "${OUT_DIR}/naylampd"
