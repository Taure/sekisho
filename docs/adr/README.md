# Architecture Decision Records

The decision log for sekisho. Each ADR captures the *why* behind a behaviour, a
wire-protocol or persistence choice, or the security model - the context an
agent or contributor needs before changing it.

## When to write one

Write a new ADR for any new upstream auth mode, persistence change, public API
shape, or change to the security model. Small fixes that preserve contracts do
not need one.

Use the [Nygard format](https://github.com/joelparkerhenderson/architecture-decision-record):
**Context**, **Decision**, **Consequences**. Number sequentially; never rewrite
a merged ADR - supersede it.

## Index

| ADR | Title |
| --- | --- |
| [0001](0001-gateway-security-model.md) | Gateway and security model |
