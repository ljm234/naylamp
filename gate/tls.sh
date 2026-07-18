#!/usr/bin/env bash
# tls.sh: prove on the three real hosts what 4.4 only proved on loopback, that
# inter host traffic is mutual TLS and that a peer without a certificate from the
# trusted ca is rejected. It runs four checks over ssh and adds no engine code:
#
#   peer       T4.1 a forged peer (an independent ca and a node-id certificate
#              minted by the existing gencerts) is refused by the server's client
#              auth. The test is behavioral and deterministic: the forged
#              certificate is presented while the real ca is trusted, so the only
#              thing that can fail is the node rejecting the stranger certificate,
#              and the check is whether the cluster still serves an operation.
#              Valid material is served, forged material is not. The positive
#              control (valid material served) runs first, or the rejection means
#              nothing; and if client auth were off the forged material would be
#              served too and this check would fail, so a pass is coupled to the
#              property. An openssl probe is added only as best effort evidence of
#              the exact tls alert, never as the verdict, because openssl s_client
#              reads the TLS 1.3 client auth alert only when timing allows.
#   encrypt    T4.2 capture the raft port with tcpdump while a marked write goes
#              through and confirm neither the marker nor the framing magic
#              (bytes 50 4c 59 4e) appear in the clear. T4.3 the same capture and
#              search over a known cleartext channel must show them, or the
#              method is blind and the T4.2 verdict is void.
#   handshake  T4.4 a fresh connection between hosts negotiates TLS 1.3.
#   all        run peer, then encrypt, then handshake, then a health check.
#
# Usage: tls.sh <all|peer|encrypt|handshake>
#
# Every check registers a verdict when it emits one. The final report treats a
# check that never registered a verdict as not passed, never as passed by
# omission, and is emitted from the exit trap so it runs on every exit path: the
# run can be called a success only when every expected check said pass.
#
# Assumes cluster.sh start has run and a leader has been elected, the same
# precondition the failover and partition steps carry. It adds no firewall
# rules; captures, the control listener, and the forged material are torn down on
# exit and cleared again at start. Tools it expects already present on the hosts:
# tcpdump, openssl, nc, od, timeout. It installs nothing; a missing tool stops
# the run with a report.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

# CAPTURE_HOST is a node host that is not the client host, so the raft port there
# carries consensus and client traffic either way. PROBE_TARGET is the node the
# openssl probes dial. CTRL_PORT is an unused port for the cleartext control on
# the capture host's loopback, kept off 9401 and 9490 so it never collides with
# a node or the client and never depends on a cross host firewall rule.
CAPTURE_HOST=2
PROBE_TARGET=2
CTRL_PORT=9402

# The marker is a nonzero id whose little endian wire bytes spell NAYLAMP! in
# ascii (4e 41 59 4c 41 4d 50 21), a distinctive run to grep for in a capture.
# MARKER_ID_HEX_LE is those eight bytes as the command codec writes them on the
# wire, wide enough that a chance match in ciphertext is not a real concern.
MARKER_ID=$((16#21504D414C59414E))
MARKER_ID_HEX_LE="4e41594c414d5021"
# FRAME_MAGIC is the on wire framing magic of every cluster block, 50 4c 59 4e.
# It is only four bytes, so a chance hit in ciphertext is rare but not
# impossible; a hit biases toward a false failure of T4.2, never a false pass.
FRAME_MAGIC="504c594e"

# CERT_ALERT is the signature of the server's client auth turning away a
# certificate it does not trust: a fatal certificate alert. A clean shutdown
# (close_notify, alert number 0) is deliberately not matched.
CERT_ALERT='unknown ca|bad certificate|certificate required|certificate unknown|no peer certificate|handshake failure|alert number (4[0-9]|11[0-9])'

ROGUE_DIR="${OUT_DIR}/rogue-certs"
PCAP_ENC="/tmp/t4-encrypt.pcap"
PCAP_CTRL="/tmp/t4-control.pcap"

# Verdict registry. record_verdict is called once per check when it finishes.
# EXPECTED is the set of checks the invoked subcommand must pass. COMPLETED is
# set only after the last check returns, so a run that dies partway can never
# read as complete. CHECK_FAILED is the per-check flag fail() raises.
VERDICTS=" "
EXPECTED=""
COMPLETED=0
CHECK_FAILED=0

pass() { echo "gate: PASS $*"; }
note() { echo "gate: $*"; }
fail() { echo "gate: FAIL $*" >&2; CHECK_FAILED=1; }
stop() { echo "gate: STOP $*" >&2; exit 1; }

# record_verdict appends a check's outcome. verdict_of reports pass, fail, or
# none for a check id, with fail winning over pass and pass over none.
record_verdict() { VERDICTS="${VERDICTS}$1=$2 "; }
verdict_of() {
	case "${VERDICTS}" in
		*" $1=fail "*) printf fail ;;
		*" $1=pass "*) printf pass ;;
		*) printf none ;;
	esac
}

