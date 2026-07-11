#!/usr/bin/env bash
# partition.sh: isolate a node from its two peers with iptables, and heal it.
# Usage: partition.sh <apply|heal|status> N
#
# apply INSERTS the DROP rules at position 1 of INPUT and OUTPUT (-I ... 1),
# never appends (-A), so they take precedence over any pre-existing rule such as
# an ESTABLISHED ACCEPT that a default firewall may carry. It drops traffic to
# and from BOTH peers, so the node is fully isolated. heal deletes the same
# specifications with -D. Requires passwordless sudo on the host (the EC2 ubuntu
# user has it). A Security Groups alternative is described in README.md.
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
	*)
		echo "usage: partition.sh <apply|heal|status> N" >&2
		exit 2
		;;
esac
