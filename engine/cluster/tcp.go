package cluster

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"naylamp/engine/persist"
)

// TCPTransport is the real-network adapter behind the same Transport contract
// SimNet implements: at-most-once, unordered, opaque payloads. Every payload
// is wrapped in the persist CRC block format before touching the socket, so
// bytes on the wire carry the same integrity guarantees as bytes on disk, and
// the block framing doubles as the message delimiter over the stream. The
// first block on a dialed connection is a hello carrying the dialer's NodeID,
// which attributes every later frame on that connection to that peer. A
// failed write drops the connection and returns an error; retries belong to
// the protocol above, never to the transport.
type TCPTransport struct {
	self NodeID
	h    Handler
	ln   net.Listener

	mu      sync.Mutex
	peers   map[NodeID]string
	links   map[NodeID]*peerLink
	inbound map[net.Conn]bool
	closed  bool
	wg      sync.WaitGroup

	// timeout bounds every socket read and write, guarded by mu: a read waits at
	// most this long for the next frame, a write at most this long to drain. Set
	// well above any heartbeat interval so a healthy link never trips it, yet a
	// hung peer is dropped within it instead of blocking forever. A read that
	// expires mid-frame ends the whole connection, so the CRC framing is never
	// left half-consumed.
	timeout time.Duration
}

// peerLink is one live outbound connection. Its mutex serializes writes so
// concurrent Sends to the same peer never interleave frames.
type peerLink struct {
	mu   sync.Mutex
	conn net.Conn
}

var errTCPClosed = errors.New("cluster: tcp transport is closed")

// defaultSocketTimeout bounds a blocked socket read or write. It is generous on
// purpose: a healthy consensus link carries heartbeats far more often, so a read
// never waits this long for the next frame on a live peer, while a peer that has
// gone silent or whose buffer never drains is dropped within it rather than
// hanging the reader or the sender indefinitely. A timeout is a legitimate
// at-most-once drop, not a transport error: the link is closed and the protocol
// above redials.
const defaultSocketTimeout = 30 * time.Second

// NewTCPTransport listens on listenAddr and starts accepting. Use ":0" for an
// ephemeral port and Addr() to discover it. Peers are registered afterwards
// with AddPeer; wiring them from a Config is the node layer's job (3.3).
func NewTCPTransport(self NodeID, listenAddr string, h Handler) (*TCPTransport, error) {
	if self == None {
		return nil, errors.New("cluster: tcp self id 0 is reserved")
	}
	if h == nil {
		return nil, errors.New("cluster: tcp handler is nil")
	}
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return nil, fmt.Errorf("cluster: tcp listen: %w", err)
	}
	t := &TCPTransport{
		self:    self,
		h:       h,
		ln:      ln,
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

// socketTimeout returns the current read and write deadline duration, read
// under the lock so a caller that does not already hold mu stays race free
// against an adjustment (the tests shorten it).
func (t *TCPTransport) socketTimeout() time.Duration {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.timeout
}

// Send frames data and writes it to the peer, dialing on demand. A write
// failure drops the link and surfaces the error; the message is lost, which
// is exactly the at-most-once contract.
func (t *TCPTransport) Send(to NodeID, data []byte) error {
	link, err := t.link(to)
	if err != nil {
		return err
	}
	link.mu.Lock()
	defer link.mu.Unlock()
	_ = link.conn.SetWriteDeadline(time.Now().Add(t.socketTimeout()))
	if _, werr := persist.WriteBlock(link.conn, persist.BlockClusterMessage, data); werr != nil {
		t.dropLink(to, link)
		return fmt.Errorf("cluster: tcp send to %d: %w", to, werr)
	}
	return nil
}

// link returns the live outbound connection to a peer, dialing and sending
// the hello if none exists. The transport lock is held across the dial: at
// cluster sizes this serialization is a simplicity win over per-peer dial
// races, and it guarantees exactly one hello per connection.
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
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("cluster: tcp dial node %d: %w", to, err)
	}
	hello := make([]byte, 8)
	binary.LittleEndian.PutUint64(hello, uint64(t.self))
	// mu is held here, so read t.timeout directly rather than through
	// socketTimeout, which would relock it.
	_ = conn.SetWriteDeadline(time.Now().Add(t.timeout))
	if _, werr := persist.WriteBlock(conn, persist.BlockClusterMessage, hello); werr != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("cluster: tcp hello to node %d: %w", to, werr)
	}
	l := &peerLink{conn: conn}
	t.links[to] = l
	return l, nil
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

// readLoop attributes the connection via the hello, then feeds every valid
// frame to the handler. Any framing error ends the connection: the peer will
// redial, and whatever was in flight is lost (at-most-once).
func (t *TCPTransport) readLoop(conn net.Conn) {
	defer t.wg.Done()
	defer func() {
		t.mu.Lock()
		delete(t.inbound, conn)
		t.mu.Unlock()
		_ = conn.Close()
	}()

	_ = conn.SetReadDeadline(time.Now().Add(t.socketTimeout()))
	typ, payload, err := persist.ReadBlock(conn)
	if err != nil || typ != persist.BlockClusterMessage || len(payload) != 8 {
		return
	}
	from := NodeID(binary.LittleEndian.Uint64(payload))
	if from == None {
		return
	}

	for {
		_ = conn.SetReadDeadline(time.Now().Add(t.socketTimeout()))
		typ, payload, err := persist.ReadBlock(conn)
		if err != nil || typ != persist.BlockClusterMessage {
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