# begin_check resets the per-check failure flag; end_check turns it into the
# check's verdict. A check that never reaches end_check registers nothing.
begin_check() { CHECK_FAILED=0; }
end_check() {
	if [ "${CHECK_FAILED}" -eq 0 ]; then
		record_verdict "$1" pass
	else
		record_verdict "$1" fail
	fi
}

# emit_final_verdict prints one line per expected check and returns 0 only when
# the run completed and every expected check registered pass. It exits nothing,
# so the trap owns the process exit code; keeping it side effect free is what
# lets the local demonstration exercise it directly.
emit_final_verdict() {
	[ -z "${EXPECTED}" ] && return 0
	local id v bad=""
	for id in ${EXPECTED}; do
		v="$(verdict_of "${id}")"
		printf 'gate: verdict %s = %s\n' "${id}" "${v}" >&2
		if [ "${v}" != pass ]; then
			bad="${bad} ${id}(${v})"
		fi
	done
	if [ "${COMPLETED}" -eq 1 ] && [ -z "${bad}" ]; then
		echo "gate: all checks passed (${EXPECTED})"
		return 0
	fi
	if [ -n "${bad}" ]; then
		echo "gate: NOT A SUCCESS; checks without a passing verdict:${bad}" >&2
	else
		echo "gate: NOT A SUCCESS; the run did not reach a clean completion" >&2
	fi
	return 1
}

# run_on_ok runs a remote command whose failure must not abort the gate: a
# teardown that finds no process to kill or no file to remove is not an error,
# and pkill returns nonzero when it matches nothing, so under set -euo pipefail
# these must not propagate. Use run_on (which does surface a nonzero status)
# whenever a remote failure should be seen; use run_on_ok only for teardown.
run_on_ok() {
	run_on "$@" || true
	return 0
}

# teardown removes what a run leaves behind on the hosts: any capture, the
# control listener, the temp files, and the forged material. It adds no firewall
# rules, so there is nothing to heal. It is tolerant by design and runs both at
# start (to clear a previous aborted run) and from the exit trap.
teardown() {
	run_on_ok "${CAPTURE_HOST}" "sudo pkill -f 'tcpdump.*t4-' 2>/dev/null; pkill -f 'nc .*${CTRL_PORT}' 2>/dev/null; sudo rm -f ${PCAP_ENC} ${PCAP_CTRL} /tmp/t4-*.log /tmp/t4-control-recv.bin 2>/dev/null"
	run_on_ok 1 "rm -rf naylamp/rogue 2>/dev/null"
}

# cleanup runs on every exit path. It tears down, then emits the final verdict,
# and forces a non-zero exit whenever the run did not end in an all-pass verdict,
# so a run that died partway can never leave a success on the terminal.
cleanup() {
	local rc=$?
	set +e
	teardown
	if ! emit_final_verdict; then
		[ "${rc}" -eq 0 ] && rc=1
	fi
	exit "${rc}"
}
trap cleanup EXIT INT TERM

