// Command naylamp runs one process of the demo cluster: a replicated node or
// the routing client. It is a hands-on way to see the pieces of Subphase 3.4
// on real sockets and real processes; correctness itself lives in the seeded
// simulation, never here.
package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"naylamp/engine/cluster"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	switch os.Args[1] {
	case "node":
		runNode(os.Args[2:])
	case "client":
		runClient(os.Args[2:])
	case "gencerts":
		runGencerts(os.Args[2:])
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: naylamp <command> [flags]")
	fmt.Fprintln(os.Stderr, "commands:")
	fmt.Fprintln(os.Stderr, "  gencerts  write a demo CA and per-node certificates to a directory")
	fmt.Fprintln(os.Stderr, "  node      run one replica of a shard group")
	fmt.Fprintln(os.Stderr, "  client    run the routing client REPL")
	fmt.Fprintln(os.Stderr, "run 'naylamp <command> -h' for a command's flags")
	fmt.Fprintln(os.Stderr, "every node and client dials over mutual TLS, so run gencerts first")
}

// nodeAddr binds a node id to the address it is dialed at, as parsed from the
// id=addr entries a node's -peers or the client's -group flags carry.
type nodeAddr struct {
	id   cluster.NodeID
	addr string
}

// parseNodeList parses a comma-separated list of id=addr entries. An empty
// string is a valid empty list, which is how a single-node group is spelled.
func parseNodeList(s string) ([]nodeAddr, error) {
	var out []nodeAddr
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, "=", 2)
		if len(kv) != 2 {
			return nil, fmt.Errorf("entry %q is not id=addr", part)
		}
		id, err := strconv.ParseUint(strings.TrimSpace(kv[0]), 10, 64)
		if err != nil {
			return nil, fmt.Errorf("entry %q has a bad id: %w", part, err)
		}
		addr := strings.TrimSpace(kv[1])
		if addr == "" {
			return nil, fmt.Errorf("entry %q has an empty address", part)
		}
		out = append(out, nodeAddr{id: cluster.NodeID(id), addr: addr})
	}
	return out, nil
}
