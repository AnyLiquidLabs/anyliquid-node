# Design Docs Index

This directory is the durable design knowledge base for the AnyLiquid node and API stack.

## Reading Order

1. [`core-beliefs.md`](core-beliefs.md)
2. [`harness-driven-documentation.md`](harness-driven-documentation.md)
3. [`api-layer/index.md`](api-layer/index.md)
4. [`node-layer/index.md`](node-layer/index.md)
5. [`shared/shared-contracts.md`](shared/shared-contracts.md)

## Domain Map

- [`api-layer/`](api-layer/index.md): external API boundary, authentication, caching, HTTP, and WebSocket delivery.
- [`node-layer/`](node-layer/index.md): authoritative execution, consensus, storage, networking, and risk logic.
- [`shared/`](shared/shared-contracts.md): contracts shared by API and Node processes.

## Conventions

- Each module document should define responsibilities, interfaces, observable behavior, and harness entry points.
- Cross-module types should be defined in the shared contracts document and referenced from module docs.
- Overview documents should link to concrete module documents instead of duplicating contract details.
