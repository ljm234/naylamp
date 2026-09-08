#!/usr/bin/env bash
# build.sh: build the binaries and mint the certificates the gate needs, all on
# this machine. naylampd is cross compiled for linux/arm64 as a static binary
# (CGO_ENABLED=0), ready to scp to an EC2 host. The demo naylamp is built
# natively only to mint certificates with its gencerts subcommand. Certificates
# are minted once and reused, so re-running does not rotate identities.
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
CERT_DIR="${OUT_DIR}/certs"

mkdir -p "${OUT_DIR}"

echo "gate: building the native demo (only for gencerts)"
( cd "${REPO_DIR}" && go build -o "${OUT_DIR}/naylamp" ./engine/cmd/naylamp )

echo "gate: cross compiling naylampd for linux/arm64 (static, CGO_ENABLED=0)"
( cd "${REPO_DIR}" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "${OUT_DIR}/naylampd" ./engine/cmd/naylampd )

# The log-fidelity gate (faithlog.sh) runs the faultlog injector on the hosts, and
# faultlog lives in the demo naylamp, never in naylampd. So naylamp is also cross
# compiled for the hosts here, in addition to the native build above that mints
# certificates. Deploying it is harmless: it is a support tool the gate invokes by
# hand against copies, and it never runs as the production daemon.
echo "gate: cross compiling naylamp for linux/arm64 (the faultlog injector for the log-fidelity gate)"
( cd "${REPO_DIR}" && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o "${OUT_DIR}/naylamp-linux" ./engine/cmd/naylamp )

# The ids this gate mints for, written ONCE. The reuse check below counts what it
# visited against the length of THIS list, so the count cannot drift from the set
# that is actually minted, and adding an id cannot leave the check certifying over
# a set it no longer covers.
CERT_IDS="1,2,3,90"

mint_certs() {
	echo "gate: minting certificates for ids ${CERT_IDS} into ${CERT_DIR}"
	"${OUT_DIR}/naylamp" gencerts -dir "${CERT_DIR}" -ids "${CERT_IDS}"
}

# Reuse the certificates only when they are present and still valid with room to
# spare. The gate mints short-lived certificates, and a run that reuses an expired
# or nearly-expired set fails as a broken mutual TLS handshake with no leader, not
# as an obvious certificate error, which is a slow thing to diagnose on the hosts.
# checkend rejects any certificate that is already expired or expires within the
# margin, and the margin is NOT written here: it lives in gate/cert-margen.sh and
# is sourced above, because this script and gate/p2-preflight.sh have to demand
# the same thing or there is a window where one refuses to start and the other
# refuses to re-mint. It reads 21600, six hours, since 2026-09-08; it was two
# hours before, and two is shorter than an iron session. The
# private keys (node-*-key.pem) are not certificates, so they are skipped.
if [ ! -f "${CERT_DIR}/ca.pem" ]; then
	mint_certs
else
	# WALKING THE ID LIST IS WHAT MAKES THIS A CHECK, and the road here went
	# through a weaker version worth writing down, because the weaker version is
	# the one that looks right.
	#
	# The loop used to be a glob over node-*.pem. With the node certificates gone
	# and only their keys left it visited ca.pem alone, found nothing stale, and
	# printed the reuse line below over a set that cannot hand a single node an
	# identity; the run then dies on the hosts as the broken mutual TLS handshake
	# with no leader that the reuse comment above calls a slow thing to diagnose.
	#
	# COUNTING WHAT THE GLOB FOUND DID NOT FIX IT. A count answers how many and
	# the question is WHICH. Measured on four directories, all with a valid CA:
	# ids 1,2,3,90 present kept them, correctly; node-90 swapped for node-91 was
	# KEPT with five certificates and no identity for the client; five ids none of
	# which is 90 was KEPT as well. Only a directory that was SHORT re-minted, and
	# being short is not the failure that matters. So the loop asks the list.
	IFS=',' read -r -a _cert_ids <<< "${CERT_IDS}"
	# AND THE LIST ITSELF IS CHECKED, because deriving a length from a list that
	# came back empty is the same defect one level up: with CERT_IDS emptied,
	# read -a leaves a zero-length array WITHOUT failing under set -e, measured on
	# these lines, and every id loop below would then be vacuously satisfied. An
	# empty set is answered, not approved.
	if [ "${#_cert_ids[@]}" -eq 0 ]; then
		echo "gate: CERT_IDS is empty, so there is no identity set to check the certificate directory against" >&2
		exit 2
	fi
	missing=""
	stale=""
	# The CA first, then one named certificate per id. Nothing here globs: a name
	# that is absent is reported as absent instead of shortening a count.
	for pem in "${CERT_DIR}/ca.pem" "${_cert_ids[@]/#/${CERT_DIR}/node-}"; do
		case "${pem}" in "${CERT_DIR}/node-"*) pem="${pem}.pem" ;; esac
		if [ ! -f "${pem}" ]; then
			missing="${missing} $(basename "${pem}")"
			continue
		fi
		if ! openssl x509 -in "${pem}" -checkend "${CERT_MARGEN_SEG}" -noout >/dev/null 2>&1; then
			stale="${pem}"
			break
		fi
	done
	if [ -n "${missing}" ] && [ -z "${stale}" ]; then
		echo "gate: ${CERT_DIR} is missing the certificates this gate mints for ids ${CERT_IDS}:${missing}; re-minting the whole set"
		rm -rf "${CERT_DIR}"
		mint_certs
	elif [ -n "${stale}" ]; then
		echo "gate: certificate ${stale} is expired or expires within ${CERT_MARGEN_SEG}s; re-minting the whole set into ${CERT_DIR}"
		rm -rf "${CERT_DIR}"
		mint_certs
	else
		echo "gate: the CA and one certificate per id (${CERT_IDS}) are present in ${CERT_DIR} and valid for at least ${CERT_MARGEN_SEG}s, keeping them"
	fi
fi

echo "gate: naylampd binary is"
file "${OUT_DIR}/naylampd"
echo "gate: naylamp (linux, faultlog) binary is"
file "${OUT_DIR}/naylamp-linux"
