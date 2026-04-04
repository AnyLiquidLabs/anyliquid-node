# AGENTS.md

This repository follows the documentation pattern described in OpenAI's Harness Engineering article:

- Keep top-level agent guidance short.
- Treat `docs/` as the system of record for durable project knowledge.
- Organize design knowledge by domain so agents can load only the relevant files.

## Start Here

1. Read [`ARCHITECTURE.md`](ARCHITECTURE.md) for the repository map.
2. Read [`docs/design-docs/index.md`](docs/design-docs/index.md) for the design documentation index.
3. Read only the module documents that are relevant to the task.

## Documentation Rules

- Design documents live under `docs/design-docs/`.
- Product and operational references live under `docs/product-specs/` and `docs/references/`.
- When a behavior changes, update the corresponding design document in the same change.
- Prefer adding new knowledge to an existing indexed document instead of creating ad hoc markdown files at the repository root.

## Repository Constraints

- The implementation target is `Zig 0.15.2`.
- The system is designed toward a long-term throughput target of `1,000,000 TPS`, so design changes should be evaluated against that target.
- Prefer mature third-party libraries over bespoke implementations for cryptography, serialization, parsing, storage, and low-level networking primitives.
- All documentation and code comments must be written in English.

## Current Knowledge Layout

- API-layer design: `docs/design-docs/api-layer/`
- Node-layer design: `docs/design-docs/node-layer/`
- Shared contracts: `docs/design-docs/shared/`
- Engineering beliefs and harness standards: `docs/design-docs/core-beliefs.md` and `docs/design-docs/harness-driven-documentation.md`
