package cluster

import (
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
// it does not hold a signed certificate for. There is no plaintext mode. A
// failed write drops the connection and returns an error; retries belong to the
// protocol above, never to the transport.
type TCPTransport struct {
	self NodeID
	h    Handler
	ln   net.Listener

	// cert and ca are the TLS material, set once at construction and never
	// mutated: cert is presented to peers as both server and client credential,
	// and ca is the authority a peer's certificate must chain to.
	cert tls.Certificate
	ca   *x509.CertPool

	mu      sync.Mutex
	peers   map[NodeID]string
	links   map[NodeID]*peerLink
	inbound map[net.Conn]bool
	closed  bool
	wg      sync.WaitGroup

	// timeout bounds every socket operation, guarded by mu: the TLS handshake, a
	// read waiting for the next frame, and a write draining a frame. Set well
	// above any heartbeat interval so a healthy link never trips it, yet a hung
	// peer is dropped within it instead of blocking forever. A read that expires
	// mid-frame ends the whole connection, so the CRC framing is never left
	// half-consumed.
	timeout time.Duration
}

// peerLink is one live outbound connection. Its mutex serializes writes so
// concurrent Sends to the same peer never interleave frames.
type peerLink struct {
	mu   sync.Mutex
	conn net.Conn
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
		self:    self,
		h:       h,
		ln:      tls.NewListener(rawLn, serverCfg),
		cert:    mat.Cert,
		ca:      mat.CA,
		peers:   make(map[NodeID]string),
		links:   make(map[NodeID]*peerLink),
		inbound: make(map[net.Conn]bool),
		timeout: defaultSocketTimeout,
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

// Send frames data and writes it to the peer, dialing on demand. A write failure
// drops the link and surfaces the error; the message is lost, which is exactly
// the at-most-once contract.
func (t *TCPTransport) Send(to NodeID, data []byte) error {
	link, err := t.link(to)
	if err != nil {
		return err
	}
	link.mu.Lock()
	defer link.mu.Unlock()
	// SetDeadline, not SetWriteDeadline: over TLS a logical write may also read
	// control records, so both directions are bounded.
	_ = link.conn.SetDeadline(time.Now().Add(t.socketTimeout()))
	if _, werr := persist.WriteBlock(link.conn, persist.BlockClusterMessage, data); werr != nil {
		t.dropLink(to, link)
		return fmt.Errorf("cluster: tcp send to %d: %w", to, werr)
	}
	return nil
}

// link returns the live outbound connection to a peer, dialing over TLS if none
// exists. The transport lock is held across the dial and handshake: at cluster
// sizes this serialization is a simplicity win over per-peer dial races and
// guarantees exactly one connection per peer. The client config verifies the
// server chains to our CA AND that its certificate identity is the exact peer we
// dialed, so a valid but different node cannot impersonate to.
func (t *TCPTransport) link(to NodeID) (*peerLink, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return nil, errTCPClosed
	}
	if l, ok := t.links[to]; ok {
		return l, nil
	}
	addr, ok := t.peers[to]
	if !ok {
		return nil, fmt.Errorf("cluster: tcp has no address for node %d", to)
	}
	dialer := &net.Dialer{Timeout: t.timeout}
	conn, err := tls.DialWithDialer(dialer, "tcp", addr, t.clientConfig(to))
	if err != nil {
		return nil, fmt.Errorf("cluster: tcp dial node %d: %w", to, err)
	}
	l := &peerLink{conn: conn}
	t.links[to] = l
	return l, nil
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

// dropLink closes and forgets an outbound connection if it is still current.
func (t *TCPTransport) dropLink(to NodeID, l *peerLink) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if cur, ok := t.links[to]; ok && cur == l {
		delete(t.links, to)
	}
	_ = l.conn.Close()
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

// Close stops the listener, closes every connection and waits for the loops.
func (t *TCPTransport) Close() error {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil
	}
	t.closed = true
	_ = t.ln.Close()
	for _, l := range t.links {
		_ = l.conn.Close()
	}
	t.links = make(map[NodeID]*peerLink)
	for c := range t.inbound {
		_ = c.Close()
	}
	t.mu.Unlock()
	t.wg.Wait()
	return nil
}
