package cluster

import (
	"bytes"
	"crypto/tls"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"naylamp/engine/cluster/tlstest"
	"naylamp/engine/persist"
)

// mustCA builds a fresh in-memory CA for the mutual TLS tests from the shared
// tlstest package, failing the test on error. The cluster tests and the naylamp
// tests mint identity from the same generator, so the certificate convention
// the transport verifies, that a common name is the decimal node id, lives in
// exactly one place.
func mustCA(t *testing.T) *tlstest.CA {
	t.Helper()
	ca, err := tlstest.NewCA()
	if err != nil {
		t.Fatalf("test ca: %v", err)
	}
	return ca
}

// mustMaterial issues node id's certificate from ca and wraps it as the
// transport material, failing the test on error.
func mustMaterial(t *testing.T, ca *tlstest.CA, id NodeID) TLSMaterial {
	t.Helper()
	return TLSMaterial{Cert: mustNodeCert(t, ca, id), CA: ca.Pool()}
}

// mustNodeCert issues a leaf certificate for one node id, usable as both a
// server and a client credential, with the decimal node id as its common name,
// failing the test on error.
func mustNodeCert(t *testing.T, ca *tlstest.CA, id NodeID) tls.Certificate {
	t.Helper()
	cert, err := ca.NodeCert(uint64(id))
	if err != nil {
		t.Fatalf("node cert %d: %v", id, err)
	}
	return cert
}

// TestTCP_DeadlineUnblocksHungPeer proves the socket read deadline still bites
// under mutual TLS: a peer that completes the handshake with a valid certificate
// and then goes silent must not block the receiver's read loop forever. The
// receiver times the read out and closes the connection, so this test observes
// the close promptly rather than hanging. A timeout is a legitimate at-most-once
// drop, so it is not a transport error.
func TestTCP_DeadlineUnblocksHungPeer(t *testing.T) {
	ca := mustCA(t)
	recv, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {}, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("new transport: %v", err)
	}
	defer func() { _ = recv.Close() }()

	// Shorten the socket timeout so the test does not wait the generous default.
	// The field is guarded by the transport mutex.
	const timeout = 200 * time.Millisecond
	recv.mu.Lock()
	recv.timeout = timeout
	recv.mu.Unlock()

	// A hung peer: complete the mutual TLS handshake with a valid node 2
	// certificate, then send no frames.
	client := &tls.Config{
		Certificates:       []tls.Certificate{mustNodeCert(t, ca, 2)},
		RootCAs:            ca.Pool(),
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, //nolint:gosec // this test exercises only the receiver's read deadline, not server identity
	}
	conn, err := tls.Dial("tcp", recv.Addr(), client)
	if err != nil {
		t.Fatalf("tls dial: %v", err)
	}
	defer func() { _ = conn.Close() }()

	// The handshake completed on dial. Now stall. The receiver times out after
	// about timeout and closes, which this read observes well within the bound.
	// A safety deadline on our own read keeps the test from hanging if the
	// receiver never times out.
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	start := time.Now()
	if _, rerr := conn.Read(make([]byte, 1)); rerr == nil {
		t.Fatalf("expected the receiver to close the hung connection, got a successful read")
	}
	elapsed := time.Since(start)
	if elapsed > timeout+2*time.Second {
		t.Fatalf("receiver took %v to drop the hung peer, want under %v", elapsed, timeout+2*time.Second)
	}
}

// TestTCP_RejectsUnauthenticatedPeer proves the receiver admits a peer only when
// its certificate is signed by the trusted CA: a certificate from a different CA,
// and no certificate at all, are both rejected, so neither delivers a frame to
// the handler. In TLS 1.3 the client finishes its flight before the server
// verifies the client certificate, so the rejection is not a dial error; the
// test asserts the security property directly, that an unauthenticated peer's
// frame never reaches the handler.
func TestTCP_RejectsUnauthenticatedPeer(t *testing.T) {
	ca := mustCA(t)
	delivered := make(chan NodeID, 1)
	recv, err := NewTCPTransport(1, "127.0.0.1:0", func(from NodeID, _ []byte) { delivered <- from }, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("new transport: %v", err)
	}
	defer func() { _ = recv.Close() }()

	// Dial with the given config and, if the client-side handshake completes,
	// try to push a frame. A rejected peer's frame must never be delivered.
	dialAndTrySend := func(cfg *tls.Config) {
		cfg.MinVersion = tls.VersionTLS13
		cfg.InsecureSkipVerify = true //nolint:gosec // the test checks that the server rejects the client, not the reverse
		conn, derr := tls.Dial("tcp", recv.Addr(), cfg)
		if derr != nil {
			return // rejected at dial: nothing to send
		}
		defer func() { _ = conn.Close() }()
		_ = conn.SetDeadline(time.Now().Add(time.Second))
		_, _ = persist.WriteBlock(conn, persist.BlockClusterMessage, []byte("rogue frame"))
	}

	// A certificate from a different CA is not trusted by the receiver.
	rogue := mustCA(t)
	dialAndTrySend(&tls.Config{Certificates: []tls.Certificate{mustNodeCert(t, rogue, 2)}, RootCAs: rogue.Pool()})
	// No client certificate at all is rejected by RequireAndVerifyClientCert.
	dialAndTrySend(&tls.Config{RootCAs: ca.Pool()})

	select {
	case from := <-delivered:
		t.Fatalf("an unauthenticated peer was admitted: it delivered a frame attributed to node %d", from)
	case <-time.After(500 * time.Millisecond):
		// Nothing delivered: both unauthenticated peers were rejected.
	}
}

