package cluster

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"naylamp/engine/persist"
)

// TCPTransport is the real-network adapter behind the same Transport contract
// SimNet implements: at-most-once, unordered, opaque payloads. Every payload is
// wrapped in the persist CRC block format before touching the socket, so bytes
// on the wire carry the same integrity guarantees as bytes on disk, and the
// block framing doubles as the message delimiter over the stream. Every
// connection is mutual TLS: a peer's identity is the common name of its verified
// certificate, never a self-declared value, so a node cannot claim an identity
// it does not hold a signed certificate for. There is no plaintext mode.
//
// Send never touches a socket. It copies the frame onto a bounded per-peer
// outbox drained by one writer goroutine that owns every socket operation for
// that peer, dial, write and close, so the documented Transport contract,
// "Send queues data for delivery", holds literally here. A failed dial or
// write costs exactly the frame that provoked it and the next frame redials;
// retries belong to the protocol above, never to the transport.
type TCPTransport struct {
	self NodeID
	h    Handler
	ln   net.Listener

	// cert and ca are the TLS material, set once at construction and never
	// mutated: cert is presented to peers as both server and client credential,
	// and ca is the authority a peer's certificate must chain to.
	cert tls.Certificate
	ca   *x509.CertPool

	mu       sync.Mutex
	peers    map[NodeID]string
	outboxes map[NodeID]*peerOutbox
	inbound  map[net.Conn]bool
	closed   bool
	wg       sync.WaitGroup

	// timeout bounds the I/O of an already connected socket, guarded by mu: a read
	// waiting for the next frame, a write draining a frame, and the handshake of
	// an inbound connection the accept loop is admitting. Set well above any
	// heartbeat interval so a healthy link never trips it, yet a hung peer is
	// dropped within it instead of blocking forever. A read that expires mid-frame
	// ends the whole connection, so the CRC framing is never left half-consumed.
	//
	// dialTimeout bounds only the connect plus handshake of a NEW outbound link,
	// guarded by the same mu. It is a separate, much shorter budget than timeout
	// because a dial is where a dead or partitioned peer is discovered, and that
	// discovery must not monopolize the peer's writer for the whole socket
	// timeout per attempt: see defaultDialTimeout.
	timeout     time.Duration
	dialTimeout time.Duration
}

// peerOutbox is one peer's outbound lane: a bounded frame queue drained by a
// single writer goroutine that owns every socket operation toward that peer.
// Send only enqueues, so no caller ever waits on another node's socket, and
// the single writer preserves the per-peer FIFO the old link mutex used to
// provide. ctx is the writer's stop signal: Close cancels it, which aborts an
// in-flight dial immediately and tells the drain loop to exit. conn is the
// live connection, published under its own mutex so Close can sever it from
// outside and unblock a writer parked inside a kernel write.
type peerOutbox struct {
	ch     chan []byte
	ctx    context.Context
	cancel context.CancelFunc

	mu   sync.Mutex
	conn *tls.Conn
}

// outboxCapacity bounds one peer's outbox, in frames. The queue exists to
// absorb short hiccups, a redial or a briefly slow peer, without unbounded
// memory; a peer stalled for longer legitimately loses frames, because the
// transport is at-most-once and everything above it already retransmits: raft
// re-offers entries every heartbeat interval and the router re-emits
// unanswered client attempts. Sizing: consensus traffic toward one peer is one
// or two small frames per 10ms production tick (heartbeats every 20ms), so 32
// slots absorb several hundred milliseconds of full-rate traffic, well past a
// healthy redial, while a black-holed peer overflows it quickly with frames
// that are stale by construction. Worst-case memory is capacity times the
// largest frame: the envelope layer admits 16MiB (maxMessagePayload), which
// bounds one outbox at 512MiB, and that ceiling is reachable, not
// hypothetical. Snapshot transfers chunk at 64KiB, but buildAppend in the
// raft core does not cap a batch, so one MsgApp toward a follower that fell
// far behind legally carries the follower's entire gap, right up to the
// envelope limit. In practice frames stay small, heartbeats and short append
// batches, so the steady-state cost is kilobytes per peer; the bound to plan
// against is still the theoretical one. The remediation is a batch cap in
// the raft core, recorded as deferred work, not a different queue length
// here.
const outboxCapacity = 32

