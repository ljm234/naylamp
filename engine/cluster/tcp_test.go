package cluster

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"naylamp/engine/persist"
)

// TestTCP_DeadlineUnblocksHungPeer proves the socket read deadline: a peer that
// opens a connection and then goes silent must not block the receiver's read
// loop forever. The receiver times the read out and closes the connection, so
// this test observes the close promptly rather than hanging. With the deadlines
// removed the receiver would block indefinitely and the read below would only
// return at its own safety deadline, which the elapsed bound catches. A timeout
// is a legitimate at-most-once drop, so it is not a transport error.
func TestTCP_DeadlineUnblocksHungPeer(t *testing.T) {
	recv, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {})
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

	// A hung peer: dial the receiver, send a valid hello so its read loop admits
	// the connection, then send nothing more.
	conn, err := net.Dial("tcp", recv.Addr())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer func() { _ = conn.Close() }()
	hello := make([]byte, 8)
	binary.LittleEndian.PutUint64(hello, uint64(2))
	if _, werr := persist.WriteBlock(conn, persist.BlockClusterMessage, hello); werr != nil {
		t.Fatalf("hello: %v", werr)
	}

	// The receiver read the hello, then blocks on the next frame. With the read
	// deadline it gives up after about timeout and closes the connection, which
	// this read observes as EOF or a reset well within the bound below. A safety
	// deadline on our own read keeps the test from hanging if the receiver never
	// times out.
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
