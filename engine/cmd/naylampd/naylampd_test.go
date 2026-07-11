package main

import (
	"bytes"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"naylamp/engine/cluster/tlstest"
)

// TestNaylampd_QuorumOverLoopback is the CI-verifiable DONE of Subphase 4.4:
// three naylampd node processes on loopback authenticate each other with mutual
// TLS, elect a leader, and commit a write that a fourth invocation reads back.
// It is deliberately a multi-process test, not an in-process one, so it proves
// the real binary loads its TLS material from the environment, dials peers by
// certificate identity, and forms quorum without any of the demo scaffolding.
//
// The child binary is built with a plain go build, without -race: the -race on
// this test instruments the orchestrator process, not the children, and the
// race authority for the cluster logic is the seeded DST, not this end-to-end
// wiring check. Instrumenting the children would need a -race build and would
// not add coverage this test is responsible for.
func TestNaylampd_QuorumOverLoopback(t *testing.T) {
	if testing.Short() {
		t.Skip("multi-process integration test: builds and spawns naylampd, skipped under -short")
	}

	bin := filepath.Join(t.TempDir(), "naylampd")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil { //nolint:gosec // building the package under test with the go toolchain, a fixed command
		t.Fatalf("build naylampd: %v\n%s", err, out)
	}

	// One CA issues certificates for the three nodes and the client, each with
	// its node id as the common name, written to disk exactly as a deployment
	// would provision them. The material is generated straight through tlstest,
	// not by shelling out to the demo's gencerts, so the test owns its inputs.
	ca, err := tlstest.NewCA()
	if err != nil {
		t.Fatalf("new ca: %v", err)
	}
	certDir := t.TempDir()
	if werr := ca.WritePEM(certDir, 1, 2, 3, uint64(clientID)); werr != nil {
		t.Fatalf("write certs: %v", werr)
	}
	tlsEnv := func(id uint64) []string {
		return append(os.Environ(),
			"NAYLAMP_TLS_CERT="+filepath.Join(certDir, fmt.Sprintf("node-%d.pem", id)),
			"NAYLAMP_TLS_KEY="+filepath.Join(certDir, fmt.Sprintf("node-%d-key.pem", id)),
			"NAYLAMP_TLS_CA="+filepath.Join(certDir, "ca.pem"),
		)
	}

	// Four pre-assigned loopback ports: three nodes and the client. Each is
	// reserved by binding an ephemeral port and releasing it, then handed to a
	// child. There is a TOCTOU gap between release and the child binding the same
	// port; on a loopback test host with no competing binders it is not observed,
	// and it is the standard way to give a child a concrete address it must be
	// dialable by before it starts, since peers are wired at launch.
	nodeAddrs := []string{freePort(t), freePort(t), freePort(t)}
	clientAddr := freePort(t)

	dataDir := t.TempDir()
	nodeIDs := []uint64{1, 2, 3}
	bufs := make([]*safeBuf, len(nodeIDs))
	cmds := make([]*exec.Cmd, len(nodeIDs))
	for i, id := range nodeIDs {
		peers := make([]string, 0, len(nodeIDs)-1)
		for j, other := range nodeIDs {
			if other == id {
				continue
			}
			peers = append(peers, fmt.Sprintf("%d=%s", other, nodeAddrs[j]))
		}
		buf := &safeBuf{}
		cmd := exec.Command(bin, "node", //nolint:gosec // bin is the binary under test built into a temp dir; every arg is test-controlled
			"-id", strconv.FormatUint(id, 10),
			"-listen", nodeAddrs[i],
			"-peers", strings.Join(peers, ","),
			"-client", fmt.Sprintf("%d=%s", clientID, clientAddr),
			"-dir", filepath.Join(dataDir, fmt.Sprintf("n%d", id)),
			"-tick", "5ms",
		)
		cmd.Env = tlsEnv(id)
		cmd.Stderr = buf
		if serr := cmd.Start(); serr != nil {
			t.Fatalf("start node %d: %v", id, serr)
		}
		bufs[i] = buf
		cmds[i] = cmd
	}

	t.Cleanup(func() {
		stopAll(cmds)
		if t.Failed() {
			for i, b := range bufs {
				t.Logf("--- node %d stderr ---\n%s", nodeIDs[i], b.String())
			}
		}
	})

	// Best-effort readiness: wait for any node to report a nonzero leader before
	// driving the client. If it never appears the client still runs with its own
	// generous deadline and a failure dumps every node's stderr for diagnosis.
	if !waitForLeader(bufs, 15*time.Second) {
		t.Logf("no leader reported within the readiness window; running the client anyway")
	}

	group := fmt.Sprintf("1=%s,2=%s,3=%s", nodeAddrs[0], nodeAddrs[1], nodeAddrs[2])
	const vecArg = "1,0,0"
	const vecID = "7"

	// Put a known vector: read-your-writes starts with a committed write, which
	// demands a leader and a majority to replicate it.
	putOut, putErr, perr := runNaylampdClient(t, bin, tlsEnv(uint64(clientID)),
		"-listen", clientAddr, "-group", group, "-op", "put", "-id", vecID, "-vec", vecArg, "-deadline", "20s")
	if perr != nil {
		t.Fatalf("client put failed (exit error %v)\nstdout: %s\nstderr: %s", perr, putOut, putErr)
	}
	if !strings.HasPrefix(putOut, "ok index=") {
		t.Fatalf("client put stdout was %q, want an ok index= line", putOut)
	}

	// Search the same vector: an OK result that names the written id proves the
	// write was committed to a majority and is served back, which is quorum
	// observed end to end across processes.
	searchOut, searchErr, serr := runNaylampdClient(t, bin, tlsEnv(uint64(clientID)),
		"-listen", clientAddr, "-group", group, "-op", "search", "-vec", vecArg, "-k", "3", "-deadline", "20s")
	if serr != nil {
		t.Fatalf("client search failed (exit error %v)\nstdout: %s\nstderr: %s", serr, searchOut, searchErr)
	}
	if !strings.Contains(searchOut, "id="+vecID) {
		t.Fatalf("client search stdout was %q, want it to contain id=%s (read-your-writes)", searchOut, vecID)
	}
}

