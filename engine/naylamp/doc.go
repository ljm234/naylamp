// Package naylamp is the public API of the Naylamp vector database engine. It
// spans two layers built on the same vector store and HNSW index.
//
// The single-node layer is the in-process facade. An Engine owns named
// Collections (New, CreateCollection, and Collection lookup); a Collection is a
// self-contained group of vectors of one dimension that you Upsert into, Query
// for nearest neighbors, and Delete from. It is safe for concurrent use and has
// no consensus or durability of its own. It also carries one read-only audit
// accessor, IndexIDs, which enumerates the ids its index holds.
//
// The replicated layer turns a collection into a fault-tolerant service. A Node,
// opened with OpenNode, is one replica of a vector collection driven by a Raft
// core: it accepts Upsert, Delete and Search, serves a linearizable read through
// BeginRead, ReadServable and ReadIndex, persists its log and recovers from it.
// A Node is sans-io, so a Host wires it to a transport, and a Router with its
// RouterHost fans a client operation out across shards and gathers a search into
// a global top-k. Client operations and their replies travel as ClientRequest
// and ClientResponse frames.
//
// There is no network server in this package: a Node speaks over whatever
// transport it is bound to, a simulated fabric under the seeded tests or TCP in
// the demo binary, and serving the API over a real client-facing server is the
// job of a later subphase, not of this package.
package naylamp

// APIVersion is the version of this package's public API surface: the exported
// types and methods a consumer builds against (Engine, Collection, Node, Host,
// Router, RouterHost and the client wire types). It is not the state machine
// image format version, which imageVersion carries, and not a module version,
// which the module would carry through its own tags. It starts at a first
// stable-in-progress version, so the surface may still evolve before it reaches
// 1.0.
//
// It stays at 0.1.0 through the addition of Collection.IndexIDs: an added method
// breaks no consumer, so moving the number would report a change that did not
// happen.
const APIVersion = "0.1.0"