// newPeerOutbox builds an idle outbox; the caller starts its writer.
func newPeerOutbox() *peerOutbox {
	ctx, cancel := context.WithCancel(context.Background())
	return &peerOutbox{ch: make(chan []byte, outboxCapacity), ctx: ctx, cancel: cancel}
}

// publish records the live connection so Close can sever it from outside.
func (ob *peerOutbox) publish(c *tls.Conn) {
	ob.mu.Lock()
	ob.conn = c
	ob.mu.Unlock()
}

// current returns the live connection, or nil when the writer must redial.
func (ob *peerOutbox) current() *tls.Conn {
	ob.mu.Lock()
	defer ob.mu.Unlock()
	return ob.conn
}

// closeConn severs the current connection, if any, at the RAW socket layer,
// deliberately skipping the TLS close_notify alert: crypto/tls Close writes
// that alert under a hardcoded 5 second budget, so against the full pipe of a
// peer that stopped draining it parks the closer for those 5 seconds on top of
// the already expired write deadline. Every close on this path is the abort of
// a failed or dying link, never the graceful end of a stream, and the CRC
// block framing already makes a truncated frame fail loudly on the reader,
// which drops the connection and lets the peer redial: nothing close_notify
// protects survives this transport anyway. Closing the raw socket also
// unblocks a writer parked inside a kernel write immediately, which is what
// keeps Close prompt.
func (ob *peerOutbox) closeConn() {
	ob.mu.Lock()
	c := ob.conn
	ob.conn = nil
	ob.mu.Unlock()
	if c != nil {
		_ = c.NetConn().Close()
	}
}

// TLSMaterial is the certificate material a transport authenticates with. Cert
// is this node's own certificate, whose common name is the decimal node id, and
// CA is the pool a peer's certificate must chain to. A transport built without
// both refuses to start: there is no unauthenticated mode.
type TLSMaterial struct {
	Cert tls.Certificate
	CA   *x509.CertPool
}

var errTCPClosed = errors.New("cluster: tcp transport is closed")

// defaultSocketTimeout bounds a blocked socket operation. It is generous on
// purpose: a healthy consensus link carries heartbeats far more often, so a read
// never waits this long for the next frame on a live peer, while a peer that has
// gone silent, whose buffer never drains, or whose handshake stalls is dropped
// within it rather than hanging a goroutine indefinitely. A timeout is a
// legitimate at-most-once drop, not a transport error: the link is closed and
// the protocol above redials.
const defaultSocketTimeout = 30 * time.Second

// defaultDialTimeout bounds establishing a NEW outbound link, the connect plus
// the TLS handshake as a whole. It is deliberately far shorter than
// defaultSocketTimeout because the two guard different things: the socket
// timeout keeps a live but stalled link from parking its writer indefinitely,
// while the dial timeout bounds each connection attempt that writer makes.
// The asymmetry that motivates the split: a crashed process answers a connect
// with a RST, so the dial fails within a round trip and the next frame redials
// at once; a partitioned peer behind a silent DROP answers nothing, so the
// connect blocks for the whole budget. Under the per-peer outbox no caller
// ever rides a dial, but this budget stays load-bearing: it is what keeps a
// black hole from monopolizing its writer's redial cycle for the whole socket
// timeout per attempt, so the queue keeps draining, stale frames keep aging
// out, and a healed route is retried within seconds. A transport Close does
// not wait even this long: it cancels the outbox context, which aborts an
// in-flight dial immediately. Two seconds sits orders of magnitude above a
// datacenter connect and handshake, which complete in milliseconds on a
// healthy peer.
const defaultDialTimeout = 2 * time.Second

