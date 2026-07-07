package naylamp

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"

	"naylamp/engine/cluster"
	"naylamp/engine/vector"
)

// ClientKind is the cluster envelope family for client traffic: requests from
// a coordinator to a replica and the responses back. It is separate from the
// consensus family so one transport carries both without confusion; the
// envelope already supplies From, To and a CRC over the whole frame.
const ClientKind cluster.Kind = 2

// ClientOp names the operation a request carries.
type ClientOp uint8

const (
	// ReqUpsert adds or replaces a vector under an id.
	ReqUpsert ClientOp = 1
	// ReqDelete removes an id.
	ReqDelete ClientOp = 2
	// ReqSearch asks for the k nearest neighbors of a query vector.
	ReqSearch ClientOp = 3
)

// ClientStatus is the outcome a response reports.
type ClientStatus uint8

const (
	// StatusOK is a successful write (with an index) or search (with
	// neighbors).
	StatusOK ClientStatus = 1
	// StatusNotLeader tells the caller to redirect; Leader may hint where.
	StatusNotLeader ClientStatus = 2
	// StatusNotReady is a retryable refusal: the leader has no commit in its
	// own term yet.
	StatusNotReady ClientStatus = 3
	// StatusInvalidArgument rejects a malformed request without touching the
	// state machine; the caller fixes its input.
	StatusInvalidArgument ClientStatus = 4
)

// ClientRequest is one decoded client operation. Unused fields are zero and
// the codec enforces it: a delete carries neither k nor a vector, an upsert no
// k, a search no id.
type ClientRequest struct {
	Op    ClientOp
	ReqID uint64
	ID    uint64
	K     uint32
	Vec   []float32
}

// ClientResponse is one decoded reply, keyed to a request by ReqID.
type ClientResponse struct {
	ReqID     uint64
	Status    ClientStatus
	Leader    cluster.NodeID
	Index     uint64
	Neighbors []vector.Neighbor
}

// ErrWrongClientKind reports an envelope that is not client traffic. Fail loud:
// a frame in the wrong family means a routing bug, not a value to guess at.
var ErrWrongClientKind = errors.New("naylamp: envelope does not carry client traffic")

// ErrMalformedClientMessage reports a body that does not parse cleanly. Fail
// loud, exactly like the consensus codec: a lying length or a stray byte can
// only mean corruption or version skew, and reading past it would act on state
// the sender never framed.
var ErrMalformedClientMessage = errors.New("naylamp: malformed client message body")

// Client request body, little-endian. From and To are not in the body: they
// travel in the cluster envelope, which already frames and checksums the whole
// message.
//
//	op     uint8  (1 upsert, 2 delete, 3 search)
//	reqID  uint64
//	id     uint64
//	k      uint32
//	count  uint32
//	vec    count times float32 bits
//
// Client response body, little-endian.
//
//	reqID     uint64
//	status    uint8  (1 ok, 2 not leader, 3 not ready, 4 invalid argument)
//	leader    uint64
//	index     uint64
//	count     uint32
//	neighbors count times: id uint64, distance float32 bits
const (
	clientReqHeaderSize  = 1 + 8 + 8 + 4 + 4
	clientRespHeaderSize = 8 + 1 + 8 + 8 + 4
	neighborFixedSize    = 8 + 4
)