// TestTCP_TrafficIsEncrypted proves the payload never crosses the wire in the
// clear. A transparent byte-copying proxy sits in front of the receiver and
// records the client to server bytes; the sender delivers a known marker over
// mutual TLS, and the marker must not appear literally in the captured bytes.
func TestTCP_TrafficIsEncrypted(t *testing.T) {
	ca := mustCA(t)
	got := make(chan []byte, 1)
	recv, err := NewTCPTransport(2, "127.0.0.1:0", func(_ NodeID, data []byte) {
		got <- append([]byte(nil), data...)
	}, mustMaterial(t, ca, 2))
	if err != nil {
		t.Fatalf("recv transport: %v", err)
	}
	defer func() { _ = recv.Close() }()

	proxy, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("proxy listen: %v", err)
	}
	defer func() { _ = proxy.Close() }()
	var mu sync.Mutex
	var wire []byte
	go func() {
		c, aerr := proxy.Accept()
		if aerr != nil {
			return
		}
		up, derr := net.Dial("tcp", recv.Addr())
		if derr != nil {
			_ = c.Close()
			return
		}
		// client to server: tee into wire, then relay.
		go func() {
			buf := make([]byte, 4096)
			for {
				n, rerr := c.Read(buf)
				if n > 0 {
					mu.Lock()
					wire = append(wire, buf[:n]...)
					mu.Unlock()
					if _, werr := up.Write(buf[:n]); werr != nil {
						break
					}
				}
				if rerr != nil {
					break
				}
			}
			_ = up.Close()
			_ = c.Close()
		}()
		// server to client: plain relay.
		go func() {
			_, _ = io.Copy(c, up)
			_ = c.Close()
			_ = up.Close()
		}()
	}()

	sender, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {}, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("sender transport: %v", err)
	}
	defer func() { _ = sender.Close() }()
	// Dial the proxy, which relays bytes transparently to recv; the TLS session
	// is end to end between sender and recv, so the sender still verifies recv's
	// certificate identity.
	sender.AddPeer(2, proxy.Addr().String())

	marker := []byte("PLAINTEXT-MARKER-do-not-find-me-on-the-wire")
	if serr := sender.Send(2, marker); serr != nil {
		t.Fatalf("send: %v", serr)
	}

	select {
	case data := <-got:
		if string(data) != string(marker) {
			t.Fatalf("recv delivered %q, want %q", data, marker)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("timeout waiting for delivery through the proxy")
	}

	mu.Lock()
	captured := append([]byte(nil), wire...)
	mu.Unlock()
	if len(captured) == 0 {
		t.Fatalf("no bytes captured on the wire")
	}
	if bytes.Contains(captured, marker) {
		t.Fatalf("the plaintext payload appeared on the wire; traffic is not encrypted")
	}
}