// NewTCPTransport listens on listenAddr over mutual TLS and starts accepting.
// Use ":0" for an ephemeral port and Addr() to discover it. The material is
// required: a nil CA or an empty certificate is an error, because a transport
// without authenticated identity is exactly the vulnerability this layer exists
// to remove. Peers are registered afterwards with AddPeer.
func NewTCPTransport(self NodeID, listenAddr string, h Handler, mat TLSMaterial) (*TCPTransport, error) {
	if self == None {
		return nil, errors.New("cluster: tcp self id 0 is reserved")
	}
	if h == nil {
		return nil, errors.New("cluster: tcp handler is nil")
	}
	if len(mat.Cert.Certificate) == 0 || mat.CA == nil {
		return nil, errors.New("cluster: tcp requires TLS material (a certificate and a CA); there is no plaintext mode")
	}
	serverCfg := &tls.Config{
		Certificates: []tls.Certificate{mat.Cert},
		ClientCAs:    mat.CA,
		ClientAuth:   tls.RequireAndVerifyClientCert,
		MinVersion:   tls.VersionTLS13,
	}
	rawLn, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return nil, fmt.Errorf("cluster: tcp listen: %w", err)
	}
	t := &TCPTransport{
		self:        self,
		h:           h,
		ln:          tls.NewListener(rawLn, serverCfg),
		cert:        mat.Cert,
		ca:          mat.CA,
		peers:       make(map[NodeID]string),
		outboxes:    make(map[NodeID]*peerOutbox),
		inbound:     make(map[net.Conn]bool),
		timeout:     defaultSocketTimeout,
		dialTimeout: defaultDialTimeout,
	}
	t.wg.Add(1)
	go t.acceptLoop()
	return t, nil
}

// Addr returns the bound listen address (useful with ":0").
func (t *TCPTransport) Addr() string { return t.ln.Addr().String() }

// AddPeer registers where a peer can be dialed.
func (t *TCPTransport) AddPeer(id NodeID, addr string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.peers[id] = addr
}

// socketTimeout returns the current deadline duration, read under the lock so a
// caller that does not already hold mu stays race free against an adjustment
// (the tests shorten it).
func (t *TCPTransport) socketTimeout() time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.timeout
}

// Send copies data onto the peer's outbox and returns, so the caller never
// touches a socket and never waits on one: this is the Transport contract
// taken literally, a nil error means the frame was accepted for sending, not
// that it arrived. A full outbox drops the NEW frame silently, the same
// legitimate at-most-once loss a fault-injecting fabric produces, and the
// protocol above recovers it by retransmission; dropping the newcomer rather
// than evicting keeps every already accepted frame and its order intact, and
// the queue only fills when the peer has already been stalled for longer than
// anything in it stays useful. The only errors are a closed transport and a
// peer with no registered address, both immediate. The outbox and its writer
// are created lazily on the first Send toward a peer, mirroring the old
// dial-on-demand, so AddPeer stays a pure address registration.
func (t *TCPTransport) Send(to NodeID, data []byte) error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return errTCPClosed
	}
	ob, ok := t.outboxes[to]
	if !ok {
		if _, known := t.peers[to]; !known {
			t.mu.Unlock()
			return fmt.Errorf("cluster: tcp has no address for node %d", to)
		}
		ob = newPeerOutbox()
		t.outboxes[to] = ob
		t.wg.Add(1)
		go t.runWriter(to, ob)
	}
	t.mu.Unlock()

	// The copy honors the contract that the caller may reuse its buffer the
	// moment Send returns: the old synchronous write consumed data before
	// returning, a queue must own its own bytes.
	frame := make([]byte, len(data))
	copy(frame, data)
	select {
	case ob.ch <- frame:
	default:
		// Queue full: the newest frame is the drop. Blocking here instead
		// would resurrect the exact caller stall this outbox exists to remove.
	}
	return nil
}

// runWriter is one peer's writer goroutine, the only place this transport
// touches that peer's socket: it drains the outbox in FIFO order, dialing on
// demand, so frames toward one peer never interleave and never ride a
// caller's goroutine. It exits when Close cancels the outbox context; the
// deferred closeConn releases whatever connection is live at that moment.
func (t *TCPTransport) runWriter(to NodeID, ob *peerOutbox) {
	defer t.wg.Done()
	defer ob.closeConn()
	for {
		select {
		case <-ob.ctx.Done():
			return
		case frame := <-ob.ch:
			t.writeFrame(to, ob, frame)
		}
	}
}