# require_tools stops the run, with a report and no install, if a host is missing
# any tool the checks need.
require_tools() {
	local host="$1" missing="" t
	for t in tcpdump openssl nc od timeout; do
		if ! run_on "${host}" "command -v ${t} >/dev/null 2>&1"; then
			missing="${missing} ${t}"
		fi
	done
	if [ -n "${missing}" ]; then
		stop "host ${host} is missing required tools:${missing}; this script installs nothing, install them or run on a host that has them"
	fi
	note "host ${host} has the required tools (tcpdump openssl nc od timeout)"
}

# capture_start begins a background tcpdump on the capture host, filtered to one
# tcp port, writing a pcap. It mirrors cluster.sh: nohup with stdin from
# /dev/null and output to a log frees the ssh channel so this returns. capture is
# stopped by pkill on the unique pcap path, so no pid bookkeeping is needed.
capture_start() {
	local pcap="$1" port="$2" tag="$3"
	run_on "${CAPTURE_HOST}" "sudo rm -f ${pcap}; sudo nohup tcpdump -i any -s 0 -U -w ${pcap} tcp port ${port} > /tmp/t4-${tag}.log 2>&1 < /dev/null & sleep 2; echo capture on host ${CAPTURE_HOST} port ${port} started"
}

# capture_stop kills the tcpdump writing a given pcap and lets it flush. The
# remote pkill returns non-zero when the process is already gone, which is not a
# failure, so it goes through run_on_ok; the progress line is printed locally so
# it shows regardless of the remote status.
capture_stop() {
	local pcap="$1"
	run_on_ok "${CAPTURE_HOST}" "sudo pkill -f 'tcpdump.*$(basename "${pcap}")' 2>/dev/null; sleep 1"
	note "capture stopped"
}

# pcap_packets prints how many packets a pcap holds, so an empty capture is never
# mistaken for an absent marker. It is tolerant (a missing file is zero packets)
# and the output is reduced to digits so ssh noise cannot masquerade as a count.
pcap_packets() {
	local pcap="$1" n
	n="$(run_on_ok "${CAPTURE_HOST}" "sudo tcpdump -r ${pcap} 2>/dev/null | wc -l")"
	printf '%s' "${n}" | tr -dc '0-9'
}

# pcap_has_hex searches a pcap for a byte sequence given as hex (no spaces). It
# returns 0 if the sequence is present, 1 if it is cleanly absent (the search ran
# and did not match), and 2 if the search could not run at all (an ssh or tool
# error): a run that could not look is never reported as absent, so a transport
# failure can never become a T4.2 security pass. It flattens the file to a hex
# stream with od, tr, and grep. Absence is a meaningful answer, so callers weigh
# the three outcomes rather than routing it through run_on_ok.
pcap_has_hex() {
	local pcap="$1" hex="$2" rc=0
	run_on "${CAPTURE_HOST}" "sudo od -An -v -tx1 ${pcap} 2>/dev/null | tr -dc '0-9a-f' | grep -qi '${hex}'" || rc=$?
	case "${rc}" in
		0) return 0 ;;
		1) return 1 ;;
		*) return 2 ;;
	esac
}

# client_op_tls runs one client operation on host 1 with the given tls material
# and appends its exit line. Holding the ca constant and swapping only the
# presented certificate isolates the node's client auth as the single variable.
# The call sites pass fixed, space free arguments, so the unquoted expansion is
# intentional and safe.
client_op_tls() {
	local cert="$1" key="$2" ca="$3"
	shift 3
	local group="1=${PRIV[1]}:${NODE_PORT},2=${PRIV[2]}:${NODE_PORT},3=${PRIV[3]}:${NODE_PORT}"
	run_on 1 "cd naylamp && NAYLAMP_TLS_CERT=${cert} NAYLAMP_TLS_KEY=${key} NAYLAMP_TLS_CA=${ca} ./bin/naylampd client -listen ${PRIV[1]}:${CLIENT_PORT} -group '${group}' $* ; echo exit=\$?" 2>&1
}