// TestTCP_SimultaneousDialConverges reproduces the mutual-dial deadlock and
// proves it is fixed. Two transports dial each other at the same instant: were
// the dial held under the transport lock, each side would hold its own lock
// waiting for the peer's TLS ServerHello while the peer's acceptLoop is blocked
// on that same lock, so neither handshake would begin and both dials would hang
// until the socket timeout fired. Dialing outside the lock lets both handshakes
// proceed and both frames arrive almost immediately.
//
// The socket timeout is deliberately left at its generous default: that default
// is what makes the bound discriminating. With the fix the frames converge in
// milliseconds; with the deadlock both dials block for the full socket timeout,
// far past the bound below, so this test fails fast rather than hanging.
func TestTCP_SimultaneousDialConverges(t *testing.T) {
	ca := mustCA(t)
	got1 := make(chan NodeID, 1)
	got2 := make(chan NodeID, 1)
	t1, err := NewTCPTransport(1, "127.0.0.1:0", func(from NodeID, _ []byte) { got1 <- from }, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("transport 1: %v", err)
	}
	defer func() { _ = t1.Close() }()
	t2, err := NewTCPTransport(2, "127.0.0.1:0", func(from NodeID, _ []byte) { got2 <- from }, mustMaterial(t, ca, 2))
	if err != nil {
		t.Fatalf("transport 2: %v", err)
	}
	defer func() { _ = t2.Close() }()
	t1.AddPeer(2, t2.Addr())
	t2.AddPeer(1, t1.Addr())

	// Release both Sends at the same instant so the two dials race head-on, the
	// condition that deadlocks a lock-held dial. A send error is reported so a
	// non-deadlock failure (a refused dial) is diagnosed rather than masked.
	var ready sync.WaitGroup
	ready.Add(2)
	start := make(chan struct{})
	errc := make(chan error, 2)
	go func() {
		ready.Done()
		<-start
		if e := t1.Send(2, []byte("from 1")); e != nil {
			errc <- e
		}
	}()
	go func() {
		ready.Done()
		<-start
		if e := t2.Send(1, []byte("from 2")); e != nil {
			errc <- e
		}
	}()
	ready.Wait()
	close(start)

	// Both frames must arrive well within the bound. With the deadlock each dial
	// would block for the full default socket timeout, so this 5s bound fails
	// fast. On success the frames arrive in milliseconds.
	deadline := time.After(5 * time.Second)
	for i := 0; i < 2; i++ {
		select {
		case from := <-got1:
			if from != 2 {
				t.Fatalf("transport 1 received a frame attributed to node %d, want 2", from)
			}
		case from := <-got2:
			if from != 1 {
				t.Fatalf("transport 2 received a frame attributed to node %d, want 1", from)
			}
		case <-deadline:
			select {
			case e := <-errc:
				t.Fatalf("frames did not converge within 5s (a send failed: %v); the mutual dial may have deadlocked", e)
			default:
				t.Fatalf("frames did not converge within 5s: the mutual dial deadlocked")
			}
		}
	}
}

// TestTCPSendBoundedByDialTimeout proves a Send toward an unreachable peer
// never parks the caller. The peer address is 192.0.2.1:9, in the TEST-NET-1
// block RFC 5737 reserves for documentation and which no host routes: a
// connect there is dropped silently on the way out or answered with an
// unreachable, and never completes. Before the dial and socket timeouts were
// split, this Send blocked for the whole socket timeout; after the split it
// still rode the dial for up to dialTimeout; under the per-peer outbox it
// does not ride anything: Send copies the frame onto the outbox and returns
// nil, the accepted-for-sending half of the Transport contract, while the
// dial happens on the peer's writer goroutine, where dialTimeout still bounds
// every connection attempt and a failed dial costs exactly the frame that
// provoked it, which at-most-once permits.
//
// The assertion is a BOUND on the caller's latency, never a delivery promise:
// what it proves is that Send no longer hangs for any dial's duration, let
// alone the socket timeout, which is the regression this pin closes.
func TestTCPSendBoundedByDialTimeout(t *testing.T) {
	ca := mustCA(t)
	tr, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {}, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("new transport: %v", err)
	}
	defer func() { _ = tr.Close() }()

	// Shorten the dial timeout so the test does not wait the generous default. The
	// field is guarded by the transport mutex, the same pattern the socket-timeout
	// test uses.
	const dialTimeout = 100 * time.Millisecond
	tr.mu.Lock()
	tr.dialTimeout = dialTimeout
	tr.mu.Unlock()

	// A black hole: TEST-NET-1, reserved and unrouted, so the connect never
	// completes. Port 9 (discard) is conventional for a destination that answers
	// nothing.
	tr.AddPeer(2, "192.0.2.1:9")

	start := time.Now()
	serr := tr.Send(2, []byte("frame"))
	elapsed := time.Since(start)

	// The outbox contract: a Send toward a peer with a registered address is
	// accepted for sending, and the dial failure that follows on the writer is
	// a silent at-most-once loss, never the caller's error.
	if serr != nil {
		t.Fatalf("Send to a registered peer must be accepted for sending under the outbox contract, got %v", serr)
	}
	// The bound: comfortably under the 30s socket timeout the dial used to
	// inherit and under the dial timeout the caller used to ride; an enqueue is
	// microseconds, so 2s only guards against a regression to any blocking path
	// without flaking on a loaded CI host.
	if elapsed >= 2*time.Second {
		t.Fatalf("Send took %v, want under 2s: the caller is riding a socket wait again", elapsed)
	}
	t.Logf("Send to a black hole returned in %v", elapsed)
}

