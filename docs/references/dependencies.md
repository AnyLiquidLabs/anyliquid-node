# Dependencies and Library Strategy

This repository currently contains design documents rather than a concrete `build.zig` implementation. Because of that, this file distinguishes between:

- external technologies already referenced by the design
- preferred mature libraries to use when implementation begins

## Implementation Policy

- Target language version: `Zig 0.15.2`
- Prefer mature libraries over bespoke implementations in cryptography, serialization, parsing, storage, and low-level networking
- Prefer official upstream libraries or widely used primary implementations over niche wrappers
- Prefer C libraries with stable APIs when Zig-native options are immature or insufficient for the `1,000,000 TPS` design target

## External Technologies Already Used in the Design

These are already part of the documented architecture and should be treated as accepted design dependencies:

- `MessagePack` for API <-> Node IPC encoding
- `EIP-712` for exchange action signing
- `secp256k1` for signature verification and recovery
- `BLS12-381` aggregate signatures for consensus
- `keccak256` hashing
- `io_uring` for Linux async I/O
- `Sparse Merkle Tree` for state proofs
- `HotStuff-style BFT / HyperBFT` for consensus
- `Kademlia-style` peer discovery for P2P
- `HTTP`, `WebSocket`, `Unix socket`, and internal `TCP` transports

## Preferred Mature Libraries

### Cryptography

- `bitcoin-core/secp256k1`
  - Use for ECDSA verification, recovery, and related secp256k1 primitives
  - Reason: widely used, high-assurance, optimized, minimal runtime dependencies
  - Source: [bitcoin-core/secp256k1](https://github.com/bitcoin-core/secp256k1)

- `supranational/blst`
  - Use for BLS12-381 signatures and aggregate verification in consensus
  - Reason: performance- and security-focused, widely adopted in blockchain systems
  - Source: [supranational/blst](https://github.com/supranational/blst)

### Serialization and Parsing

- `ludocode/mpack`
  - Preferred C library for MessagePack encode/decode
  - Reason: small, embeddable, secure against untrusted data, straightforward Zig FFI story
  - Source: [ludocode/mpack](https://github.com/ludocode/mpack)

- `ibireme/yyjson`
  - Preferred JSON parser/serializer for REST and WebSocket payloads
  - Reason: very fast ANSI C library, simple embedding model, strong fit for request-heavy systems
  - Source: [ibireme/yyjson](https://github.com/ibireme/yyjson)

- `nodejs/llhttp`
  - Preferred HTTP/1.1 parser if the implementation does not rely on a higher-level server runtime
  - Reason: maintained successor to `http-parser`, strong performance, explicit parser state machine
  - Source: [nodejs/llhttp](https://github.com/nodejs/llhttp)

### Storage

- `facebook/rocksdb`
  - Preferred KV/index backend for block history, fill history, and secondary indexes
  - Reason: battle-tested LSM engine with strong read/write tradeoff tuning and large-scale production usage
  - Source: [facebook/rocksdb](https://github.com/facebook/rocksdb)

### Optional High-Performance Networking Candidate

- `uNetworking/uWebSockets`
  - Candidate for extreme-scale HTTP/WebSocket serving if the team accepts C++ integration complexity
  - Reason: battle-tested and explicitly optimized for high-throughput WebSocket systems
  - Caution: this is not the default recommendation because the Zig <-> C++ integration cost is significantly higher than pure C dependencies
  - Source: [uNetworking/uWebSockets](https://github.com/uNetworking/uWebSockets)

## Deliberately Not Recommended for a First Implementation

- Custom secp256k1 or BLS implementations
  - Too easy to get wrong, too expensive to audit

- Custom MessagePack parser
  - Not justified while mature libraries exist

- Custom HTTP parser
  - High security risk and poor return on effort

- Building the persistence layer directly on raw files before validating requirements against RocksDB
  - Acceptable for narrow WAL-only parts, but not as the primary indexed state/history backend

## Internal Module Map

The internal modules that will consume these dependencies are:

### API Layer

- `Auth Middleware`
- `Gateway`
- `REST Server`
- `State Cache`
- `WebSocket Server`

### Node Layer

- `Consensus (HyperBFT)`
- `IPC Server`
- `Matching Engine`
- `Mempool`
- `Oracle Aggregator`
- `P2P Network`
- `Perp Engine`
- `Risk Engine`
- `Store`

### Shared Layer

- `types.zig`
- `protocol.zig`
- `crypto.zig`
- `fixed_point.zig`

## Open Implementation Decisions

These are still design-level choices and should be resolved when code scaffolding starts:

- whether HTTP/WebSocket serving should use Zig-native infrastructure plus `llhttp`, or a heavier integrated runtime
- whether RocksDB is used directly through Zig FFI or behind a narrow storage adapter
- whether MessagePack and JSON are handled entirely through embedded C libraries or partially replaced by Zig-native code later