// EncodeClientRequest frames a request into a cluster envelope under
// ClientKind. Float bits are preserved exactly: the codec is a transport, not
// a place for numeric policy.
func EncodeClientRequest(from, to cluster.NodeID, r ClientRequest) ([]byte, error) {
	body := make([]byte, 0, clientReqHeaderSize+4*len(r.Vec))
	var scratch [8]byte

	body = append(body, byte(r.Op))
	binary.LittleEndian.PutUint64(scratch[:8], r.ReqID)
	body = append(body, scratch[:8]...)
	binary.LittleEndian.PutUint64(scratch[:8], r.ID)
	body = append(body, scratch[:8]...)
	binary.LittleEndian.PutUint32(scratch[:4], r.K)
	body = append(body, scratch[:4]...)
	binary.LittleEndian.PutUint32(scratch[:4], uint32(len(r.Vec))) //nolint:gosec // a vector length is bounded far below uint32
	body = append(body, scratch[:4]...)
	for _, v := range r.Vec {
		binary.LittleEndian.PutUint32(scratch[:4], math.Float32bits(v))
		body = append(body, scratch[:4]...)
	}
	return cluster.EncodeMessage(cluster.Envelope{From: from, To: to, Kind: ClientKind, Payload: body})
}

// DecodeClientRequest parses a request out of an already-decoded envelope,
// verifying the kind first, then every length before it is trusted: a count
// that cannot fit the payload is rejected before any allocation sized by it,
// unused fields must be zero for the op, and trailing bytes fail loudly. What
// makes a value merely INVALID (k, count, dimension out of range) is not the
// codec's business: the node answers those with StatusInvalidArgument, since a
// caller that gets an addressable answer beats one that gets a silent drop.
func DecodeClientRequest(env cluster.Envelope) (ClientRequest, error) {
	if env.Kind != ClientKind {
		return ClientRequest{}, fmt.Errorf("%w: kind %d", ErrWrongClientKind, env.Kind)
	}
	b := env.Payload
	if len(b) < clientReqHeaderSize {
		return ClientRequest{}, fmt.Errorf("%w: %d bytes", ErrMalformedClientMessage, len(b))
	}
	r := ClientRequest{
		Op:    ClientOp(b[0]),
		ReqID: binary.LittleEndian.Uint64(b[1:9]),
		ID:    binary.LittleEndian.Uint64(b[9:17]),
		K:     binary.LittleEndian.Uint32(b[17:21]),
	}
	count := binary.LittleEndian.Uint32(b[21:25])
	rest := len(b) - clientReqHeaderSize
	if uint64(count)*4 != uint64(rest) { //nolint:gosec // rest >= 0 by the length check above, so the conversion cannot wrap
		return ClientRequest{}, fmt.Errorf("%w: count %d does not match %d payload bytes", ErrMalformedClientMessage, count, rest)
	}

	switch r.Op {
	case ReqUpsert:
		if r.K != 0 {
			return ClientRequest{}, fmt.Errorf("%w: upsert carries a nonzero k", ErrMalformedClientMessage)
		}
	case ReqDelete:
		if r.K != 0 || count != 0 {
			return ClientRequest{}, fmt.Errorf("%w: delete carries a k or a vector", ErrMalformedClientMessage)
		}
	case ReqSearch:
		if r.ID != 0 {
			return ClientRequest{}, fmt.Errorf("%w: search carries a nonzero id", ErrMalformedClientMessage)
		}
	default:
		return ClientRequest{}, fmt.Errorf("%w: unknown op %d", ErrMalformedClientMessage, r.Op)
	}

	if count > 0 {
		r.Vec = make([]float32, count)
		for i := range r.Vec {
			off := clientReqHeaderSize + 4*i
			r.Vec[i] = math.Float32frombits(binary.LittleEndian.Uint32(b[off : off+4]))
		}
	}
	return r, nil
}