// TestTCPSendBoundedWhenPeerStopsDraining pins the caller-latency contract of
// Send: it must return to the caller promptly even when a CONNECTED peer stops
// draining, the remaining hole after the dial and socket timeouts were split.
// Send holds the peer link across the whole write with only the socket
// deadline as a bound, so once the kernel buffers between the two ends fill,
// one Send parks the calling goroutine until that deadline; on a node the
// caller is the consensus ticker or an inbound read loop, and the
// real-infrastructure gate showed a silently partitioned peer wedging exactly
// those while every other Send toward the same peer queued behind the link
// mutex. The per-peer outbox makes Send enqueue-or-drop; this test is the pin
// that flips green with it and red on any regression to a blocking send path.
//
// The physics: the receiver completes the mutual TLS handshake and its read
// loop reads exactly one frame, then parks inside the handler, so no further
// frame is ever drained and every byte after the first accumulates in the
// kernel buffers until they fill. The sender pushes up to 64 frames of 512
// KiB, 32 MiB in total, which exceeds what any loopback pair can buffer (a
// few megabytes at most on macOS and Linux), so a Send is guaranteed to hit
// full buffers within the first few dozen iterations. The 500ms bound is
// orders of magnitude above a legitimate loopback write, which is
// microseconds, and above the first Send's dial plus handshake, which is
// milliseconds, so a loaded CI host cannot trip it; yet it sits far below the
// 2s socket timeout a blocking write rides to, so the two outcomes cannot be
// confused. The observed red is in fact WORSE than the socket timeout alone:
// after the write deadline expires, dropLink closes the TLS connection, and
// crypto/tls Close overrides the expired deadline with a hardcoded 5 second
// budget to write its close_notify alert into the same full pipe, so one
// blocked Send can park the caller for up to socket timeout plus 5s when the
// alert does not fit either (with the 30s production default, up to 35s per
// expired write).
//
// The assertion is about latency alone, never about the Send result: a write
// that rides to the deadline returns an error and drops the link, while an
// outbox Send returns nil even when it must drop the frame, and both are
// legitimate under the at-most-once contract. What is not legitimate is
// parking the caller.
func TestTCPSendBoundedWhenPeerStopsDraining(t *testing.T) {
	ca := mustCA(t)

	// The receiver stops draining after one frame: the handler parks on block,
	// and the read loop, which calls it synchronously, parks with it.
	block := make(chan struct{})
	recv, err := NewTCPTransport(2, "127.0.0.1:0", func(NodeID, []byte) { <-block }, mustMaterial(t, ca, 2))
	if err != nil {
		t.Fatalf("recv transport: %v", err)
	}
	defer func() { _ = recv.Close() }()

	sender, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {}, mustMaterial(t, ca, 1))
	if err != nil {
		t.Fatalf("sender transport: %v", err)
	}
	defer func() { _ = sender.Close() }()

	// Declared after the Close defers so it runs FIRST on unwind (defers are
	// LIFO): it releases the parked handler before the Close calls join their
	// read loops, otherwise Close would wait on a read loop that is still
	// stuck inside the handler.
	defer close(block)

	// Shorten the sender's socket timeout so the expected red does not park
	// the test for the generous 30s default. The field is guarded by the
	// transport mutex, the same pattern the read-deadline test uses.
	const socketTimeout = 2 * time.Second
	sender.mu.Lock()
	sender.timeout = socketTimeout
	sender.mu.Unlock()

	sender.AddPeer(2, recv.Addr())

	// One reused payload keeps allocation out of the timing. A legitimate
	// Send either fits the buffers (microseconds) or blocks until the write
	// deadline (the full socket timeout), so the bound discriminates cleanly.
	payload := make([]byte, 512<<10)
	const bound = 500 * time.Millisecond
	var worst time.Duration
	for i := 0; i < 64; i++ {
		start := time.Now()
		_ = sender.Send(2, payload) // result ignored on purpose: the contract is the caller's latency, not delivery
		elapsed := time.Since(start)
		if elapsed > worst {
			worst = elapsed
		}
		if elapsed >= bound {
			t.Fatalf("Send %d blocked the caller for %v toward a connected peer that stopped draining; the transport must never block the caller (bound %v, socket timeout %v)",
				i+1, elapsed, bound, socketTimeout)
		}
	}
	t.Logf("64 sends of 512 KiB returned promptly (worst %v): the caller-latency contract holds", worst)
}
