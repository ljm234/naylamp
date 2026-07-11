#!/usr/bin/env bash
# build.sh: build the binaries and mint the certificates the gate needs, all on
# this machine. naylampd is cross compiled for linux/amd64 as a static binary
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

echo "gate: cross compiling naylampd for linux/amd64 (static, CGO_ENABLED=0)"
( cd "${REPO_DIR}" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o "${OUT_DIR}/naylampd" ./engine/cmd/naylampd )

if [ -f "${CERT_DIR}/ca.pem" ]; then
	echo "gate: certificates already present in ${CERT_DIR}, keeping them"
else
	echo "gate: minting certificates for ids 1,2,3,90 into ${CERT_DIR}"
	"${OUT_DIR}/naylamp" gencerts -dir "${CERT_DIR}" -ids 1,2,3,90
fi

echo "gate: naylampd binary is"
file "${OUT_DIR}/naylampd"