# client_op runs one client operation as id 90 with the real material, exactly as
# the runbook wires it.
client_op() {
	client_op_tls certs/node-90.pem certs/node-90-key.pem certs/ca.pem "$@"
}

# sclient runs one openssl s_client probe from host 1 to the probe target. It
# trusts the real ca, so the client always verifies the server and a failure can
# only come from the server's view of the presented certificate, and it pushes a
# short application write so it stays connected to read any alert the server
# sends after the handshake. It returns the combined output; timeout guards a
# hang.
sclient() {
	local cert="$1" key="$2"
	run_on 1 "cd naylamp && echo probe | timeout 15 openssl s_client -connect ${PRIV[${PROBE_TARGET}]}:${NODE_PORT} -cert ${cert} -key ${key} -CAfile certs/ca.pem -tls1_3 2>&1 || true"
}

# health_check prints each node's last role line and returns 0 if a leader is
# present, the same signal cluster.sh status reads.
health_check() {
	local n line leader=0
	for n in "${NODE_IDS[@]}"; do
		line="$(run_on "$n" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1' 2>/dev/null || true)"
		printf 'gate: node %s: %s\n' "$n" "${line:-no role line yet}"
		case "$line" in *role=leader*) leader=1 ;; esac
	done
	[ "$leader" -eq 1 ]
}

# mint_rogue mints an independent ca and a node-2 certificate into a separate
# directory with the existing gencerts subcommand, then copies the node-2 pair to
# host 1 under naylamp/rogue. Its ca is not the ca the cluster trusts, which is
# the whole point: this certificate is well formed but signed by a stranger.
mint_rogue() {
	if [ ! -x "${OUT_DIR}/naylamp" ]; then
		stop "missing ${OUT_DIR}/naylamp; run build.sh first"
	fi
	rm -rf "${ROGUE_DIR}"
	mkdir -p "${ROGUE_DIR}"
	note "minting a forged ca and node-2 certificate into ${ROGUE_DIR}"
	"${OUT_DIR}/naylamp" gencerts -dir "${ROGUE_DIR}" -ids 2 >/dev/null
	run_on 1 'mkdir -p naylamp/rogue'
	copy_to 1 "${ROGUE_DIR}/node-2.pem" 'naylamp/rogue/node-2.pem'
	copy_to 1 "${ROGUE_DIR}/node-2-key.pem" 'naylamp/rogue/node-2-key.pem'
}

