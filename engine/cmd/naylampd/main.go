// Command naylampd runs one process of a Naylamp deployment: a replicated node
// or a one-shot routing client. Unlike the demo in cmd/naylamp, it is built to
// be operated rather than explored: the TLS material comes only from the
// environment, so a deployment has exactly one channel for the secret, and the
// client runs a single operation and exits with a status code rather than
// dropping into an interactive REPL. Correctness itself lives in the seeded
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
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: naylampd <command> [flags]")
	fmt.Fprintln(os.Stderr, "commands:")
	fmt.Fprintln(os.Stderr, "  node    run one replica of a shard group until a signal stops it")
	fmt.Fprintln(os.Stderr, "  client  run one routing operation and exit")
	fmt.Fprintln(os.Stderr, "the mutual TLS material is read from the environment, never from flags:")
	fmt.Fprintln(os.Stderr, "  NAYLAMP_TLS_CERT  this process's certificate PEM file")
	fmt.Fprintln(os.Stderr, "  NAYLAMP_TLS_KEY   this process's private key PEM file")
	fmt.Fprintln(os.Stderr, "  NAYLAMP_TLS_CA    the CA certificate PEM file to trust")
	fmt.Fprintln(os.Stderr, "run 'naylampd <command> -h' for a command's flags")
}

// nodeAddr binds a node id to the address it is dialed at, parsed from the
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
		if id == 0 {
			return nil, fmt.Errorf("entry %q uses the reserved node id 0", part)
		}
		addr := strings.TrimSpace(kv[1])
		if addr == "" {
			return nil, fmt.Errorf("entry %q has an empty address", part)
		}
		out = append(out, nodeAddr{id: cluster.NodeID(id), addr: addr})
	}
	return out, nil
}

// tlsMaterialFromEnv loads the transport TLS material from the three required
// environment variables, failing loudly and naming the first missing one. This
// is the only source of TLS material for naylampd: there are no TLS flags, so a
// deployment provides the certificate, key, and CA exactly one way. The demo in
// cmd/naylamp takes them as flags instead; this is the production boundary.
func tlsMaterialFromEnv() (cluster.TLSMaterial, error) {
	cert := os.Getenv("NAYLAMP_TLS_CERT")
	key := os.Getenv("NAYLAMP_TLS_KEY")
	ca := os.Getenv("NAYLAMP_TLS_CA")
	for _, v := range []struct{ name, val string }{
		{"NAYLAMP_TLS_CERT", cert},
		{"NAYLAMP_TLS_KEY", key},
		{"NAYLAMP_TLS_CA", ca},
	} {
		if v.val == "" {
			return cluster.TLSMaterial{}, fmt.Errorf("%s is required; naylampd reads its TLS material from the environment, not flags", v.name)
		}
	}
	return cluster.LoadTLSMaterial(cert, key, ca)
}
