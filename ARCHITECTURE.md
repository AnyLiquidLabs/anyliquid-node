# Repository Architecture

This file is a short entrypoint. The detailed architecture lives under [`docs/`](docs/).

## Start Here

- [`docs/design-docs/index.md`](docs/design-docs/index.md)
- [`docs/design-docs/core-beliefs.md`](docs/design-docs/core-beliefs.md)
- [`docs/design-docs/harness-driven-documentation.md`](docs/design-docs/harness-driven-documentation.md)

## System Map

The repository describes two major runtime layers:

- [`docs/design-docs/api-layer/index.md`](docs/design-docs/api-layer/index.md): the externally exposed API process
- [`docs/design-docs/node-layer/index.md`](docs/design-docs/node-layer/index.md): the authoritative execution and consensus process

Shared types and IPC contracts live in:

- [`docs/design-docs/shared/shared-contracts.md`](docs/design-docs/shared/shared-contracts.md)

## Documentation Layout

```text
docs/
├── design-docs/
│   ├── api-layer/
│   ├── node-layer/
│   ├── shared/
│   ├── core-beliefs.md
│   └── harness-driven-documentation.md
├── product-specs/
└── references/
```

## Working Rule

When implementation behavior changes, update the corresponding document under `docs/design-docs/` in the same change. Avoid creating new root-level markdown files for durable knowledge.