# t41_peer: a forged peer is rejected by the server's client auth. The verdict is
# behavioral and deterministic: valid material completes a read only operation,
# the forged certificate does not, with the trusted ca held constant so the node
# rejecting the stranger certificate is the only variable.
t41_peer() {
	note "T4.1 forged peer rejection (operations through node group, real ca trusted throughout)"
	mint_rogue
	begin_check

	note "positive control: the real node-90 certificate must be served"
	local ok_out
	ok_out="$(client_op_tls certs/node-90.pem certs/node-90-key.pem certs/ca.pem -op search -vec 1,0,0 -k 1 -deadline 10s)"
	printf '%s\n' "${ok_out}"
	if ! printf '%s' "${ok_out}" | grep -q 'exit=0$'; then
		stop "the valid certificate could not perform an operation; the cluster is down or has no leader, so the rejection test would mean nothing"
	fi
	pass "T4.1 control: valid certificate served an operation (exit=0)"

	note "forged peer: the node-2 certificate signed by the stranger ca, presented while trusting the real ca"
	local bad_out
	bad_out="$(client_op_tls rogue/node-2.pem rogue/node-2-key.pem certs/ca.pem -op search -vec 1,0,0 -k 1 -deadline 10s)"
	printf '%s\n' "${bad_out}"
	if printf '%s' "${bad_out}" | grep -q 'exit=0$'; then
		fail "T4.1 the forged certificate completed an operation; the node ACCEPTED it, which is a security regression"
	elif printf '%s' "${bad_out}" | grep -q 'exit=1$'; then
		pass "T4.1 forged peer rejected: the cluster served the real certificate but refused the stranger ca certificate (exit=1, no result)"
	else
		fail "T4.1 the forged attempt exited neither 0 nor 1; a load or argument error, not a clean rejection, inspect the output"
	fi

	note "best effort: an openssl probe with the forged certificate, to record the exact tls alert when the handshake timing surfaces it"
	local probe_out
	probe_out="$(sclient rogue/node-2.pem rogue/node-2-key.pem)"
	if printf '%s' "${probe_out}" | grep -Eqi "${CERT_ALERT}"; then
		printf '%s\n' "${probe_out}" | grep -Ei "${CERT_ALERT}" | head -2
		note "the server sent a certificate alert to the forged probe (exact tls error captured)"
	else
		note "no certificate alert surfaced this run; openssl s_client reads the TLS 1.3 client auth alert only when timing allows, so the behavioral check above is the verdict, not this probe"
	fi

	note "cluster health after the forged attempt"
	if health_check; then
		pass "T4.1 cluster still has a leader after the forged attempt"
	else
		fail "T4.1 no leader after the forged attempt"
	fi

	end_check T4.1
}

# t42_t43_encrypt: the marker is absent from the encrypted capture, and the same
# search over a known cleartext channel finds it. The control runs and is
# blocking: if it does not find the marker, the capture method is blind and the
# T4.2 verdict is withheld. The control travels host 2 loopback while T4.2
# watches the real interface, so the control validates the search method while
# the packets>0 guard covers the capture actually seeing the raft port.
t42_t43_encrypt() {
	note "T4.2 capture the raft port while a marked write commits"
	capture_start "${PCAP_ENC}" "${NODE_PORT}" "encrypt"
	local put_out
	put_out="$(client_op -op put -id "${MARKER_ID}" -vec 1,0,0 -deadline 20s)"
	printf '%s\n' "${put_out}"
	sleep 2
	capture_stop "${PCAP_ENC}"

	local packets
	packets="$(pcap_packets "${PCAP_ENC}")"
	packets="${packets:-0}"
	note "captured ${packets} packets on port ${NODE_PORT}"
	local wrote_ok=0
	if printf '%s' "${put_out}" | grep -q 'exit=0$'; then
		wrote_ok=1
	else
		note "the marked write did not report exit=0; the id marker is corroboration only, the framing magic check on heartbeat traffic is the T4.2 verdict"
	fi

	note "T4.3 positive control: the same capture and search over a cleartext nc channel"
	begin_check
	# choose the nc listen syntax that matches the host's nc: openbsd takes a bare
	# port, traditional takes -p. the sender form is the same for both.
	run_on "${CAPTURE_HOST}" "nohup sh -c 'if nc -h 2>&1 | grep -qi openbsd; then timeout 10 nc -l ${CTRL_PORT} > /tmp/t4-control-recv.bin; else timeout 10 nc -l -p ${CTRL_PORT} > /tmp/t4-control-recv.bin; fi' >/dev/null 2>&1 < /dev/null & sleep 1; echo control listener up"
	capture_start "${PCAP_CTRL}" "${CTRL_PORT}" "control"
	# the framing magic bytes 50 4c 59 4e are the ascii PLYN and the id marker
	# bytes 4e 41 59 4c 41 4d 50 21 are the ascii NAYLAMP!, so the same two byte
	# runs the encrypted search looks for are sent here in the clear as plain text.
	run_on "${CAPTURE_HOST}" "printf 'PLYNNAYLAMP!' | nc -w 3 127.0.0.1 ${CTRL_PORT} || true; echo marker sent"
	sleep 2
	capture_stop "${PCAP_CTRL}"

	if pcap_has_hex "${PCAP_CTRL}" "${FRAME_MAGIC}" && pcap_has_hex "${PCAP_CTRL}" "${MARKER_ID_HEX_LE}"; then
		pass "T4.3 control: the method found both the framing magic and the id marker in the cleartext channel"
	else
		fail "T4.3 control: the method did NOT find the marker in a known cleartext channel; either the capture is blind or nc is an incompatible variant"
	fi
	end_check T4.3
	if [ "$(verdict_of T4.3)" != pass ]; then
		stop "T4.3 control failed; the T4.2 verdict is withheld because the search method is unproven"
	fi

	note "T4.2 verdict: search the encrypted capture"
	begin_check
	if [ "${packets}" -eq 0 ]; then
		fail "T4.2 no packets captured on the raft port; the absence of a marker is vacuous"
	fi
	local magic_rc=0
	pcap_has_hex "${PCAP_ENC}" "${FRAME_MAGIC}" || magic_rc=$?
	case "${magic_rc}" in
		0) fail "T4.2 the framing magic ${FRAME_MAGIC} appears in the clear on the raft port (re-run to rule out a rare ciphertext coincidence before concluding a real leak)" ;;
		1) pass "T4.2 the framing magic ${FRAME_MAGIC} is absent from the raft port capture" ;;
		*) fail "T4.2 could not search the capture for the framing magic (an ssh or tool error); the result is inconclusive, not a pass" ;;
	esac
	if [ "${wrote_ok}" -eq 1 ]; then
		local id_rc=0
		pcap_has_hex "${PCAP_ENC}" "${MARKER_ID_HEX_LE}" || id_rc=$?
		case "${id_rc}" in
			0) fail "T4.2 the id marker ${MARKER_ID_HEX_LE} appears in the clear on the raft port (payload leak)" ;;
			1) note "T4.2 the id marker ${MARKER_ID_HEX_LE} is also absent, which corroborates the framing magic result" ;;
			*) note "T4.2 could not search for the id marker (ssh or tool error); the framing magic result stands as the verdict" ;;
		esac
	fi
	end_check T4.2
}

