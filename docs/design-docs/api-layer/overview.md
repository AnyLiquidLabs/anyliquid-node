# API Layer Architecture

The API layer is the externally exposed boundary service. It runs as an independent process, scales horizontally, and owns no authoritative matching state. All state is replicated from the Node layer into a local read model. User writes are authenticated and forwarded to Node. Reads are served from the local cache.

This layer follows the repository-wide harness-first rules in [`../harness-driven-documentation.md`](../harness-driven-documentation.md).

```text
┌─────────────────────────────────────────────────────┐
│                     API Process                     │
│                                                     │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │   REST   │  │    WS    │  │  Auth Middleware  │ │
│  │  8080    │  │  8081    │  │  - ECDSA verify   │ │
│  │          │  │          │  │  - Rate limiter   │ │
│  └────┬─────┘  └────┬─────┘  └────────┬──────────┘ │
│       │             │                 │            │
│       └─────────────┴─────────────────┘            │
│                         │                           │
│                  ┌──────▼──────┐                    │
│                  │ Router /    │                    │
│                  │ Dispatcher  │                    │
│                  └──────┬──────┘                    │
│                         │                           │
│         ┌───────────────┼───────────────┐           │
│         ▼               ▼               ▼           │
│  ┌─────────────┐ ┌────────────┐ ┌────────────────┐ │
│  │ State Cache │ │  Gateway   │ │ Subscription   │ │
│  │ read-only   │ │ IPC client │ │ Manager        │ │
│  └─────────────┘ └─────┬──────┘ └───────┬────────┘ │
│                         │                │          │
└─────────────────────────┼────────────────┼──────────┘
                          │                │
                IPC (Unix socket or internal TCP)
                          │                │
                  ┌───────▼────────────────▼───────┐
                  │          Node Process           │
                  └─────────────────────────────────┘
```

## Documentation Constraints

- Every API module document must define observable behavior and harness seams.
- Every read path must state whether it is allowed to bypass Node and use `StateCache`.
- Every write path must define the acknowledgment boundary unambiguously.

## Module Map

| Module | Document | Responsibility |
| --- | --- | --- |
| REST Server | [`rest-server.md`](rest-server.md) | HTTP trading and query endpoints |
| WebSocket Server | [`websocket-server.md`](websocket-server.md) | realtime push and subscription management |
| Auth Middleware | [`auth-middleware.md`](auth-middleware.md) | EIP-712 verification and rate limiting |
| Gateway | [`gateway.md`](gateway.md) | IPC client for Node communication |
| Local State Cache | [`state-cache.md`](state-cache.md) | local read model for API-serving queries |
| Shared Contracts | [`../shared/shared-contracts.md`](../shared/shared-contracts.md) | shared types and IPC contracts |

## Data Flow

### Write path

```text
Client
  -> REST POST /exchange
  -> Auth Middleware
  -> Gateway.sendAction(action)
  -> IPC to Node
  -> Node executes and commits
  -> ACK and events flow back
  -> HTTP response completes
```

### Read path

```text
Client
  -> REST POST /info
  -> Auth Middleware (rate limit only)
  -> StateCache.query()
  -> HTTP response
```

### Subscription path

```text
Client
  -> WS connect
  -> subscribe { type: "l2Book", coin: "BTC" }
  -> Subscription Manager registration
  -> Node event arrives via Gateway
  -> StateCache applies the event and advances sequence
  -> Subscription Manager fan-out
  -> WS send to subscribers
```

## Harness Entry Points

API docs should support these harness combinations:

- `mock_gateway = true` to validate routing, auth, and response mapping without a real Node
- `cache_seed = ...` to validate cached `/info` reads and subscription snapshots
- `inject_node_event(...)` to validate Gateway -> Cache -> WS propagation
- `clock = fake_clock` for nonce, rate-limit, and timeout-sensitive behaviors

## IPC Contract

API and Node communicate with a private binary protocol:

```text
[ u32 len ][ u32 msg_id ][ u8 msg_type ][ payload bytes ]
```

Shared message definitions live in [`../shared/shared-contracts.md`](../shared/shared-contracts.md).

## Performance Targets

| Metric | Target |
| --- | --- |
| REST order placement P99 latency | < 5 ms, excluding Node processing |
| WebSocket push latency | < 1 ms from Node event receipt to send |
| Concurrent WebSocket connections | 100,000+ |
| REST QPS | 50,000+ |
