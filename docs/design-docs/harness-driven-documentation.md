# Harness-Driven Documentation

These design documents are not just descriptions. They are contracts for implementation, testing, and review.

Every module document should answer three questions:

1. What state does the module own, and who is allowed to mutate it?
2. What observable behavior does the module expose?
3. What seams must exist so a harness can reproduce normal, failing, and recovery scenarios deterministically?

## Required Sections

## Language Rule

- All design documents, examples, inline explanations, and code comments must be written in English only.

### Boundaries and Ownership

- Define owned state and mutable dependencies.
- Call out which operations are synchronously observable and which become visible only after asynchronous progression.
- Reuse shared contracts for cross-module types whenever possible.

### Observability

Each module should expose at least one of the following:

- return values or typed errors
- counters or metrics
- state snapshots
- event streams
- backpressure or resource health signals

If behavior cannot be observed from a harness, it is not fully specified.

### Harness Injection Points

Each module should describe the seams required for stable tests, such as:

- mock gateway or mock node
- fake cache or seeded state
- fake clock for nonce windows, deadlines, and refill timers
- injected block commits, network events, or oracle prices
- readable internal counters such as `gateway_call_count`, `slow_client_drops`, or `stale_events`

### Acceptance Scenarios

At minimum, cover:

- happy path
- rejection path
- timeout or backpressure path
- recovery path

## Review Checklist

Review a design document in this order:

1. Terminology consistency across files
2. Valid links and directory placement
3. Executable-looking examples
4. Observable success and failure semantics
5. Defined recovery behavior

## Repository-Level Agreements

- API reads default to `StateCache` unless a document explicitly requires a live Node query.
- API writes complete when `Gateway.sendAction` returns an ACK or a typed error.
- Node-originated events are modeled as `NodeEvent` and then mapped into API-visible behavior.
- Time-sensitive modules must support an injectable clock.