// EncodeClientResponse frames a response into a cluster envelope under
// ClientKind.
func EncodeClientResponse(from, to cluster.NodeID, r ClientResponse) ([]byte, error) {
	body := make([]byte, 0, clientRespHeaderSize+neighborFixedSize*len(r.Neighbors))
	var scratch [8]byte

	binary.LittleEndian.PutUint64(scratch[:8], r.ReqID)
	body = append(body, scratch[:8]...)
	body = append(body, byte(r.Status))
	binary.LittleEndian.PutUint64(scratch[:8], uint64(r.Leader))
	body = append(body, scratch[:8]...)
	binary.LittleEndian.PutUint64(scratch[:8], r.Index)
	body = append(body, scratch[:8]...)
	binary.LittleEndian.PutUint32(scratch[:4], uint32(len(r.Neighbors))) //nolint:gosec // a neighbor count is bounded far below uint32
	body = append(body, scratch[:4]...)
	for _, n := range r.Neighbors {
		binary.LittleEndian.PutUint64(scratch[:8], n.ID)
		body = append(body, scratch[:8]...)
		binary.LittleEndian.PutUint32(scratch[:4], math.Float32bits(n.Distance))
		body = append(body, scratch[:4]...)
	}
	return cluster.EncodeMessage(cluster.Envelope{From: from, To: to, Kind: ClientKind, Payload: body})
}

// DecodeClientResponse parses a response out of an already-decoded envelope,
// verifying the kind first, then every length, then the fields each status is
// allowed to carry. The codec cannot tell an empty search OK from a write OK
// when both have index zero and no neighbors; that ambiguity does not exist in
// practice because the requester knows the op it sent under this reqID.
func DecodeClientResponse(env cluster.Envelope) (ClientResponse, error) {
	if env.Kind != ClientKind {
		return ClientResponse{}, fmt.Errorf("%w: kind %d", ErrWrongClientKind, env.Kind)
	}
	b := env.Payload
	if len(b) < clientRespHeaderSize {
		return ClientResponse{}, fmt.Errorf("%w: %d bytes", ErrMalformedClientMessage, len(b))
	}
	r := ClientResponse{
		ReqID:  binary.LittleEndian.Uint64(b[0:8]),
		Status: ClientStatus(b[8]),
		Leader: cluster.NodeID(binary.LittleEndian.Uint64(b[9:17])),
		Index:  binary.LittleEndian.Uint64(b[17:25]),
	}
	count := binary.LittleEndian.Uint32(b[25:29])
	rest := len(b) - clientRespHeaderSize
	if uint64(count)*neighborFixedSize != uint64(rest) { //nolint:gosec // rest >= 0 by the length check above, so the conversion cannot wrap
		return ClientResponse{}, fmt.Errorf("%w: count %d does not match %d payload bytes", ErrMalformedClientMessage, count, rest)
	}

	switch r.Status {
	case StatusOK:
		// A write OK carries index > 0, leader 0, no neighbors; a search OK
		// carries index 0, leader 0, and any number of neighbors. Both leave
		// leader zero, and only their overlap (index 0, no neighbors) is
		// indistinguishable, which the requester disambiguates by op.
		if r.Leader != 0 {
			return ClientResponse{}, fmt.Errorf("%w: ok carries a leader hint", ErrMalformedClientMessage)
		}
		if r.Index != 0 && count != 0 {
			return ClientResponse{}, fmt.Errorf("%w: ok is both a write and a search", ErrMalformedClientMessage)
		}
	case StatusNotLeader:
		if r.Index != 0 || count != 0 {
			return ClientResponse{}, fmt.Errorf("%w: not-leader carries write or search state", ErrMalformedClientMessage)
		}
	case StatusNotReady, StatusInvalidArgument:
		if r.Leader != 0 || r.Index != 0 || count != 0 {
			return ClientResponse{}, fmt.Errorf("%w: status %d carries state it should not", ErrMalformedClientMessage, r.Status)
		}
	default:
		return ClientResponse{}, fmt.Errorf("%w: unknown status %d", ErrMalformedClientMessage, r.Status)
	}

	if count > 0 {
		r.Neighbors = make([]vector.Neighbor, count)
		for i := range r.Neighbors {
			off := clientRespHeaderSize + neighborFixedSize*i
			r.Neighbors[i] = vector.Neighbor{
				ID:       binary.LittleEndian.Uint64(b[off : off+8]),
				Distance: math.Float32frombits(binary.LittleEndian.Uint32(b[off+8 : off+12])),
			}
		}
	}
	return r, nil
}