// writeFrame delivers one frame, establishing the link first when none is
// live. Every failure loses exactly the current frame and leaves the next one
// to redial, which is the at-most-once contract: the protocol above
// retransmits, the transport never does. A write that rides to its deadline
// still costs that wait, but it now costs ONLY this writer; the callers that
// used to park behind the link mutex keep ticking.
func (t *TCPTransport) writeFrame(to NodeID, ob *peerOutbox, frame []byte) {
	conn := ob.current()
	if conn == nil {
		c, err := t.dialPeer(ob.ctx, to)
		if err != nil {
			return // the frame is lost; the next frame redials
		}
		ob.publish(c)
		select {
		case <-ob.ctx.Done():
			// Close ran during the dial, and its sweep may have run before the
			// publish above: close the connection here rather than leak it.
			ob.closeConn()
			return
		default:
		}
		conn = c
	}
	// SetDeadline, not SetWriteDeadline: over TLS a logical write may also read
	// control records, so both directions are bounded.
	_ = conn.SetDeadline(time.Now().Add(t.socketTimeout()))
	if _, err := persist.WriteBlock(conn, persist.BlockClusterMessage, frame); err != nil {
		// The frame is lost and the link is dead: sever it so the next frame
		// dials fresh.
		ob.closeConn()
	}
}

// dialPeer establishes one outbound mutual TLS link on the writer's
// goroutine. The dial happens outside the transport lock, as it always must:
// holding the lock across it deadlocks two nodes that dial each other at the
// same instant, because each side's acceptLoop needs that lock to admit the
// inbound half of the peer's handshake. ctx is the outbox context, so a
// transport Close aborts an in-flight dial immediately instead of waiting it
// out; the dial timeout bounds the connect plus the TLS handshake as a whole,
// the same budget defaultDialTimeout documents, now enforced where all
// dialing lives. The address is read fresh under the lock so a later AddPeer
// takes effect on the next dial. clientConfig verifies the server chains to
// our CA AND that its certificate identity is the exact peer we dialed, so a
// valid but different node cannot impersonate it.
func (t *TCPTransport) dialPeer(ctx context.Context, to NodeID) (*tls.Conn, error) {
	t.mu.Lock()
	addr, ok := t.peers[to]
	dt := t.dialTimeout
	t.mu.Unlock()
	if !ok {
		return nil, fmt.Errorf("cluster: tcp has no address for node %d", to)
	}
	dctx, cancel := context.WithTimeout(ctx, dt)
	defer cancel()
	d := &tls.Dialer{NetDialer: &net.Dialer{}, Config: t.clientConfig(to)}
	nc, err := d.DialContext(dctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("cluster: tcp dial node %d: %w", to, err)
	}
	tc, isTLS := nc.(*tls.Conn)
	if !isTLS {
		// tls.Dialer documents the returned connection is always *tls.Conn;
		// this guard only keeps a violated assumption loud instead of silent.
		_ = nc.Close()
		return nil, errors.New("cluster: tls dialer returned a non-TLS connection")
	}
	return tc, nil
}

// clientConfig builds the TLS config for dialing a specific peer. The default
// hostname verification is skipped because a node identity is not a DNS name;
// VerifyConnection does the full check instead: the server certificate must
// chain to our CA and its common name must be the node we dialed.
func (t *TCPTransport) clientConfig(to NodeID) *tls.Config {
	return &tls.Config{
		Certificates:       []tls.Certificate{t.cert},
		RootCAs:            t.ca,
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, //nolint:gosec // VerifyConnection below does the full chain and identity check; the default hostname check does not apply to a node id
		VerifyConnection: func(cs tls.ConnectionState) error {
			return verifyPeerIdentity(cs, t.ca, to)
		},
	}
}

