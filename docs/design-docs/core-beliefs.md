# Core Beliefs

These beliefs define how the system should evolve and how its documentation should be maintained.

## Architecture

- The Node layer is the single source of truth for matching, state transition, and consensus.
- The API layer is a scalable boundary service that authenticates writes, serves cached reads, and streams state outward.
- Shared contracts must be explicit and stable enough to be used by both implementation code and test harnesses.

## Execution

- Deterministic execution matters more than local cleverness. Given the same block, every honest node must produce the same state transition.
- Read paths should be cheap and local whenever possible. Write paths should have one well-defined acknowledgment boundary.
- Recovery behavior is a first-class feature. Reconnects, cache replay, backpressure, and restart semantics belong in the design, not as implementation afterthoughts.
- The implementation baseline is `Zig 0.15.2`, and design documents should avoid assuming other compiler versions unless explicitly called out.
- The long-term system design target is `1,000,000 TPS`, so data structures, protocol choices, and recovery flows should be reviewed with that scale in mind.
- Mature third-party libraries should be preferred over custom implementations in high-risk or high-complexity areas such as cryptography, binary serialization, HTTP parsing, and persistent storage.

## Documentation

- `docs/` is the system of record for durable project knowledge.
- Root-level docs should stay short and point into indexed design documents.
- A design document is incomplete if its behavior cannot be observed or reproduced by a harness.
- All documentation and code comments should be written in English only.

## Testing

- Every critical module should support happy-path, rejection, timeout, backpressure, and recovery scenarios.
- Time-dependent logic should allow a fake or injectable clock.
- Harnesses should be able to seed state, inject events, and inspect counters without requiring the full distributed system to boot.
