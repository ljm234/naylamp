#!/usr/bin/env bash
# cluster.sh: start, stop, and inspect the three node cluster over ssh.
# Usage: cluster.sh <start|stop|status|start-node N|stop-node N>
#
# Each node runs naylampd with its TLS material from the environment, listening
# on its private ip, dialing its two peers, and dialing the client (id 90) back
# on host 1. start-node and stop-node act on a single host, which the runbook
# needs to relaunch a killed node and to relocate leadership off host 1.
#
# NAYLAMP_GATE_NODE_FLAGS, if set, is appended verbatim to every node's naylampd
# command line, the way the service-health gate arms -service-health on the whole
# fleet. Unset or empty, the launch line is byte-for-byte the historical one, so an
# ordinary start is unchanged.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

launch_node() {
	local n="$1" peers="" j listen client extra
	for j in "${NODE_IDS[@]}"; do
		if [ "$j" != "$n" ]; then
			[ -n "$peers" ] && peers="${peers},"
			peers="${peers}${j}=${PRIV[$j]}:${NODE_PORT}"
		fi
	done
	listen="${PRIV[$n]}:${NODE_PORT}"
	client="${CLIENT_ID}=${PRIV[1]}:${CLIENT_PORT}"
	# Extra flags carry a leading space only when present, so an empty variable
	# leaves the command line exactly as it has always been.
	extra="${NAYLAMP_GATE_NODE_FLAGS:-}"
	[ -n "${extra}" ] && extra=" ${extra}"
	echo "gate: starting node ${n} on ${HOSTS[$n]} (listen ${listen}, peers ${peers}, client ${client})${extra:+, extra flags${extra}}"
	# nohup detaches the node; stdin from /dev/null and output to the log free the
	# ssh channel so this returns. The pid is recorded for kill and stop.
	#
	# The log is APPENDED to, not truncated. A truncating redirect loses the role
	# and term history of the node being relaunched, and relaunching is exactly
	# what the failure scenarios do: a killed leader is reintegrated, and a
	# leadership redraw restarts all three. That history is the only record of
	# which node held office at which term, so a gate that reads it after the fact
	# would be auditing a log the gate itself had erased. Appending costs the
	# readers nothing. They come in three shapes and each survives: one takes the
	# last role line, which is still the current one because a relaunched node
	# prints its role before anything else; one compares a count against a
	# baseline it captured earlier in the same run, which a shared older prefix
	# cancels out of; and one reads the whole file to collect the terms office was
	# claimed at, which is the reader this change exists for and which needs the
	# log and the data directory to be cleared together so terms and history share
	# one epoch.
	# Growth is bounded by whatever clears logs/. The gates that wipe do so
	# already; the ones that do not also keep their data dirs across sessions by
	# design, so the reset is the operator's, as it always was for the data.
	run_on "$n" "cd naylamp || exit 1; NAYLAMP_TLS_CERT=certs/node-${n}.pem NAYLAMP_TLS_KEY=certs/node-${n}-key.pem NAYLAMP_TLS_CA=certs/ca.pem nohup ./bin/naylampd node -id ${n} -listen ${listen} -peers ${peers} -client ${client} -dir data -tick 10ms${extra} >> logs/node.log 2>&1 < /dev/null & echo \$! > naylampd.pid; sleep 1; echo node ${n} pid \$(cat naylampd.pid)"
}

stop_node() {
	local n="$1"
	echo "gate: stopping node ${n} on ${HOSTS[$n]}"
	run_on "$n" 'if [ -f naylamp/naylampd.pid ]; then pid=$(cat naylamp/naylampd.pid); kill -TERM "$pid" 2>/dev/null || true; for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done; if kill -0 "$pid" 2>/dev/null; then echo "node still running (pid $pid)"; else echo "node stopped (pid $pid)"; fi; else echo "no pidfile on this host"; fi'
}

status_node() {
	local n="$1"
	printf 'node %s (%s): ' "$n" "${HOSTS[$n]}"
	run_on "$n" 'grep -E "role=" naylamp/logs/node.log 2>/dev/null | tail -1 || echo "no role line yet"'
}

cmd="${1:-}"
case "$cmd" in
	start)
		for n in "${NODE_IDS[@]}"; do launch_node "$n"; done
		echo "gate: all nodes launched; run cluster.sh status until a leader appears"
		;;
	stop)
		for n in "${NODE_IDS[@]}"; do stop_node "$n"; done
		;;
	status)
		for n in "${NODE_IDS[@]}"; do status_node "$n"; done
		;;
	start-node)
		launch_node "${2:?gate: start-node needs a node id}"
		;;
	stop-node)
		stop_node "${2:?gate: stop-node needs a node id}"
		;;
	*)
		echo "usage: cluster.sh <start|stop|status|start-node N|stop-node N>" >&2
		exit 2
		;;
esac