// verifyPeerIdentity checks a presented certificate: it must chain to ca and its
// common name must parse to want. It replaces the default hostname verification,
// which does not apply because a node identity is not a DNS name.
func verifyPeerIdentity(cs tls.ConnectionState, ca *x509.CertPool, want NodeID) error {
	if len(cs.PeerCertificates) == 0 {
		return errors.New("cluster: tls peer presented no certificate")
	}
	leaf := cs.PeerCertificates[0]
	inter := x509.NewCertPool()
	for _, c := range cs.PeerCertificates[1:] {
		inter.AddCert(c)
	}
	if _, err := leaf.Verify(x509.VerifyOptions{Roots: ca, Intermediates: inter}); err != nil {
		return fmt.Errorf("cluster: tls peer certificate not signed by the trusted CA: %w", err)
	}
	got, err := nodeIDFromCN(leaf.Subject.CommonName)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf("cluster: tls peer identity is node %d, expected node %d", got, want)
	}
	return nil
}

// nodeIDFromCN parses a certificate common name into a node id. The common name
// is the decimal node id, so a peer's identity is exactly what its signed
// certificate carries.
func nodeIDFromCN(cn string) (NodeID, error) {
	v, err := strconv.ParseUint(cn, 10, 64)
	if err != nil {
		return None, fmt.Errorf("cluster: certificate common name %q is not a node id: %w", cn, err)
	}
	id := NodeID(v)
	if id == None {
		return None, errors.New("cluster: certificate common name is the reserved node id 0")
	}
	return id, nil
}

// acceptLoop admits inbound connections until the listener closes.
func (t *TCPTransport) acceptLoop() {
	defer t.wg.Done()
	for {
		conn, err := t.ln.Accept()
		if err != nil {
			return
		}
		t.mu.Lock()
		if t.closed {
			t.mu.Unlock()
			_ = conn.Close()
			return
		}
		t.inbound[conn] = true
		t.wg.Add(1)
		t.mu.Unlock()
		go t.readLoop(conn)
	}
}

// readLoop completes the TLS handshake, takes the peer's identity from its
// verified certificate, then feeds every valid frame to the handler under that
// identity. The server config required and verified the client certificate
// against the CA, so the identity here is authenticated, not declared. Any
// handshake or framing error ends the connection: the peer will redial and
// whatever was in flight is lost (at-most-once).
func (t *TCPTransport) readLoop(conn net.Conn) {
	defer t.wg.Done()
	defer func() {
		t.mu.Lock()
		delete(t.inbound, conn)
		t.mu.Unlock()
		_ = conn.Close()
	}()

	tlsConn, ok := conn.(*tls.Conn)
	if !ok {
		return // the listener is a TLS listener, so this cannot happen
	}
	// Bound the handshake by the deadline in both directions, then read the
	// identity from the verified peer certificate.
	_ = conn.SetDeadline(time.Now().Add(t.socketTimeout()))
	if err := tlsConn.Handshake(); err != nil {
		return
	}
	cs := tlsConn.ConnectionState()
	if len(cs.PeerCertificates) == 0 {
		return
	}
	from, err := nodeIDFromCN(cs.PeerCertificates[0].Subject.CommonName)
	if err != nil {
		return
	}

	for {
		_ = conn.SetDeadline(time.Now().Add(t.socketTimeout()))
		typ, payload, rerr := persist.ReadBlock(conn)
		if rerr != nil || typ != persist.BlockClusterMessage {
			return
		}
		t.mu.Lock()
		closed := t.closed
		t.mu.Unlock()
		if closed {
			return
		}
		t.h(from, payload)
	}
}

// Close stops the listener, tells every writer to stop, severs every
// connection and waits for all the loops to exit. The order inside the sweep
// matters: the cancel aborts a writer parked in a dial at once, and the raw
// connection close unblocks a writer parked in a kernel write, so the final
// join cannot hang behind a stalled peer, a black-hole dial, or the 5 second
// close_notify budget the closeConn comment explains.
func (t *TCPTransport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	_ = t.ln.Close()
	for _, ob := range t.outboxes {
		ob.cancel()
		ob.closeConn()
	}
	t.outboxes = make(map[NodeID]*peerOutbox)
	for c := range t.inbound {
		_ = c.Close()
	}
	t.mu.Unlock()
	t.wg.Wait()
	return nil
}