// runNaylampdClient runs one client invocation to completion and returns its
// stdout, stderr, and the run error (non-nil on a nonzero exit).
func runNaylampdClient(t *testing.T, bin string, env []string, args ...string) (string, string, error) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	cmd := exec.Command(bin, append([]string{"client"}, args...)...) //nolint:gosec // bin is the binary under test built into a temp dir; args are test-controlled
	cmd.Env = env
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return strings.TrimSpace(stdout.String()), strings.TrimSpace(stderr.String()), err
}

// waitForLeader polls the captured node stderr until one reports a nonzero
// leader id (role log line leader=N with N >= 1) or the timeout elapses.
func waitForLeader(bufs []*safeBuf, timeout time.Duration) bool {
	leaderRe := regexp.MustCompile(`leader=[1-9]`)
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, b := range bufs {
			if leaderRe.MatchString(b.String()) {
				return true
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

// stopAll signals every node to shut down gracefully, then waits a bounded time
// for each, killing any that does not exit in time.
func stopAll(cmds []*exec.Cmd) {
	for _, c := range cmds {
		if c.Process != nil {
			_ = c.Process.Signal(syscall.SIGTERM)
		}
	}
	for _, c := range cmds {
		done := make(chan struct{})
		go func(c *exec.Cmd) { _ = c.Wait(); close(done) }(c)
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = c.Process.Kill()
			<-done
		}
	}
}

// freePort reserves a loopback port by binding an ephemeral one and releasing
// it, returning the address for a child to bind. See the TOCTOU note at the call
// site.
func freePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("reserve port: %v", err)
	}
	addr := ln.Addr().String()
	if cerr := ln.Close(); cerr != nil {
		t.Fatalf("release port: %v", cerr)
	}
	return addr
}

// safeBuf is a concurrency-safe byte sink for a child's stderr, written by the
// exec pump goroutine and read by the readiness poll and the failure dump.
type safeBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *safeBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *safeBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}
