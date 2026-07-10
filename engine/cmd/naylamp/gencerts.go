package main

import (
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"naylamp/engine/cluster/tlstest"
)

// runGencerts writes a demo certificate authority and one certificate and key
// pair per node id to a directory, the material the node and client commands
// load through their -tls-cert, -tls-key, and -tls-ca flags. It is a
// convenience for the hands-on demo only: a real deployment provisions
// certificates from a real authority, never from this command.
func runGencerts(args []string) {
	fs := flag.NewFlagSet("gencerts", flag.ExitOnError)
	var dir, ids string
	fs.StringVar(&dir, "dir", "", "directory to write ca.pem and per-node certificates into (required)")
	fs.StringVar(&ids, "ids", "", "node ids to issue certificates for, comma separated, e.g. 1,2,3,90 (required)")
	_ = fs.Parse(args)

	if dir == "" || ids == "" {
		fmt.Fprintln(os.Stderr, "gencerts: -dir and -ids are required")
		fs.Usage()
		os.Exit(2)
	}

	parsed, err := parseIDs(ids)
	if err != nil {
		log.Fatalf("gencerts: bad -ids: %v", err)
	}

	ca, err := tlstest.NewCA()
	if err != nil {
		log.Fatalf("gencerts: new ca: %v", err)
	}
	if werr := ca.WritePEM(dir, parsed...); werr != nil {
		log.Fatalf("gencerts: write: %v", werr)
	}

	fmt.Printf("wrote %s\n", filepath.Join(dir, "ca.pem"))
	for _, id := range parsed {
		fmt.Printf("wrote %s and %s (node %d)\n",
			filepath.Join(dir, fmt.Sprintf("node-%d.pem", id)),
			filepath.Join(dir, fmt.Sprintf("node-%d-key.pem", id)),
			id)
	}
	fmt.Printf("run a node with -tls-cert %s -tls-key %s -tls-ca %s\n",
		filepath.Join(dir, "node-<id>.pem"),
		filepath.Join(dir, "node-<id>-key.pem"),
		filepath.Join(dir, "ca.pem"))
}

// parseIDs parses a comma separated list of unsigned node ids, skipping empty
// entries and rejecting the reserved id 0.
func parseIDs(s string) ([]uint64, error) {
	fields := strings.Split(s, ",")
	ids := make([]uint64, 0, len(fields))
	for _, f := range fields {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		id, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("%q is not a node id: %w", f, err)
		}
		if id == 0 {
			return nil, errors.New("node id 0 is reserved")
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return nil, errors.New("no ids given")
	}
	return ids, nil
}