# t44_handshake: a fresh connection between hosts negotiates TLS 1.3.
t44_handshake() {
	note "T4.4 confirm TLS 1.3 on a fresh connection between hosts"
	begin_check
	local out
	out="$(sclient certs/node-90.pem certs/node-90-key.pem)"
	printf '%s\n' "${out}" | grep -E 'Protocol|Cipher|Verify return code' || true
	if printf '%s' "${out}" | grep -q 'TLSv1.3' && printf '%s' "${out}" | grep -q 'Verify return code: 0 (ok)'; then
		pass "T4.4 the connection negotiated TLS 1.3 with a verified peer"
	else
		fail "T4.4 could not confirm a verified TLS 1.3 handshake"
	fi
	end_check T4.4
}

teardown

cmd="${1:-all}"
case "$cmd" in
	peer)
		EXPECTED="T4.1"
		require_tools 1
		t41_peer
		COMPLETED=1
		;;
	encrypt)
		EXPECTED="T4.2 T4.3"
		require_tools "${CAPTURE_HOST}"
		require_tools 1
		t42_t43_encrypt
		COMPLETED=1
		;;
	handshake)
		EXPECTED="T4.4"
		require_tools 1
		t44_handshake
		COMPLETED=1
		;;
	all)
		EXPECTED="T4.1 T4.2 T4.3 T4.4"
		require_tools 1
		require_tools "${CAPTURE_HOST}"
		t41_peer
		t42_t43_encrypt
		t44_handshake
		COMPLETED=1
		;;
	*)
		echo "usage: tls.sh <all|peer|encrypt|handshake>" >&2
		exit 2
		;;
esac
