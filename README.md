# sekisho

[![CI](https://github.com/Taure/sekisho/actions/workflows/ci.yml/badge.svg)](https://github.com/Taure/sekisho/actions/workflows/ci.yml)
[![OTP](https://img.shields.io/badge/OTP-29%2B-blue)](https://www.erlang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://github.com/Taure/sekisho/blob/main/LICENSE)

**関所** ("barrier checkpoint") - an LLM gateway for the BEAM.

sekisho is the control plane every team and tool points at instead of calling
LLM providers directly. It custodies the real provider credentials, issues
per-team virtual keys, accounts every request, enforces budgets, and writes an
audit trail - so a regulated org gets central key management, cost attribution,
and compliance evidence across heterogeneous clients (Claude Code, gakudan
agents, services in any language).

It is a deployable Nova service on kura/Postgres, built security-first: provider
credentials are encrypted at rest, virtual keys are stored hashed, and secrets
are never logged or returned.

## How it works

Two wire-compatible lanes, four upstreams, no format translation:

| Client format | Upstream | Auth |
| --- | --- | --- |
| Anthropic Messages | api.anthropic.com | API key |
| Anthropic Messages | Claude on Vertex | GCP service account |
| OpenAI Chat Completions | Gemini (OpenAI-compat) | API key |
| OpenAI Chat Completions | Gemini on Vertex | GCP service account |

An "upstream" is just `{format, base_url, auth_mode, credential}`, so the public
APIs and Vertex are the same abstraction differing only in config - a
data-residency (Vertex-only) deployment is configuration, not a fork.

A client sends its normal provider request to sekisho with a **virtual key**;
sekisho looks up the key's team, upstream, and budget, enforces the budget,
forwards with the real credential, records usage + cost, and returns the
provider's response unchanged.

## Status

v0.1 in development. See [docs/adr/0001-gateway-security-model.md](docs/adr/0001-gateway-security-model.md)
for the architecture and threat model.

Deferred from v0.1: streaming passthrough, cross-format translation, provider
fallback, response caching, rate limiting beyond budgets.

## License

MIT.
