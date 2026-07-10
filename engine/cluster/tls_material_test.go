package cluster

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"naylamp/engine/cluster/tlstest"
)

// TestLoadTLSMaterial_RoundTrip proves the production loading path end to end:
// tlstest writes a CA and two node certificate pairs to disk, LoadTLSMaterial
// reads each node's material back, and two transports built from the loaded
// material complete a mutual TLS handshake and deliver a frame whose attributed
// identity is read off the loaded certificate. It is the on-disk analogue of
// the in-memory contract, so the file format the demo writes is proven to feed
// a working handshake, not just to parse.
func TestLoadTLSMaterial_RoundTrip(t *testing.T) {
	ca, err := tlstest.NewCA()
	if err != nil {
		t.Fatalf("new ca: %v", err)
	}
	dir := t.TempDir()
	if werr := ca.WritePEM(dir, 1, 2); werr != nil {
		t.Fatalf("write pem: %v", werr)
	}

	load := func(id uint64) TLSMaterial {
		mat, lerr := LoadTLSMaterial(
			filepath.Join(dir, fmt.Sprintf("node-%d.pem", id)),
			filepath.Join(dir, fmt.Sprintf("node-%d-key.pem", id)),
			filepath.Join(dir, "ca.pem"),
		)
		if lerr != nil {
			t.Fatalf("load material %d: %v", id, lerr)
		}
		return mat
	}

	got := make(chan NodeID, 1)
	recv, err := NewTCPTransport(2, "127.0.0.1:0", func(from NodeID, _ []byte) { got <- from }, load(2))
	if err != nil {
		t.Fatalf("recv transport: %v", err)
	}
	defer func() { _ = recv.Close() }()

	sender, err := NewTCPTransport(1, "127.0.0.1:0", func(NodeID, []byte) {}, load(1))
	if err != nil {
		t.Fatalf("sender transport: %v", err)
	}
	defer func() { _ = sender.Close() }()
	sender.AddPeer(2, recv.Addr())

	if serr := sender.Send(2, []byte("loaded from disk")); serr != nil {
		t.Fatalf("send: %v", serr)
	}
	select {
	case from := <-got:
		if from != 1 {
			t.Fatalf("frame attributed to node %d, want 1", from)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("timeout waiting for delivery of the frame")
	}
}
