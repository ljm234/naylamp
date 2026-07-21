#!/usr/bin/env bash
# partition.sh: isolate a node from its two peers with iptables, and heal it;
# or mute only a node's ack path to the client, and unmute it.
# Usage: partition.sh <apply|heal|status|mute|unmute> N
#
# apply INSERTS the DROP rules at position 1 of INPUT and OUTPUT (-I ... 1),
# never appends (-A), so they take precedence over any pre-existing rule such as
# an ESTABLISHED ACCEPT that a default firewall may carry. It drops traffic to
# and from BOTH peers, so the node is fully isolated. heal deletes the same
# specifications with -D. Requires passwordless sudo on the host (the EC2 ubuntu
# user has it). A Security Groups alternative is described in README.md.
#
# mute installs a single OUTPUT rule that drops only the node's replies to the
# client (destination the client ip, destination port the client
# port). The destination port is mandatory, because the client shares host 1's ip
# with node 1, so a rule by ip alone would also cut Raft to node 1; scoping to the
# client port leaves node to node Raft on 9401 untouched, so the muted node keeps
# its heartbeats and stays leader while only its ack to the client is lost. That
# is what makes the muted leader a silent target rather than a failed one. unmute
# deletes that one rule and is idempotent.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${GATE_DIR}/common.sh"

cmd="${1:-}"
n="${2:?gate: partition.sh needs an action and a node id, e.g. partition.sh apply 2}"

show_rules() {
	run_on "$n" 'sudo iptables -L INPUT -n --line-numbers; echo ---; sudo iptables -L OUTPUT -n --line-numbers'
}

apply_rules() {
	local x
	for x in "${NODE_IDS[@]}"; do
		if [ "$x" != "$n" ]; then
			echo "gate: dropping traffic between node ${n} and node ${x} (${PRIV[$x]})"
			run_on "$n" "sudo iptables -I INPUT 1 -s ${PRIV[$x]} -j DROP"
			run_on "$n" "sudo iptables -I OUTPUT 1 -d ${PRIV[$x]} -j DROP"
		fi
	done
}

heal_rules() {
	local x
	for x in "${NODE_IDS[@]}"; do
		if [ "$x" != "$n" ]; then
			echo "gate: restoring traffic between node ${n} and node ${x} (${PRIV[$x]})"
			run_on "$n" "sudo iptables -D INPUT -s ${PRIV[$x]} -j DROP"
			run_on "$n" "sudo iptables -D OUTPUT -d ${PRIV[$x]} -j DROP"
		fi
	done
}

# mute_rules drops only this node's replies to the client, and refuses node 1,
# which is co-located with the client and cannot have its ack path isolated by a
# rule aimed at the client ip.
mute_rules() {
	if [ "$n" = 1 ]; then
		echo "gate: refusing to mute node 1: it is co-located with the client on host 1, so a rule toward the client ip would also hit node 1 itself; only nodes 2 and 3 can have their ack path to the client muted" >&2
		exit 2
	fi
	echo "gate: muting node ${n} ack path to the client at ${PRIV[1]}:${CLIENT_PORT} (Raft heartbeats on ${NODE_PORT} preserved)"
	run_on "$n" "sudo iptables -I OUTPUT 1 -d ${PRIV[1]} -p tcp --dport ${CLIENT_PORT} -j DROP"
}

# unmute_rules deletes that one rule; the trailing tolerance makes it idempotent,
# so a teardown that runs when no rule is present is not an error.
unmute_rules() {
	echo "gate: unmuting node ${n} ack path to the client at ${PRIV[1]}:${CLIENT_PORT}"
	run_on "$n" "sudo iptables -D OUTPUT -d ${PRIV[1]} -p tcp --dport ${CLIENT_PORT} -j DROP 2>/dev/null || true"
}

# show_mute prints the client-ack drop rule if present, so mute and unmute can be
# verified the same way apply prints its rules.
show_mute() {
	run_on "$n" "sudo iptables -L OUTPUT -n --line-numbers | grep -E 'dpt:${CLIENT_PORT}' || echo '(no client-ack mute rule on node ${n})'"
}

case "$cmd" in
	apply)
		apply_rules
		echo "gate: iptables on node ${n} after apply:"
		show_rules
		;;
	heal)
		heal_rules
		echo "gate: iptables on node ${n} after heal:"
		show_rules
		;;
	status)
		echo "gate: iptables on node ${n}:"
		show_rules
		;;
	mute)
		mute_rules
		echo "gate: OUTPUT chain on node ${n} after mute:"
		show_mute
		;;
	unmute)
		unmute_rules
		echo "gate: OUTPUT chain on node ${n} after unmute:"
		show_mute
		;;
	*)
		echo "usage: partition.sh <apply|heal|status|mute|unmute> N" >&2
		exit 2
		;;
esac
