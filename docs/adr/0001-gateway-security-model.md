# 1. Gateway and security model

Date: 2026-05-28

## Status

Accepted (v0.1).

## Context

The org runs LLM traffic across many teams and tools (Claude Code, gakudan
agents, services in several languages) directly against provider APIs. That
means provider keys copied into many places, no central cost attribution, no
per-team budgets, and no unified audit trail - untenable for a regulated org.

sekisho is the control plane: one endpoint every client points at instead of
the provider. It custodies the real provider credentials, issues per-team
virtual keys, accounts every request, enforces budgets, and writes an audit
trail. It is a deployable Nova service on kura/Postgres, not a library.

Because it custodies secrets, the security model is the primary design concern,
not an afterthought.

## Decision

### Upstreams are `{format, base_url, auth_mode, credential}`

A provider target is configured data, not code:

- `format` - `anthropic` (Anthropic Messages API) or `openai` (OpenAI Chat
  Completions API).
- `base_url` - where to forward (public API or a regional Vertex endpoint).
- `auth_mode` - `api_key` (static key) or `gcp_oauth` (GCP service-account →
  short-lived bearer, minted and cached).
- `credential` - encrypted at rest (see below).

This makes the public APIs and Vertex the same abstraction differing only in
config. The four v0.1 upstreams:

| Lane (client format) | Upstream | auth_mode |
| --- | --- | --- |
| anthropic | api.anthropic.com | api_key |
| anthropic | Claude on Vertex (regional) | gcp_oauth |
| openai | Gemini OpenAI-compat (generativelanguage) | api_key |
| openai | Gemini on Vertex OpenAI-compat (regional) | gcp_oauth |

No format translation in v0.1: each client format passes through to a
matching-format upstream. Claude-on-Vertex needs only minor request rewriting
(`anthropic_version` in the body, GCP bearer auth, regional path), not
translation. Cross-format routing (e.g. Anthropic-format → Gemini) is deferred.

### Virtual keys

Clients authenticate with a sekisho-issued virtual key, never a provider key. A
virtual key binds to a team, an upstream, and a budget. Issuance returns the
token once; sekisho stores only a SHA-256 hash (+ per-token salt), so a database
read never yields a usable key - the same model as a password store. Lookup
hashes the presented token and matches.

### Provider credential custody

Real provider credentials (API keys, GCP service-account JSON) are encrypted at
rest with AES-256-GCM. The data-encryption key is supplied at boot via an
environment variable (`SEKISHO_MASTER_KEY`), never stored in the database or
the repo. Plaintext credentials live only transiently in memory during a
forwarded request. Credentials are never logged, never returned by any API, and
never echoed in errors.

### Request flow

1. Client → lane endpoint (`/anthropic/v1/messages` or
   `/openai/v1/chat/completions`) with the virtual key.
2. Hash + look up the key → team, upstream, budget. Reject unknown/disabled keys.
3. Enforce budget (reject over-budget before spending upstream).
4. Resolve upstream auth: decrypt the API key, or mint/cache a GCP token.
5. Forward to the upstream (minimal request rewriting), receive the response.
6. Parse usage from the response, compute cost, append to the usage ledger and
   the audit log (per team/key).
7. Return the provider response to the client unchanged.

### Streaming (in scope for v0.1)

Clients that send `stream: true` get a transparent SSE passthrough: sekisho
relays each `text/event-stream` chunk to the client as it arrives (preserving
latency), while accumulating the stream to extract final usage for accounting at
`stream_end`. Anthropic streams carry usage in `message_start` +
`message_delta`; OpenAI streams only include usage when
`stream_options.include_usage` is set, so sekisho injects that field into
OpenAI-format streaming requests that omit it. Budget is enforced before the
stream starts; the spend is recorded once the final usage is known. The upstream
call uses `httpc` async streaming (`{sync,false},{stream,self}`) - no new
dependency.

### Persistence (kura/Postgres)

- `upstreams` - configured targets + encrypted credentials.
- `virtual_keys` - hashed token, team, upstream ref, budget, enabled flag.
- `usage_ledger` - one row per request: key, model, tokens in/out, cost,
  timestamp.
- `audit_log` - append-only record of each request and admin action.

### Threat model (v0.1)

- **DB compromise** must not yield usable provider credentials (encrypted) or
  virtual keys (hashed).
- **Logs/errors** must never contain credentials or full virtual keys.
- **Transport** is TLS-only in production (terminated at the ingress; the app
  assumes TLS upstream and refuses to emit secrets over plaintext).
- **Budget enforcement** rejects an already-exhausted key before the upstream
  call; `spent_tokens` is bumped with an atomic SQL increment so concurrent
  requests never lose updates. Because token cost is unknown until the response,
  a budget can be overshot by at most (in-flight requests x per-request tokens)
  before the gate trips - inherent to token budgets, and bounded.
- **Outbound TLS is verified** (`verify_peer` + the OS CA store) on every call
  that carries a provider credential or mints a GCP token, so a MITM cannot
  harvest secrets in transit.
- **Internal errors are never reflected** to clients - upstream/crypto/DB error
  terms are logged server-side; the client gets a generic message.
- **Admin endpoints** (`/admin/*`) authenticate with a constant-time bearer
  check against `SEKISHO_ADMIN_TOKEN` and fail closed when it is unset. They are
  not network-segmented in v0.1; deployments must restrict `/admin/*` at the
  ingress.
- **Master key** for AES-256-GCM comes from `SEKISHO_MASTER_KEY` at boot. KMS /
  secrets-manager integration is a deliberate fast-follow, not v0.1 - confirmed
  acceptable for the first cut.
- Out of scope for v0.1: rate limiting beyond budgets, mTLS, per-request
  signing, key rotation automation, secrets-manager/KMS integration.

## Consequences

**Positive.**

- One control point for keys, cost, budgets, and audit across every team,
  language, and tool - the org's stated need.
- Vertex and the public APIs are one abstraction; data-residency (Vertex-only)
  deployments are config, not a fork.
- Secrets are encrypted at rest and hashed where possible; a DB leak is not a
  key leak.

**Negative.**

- The gateway is now a critical-path dependency and a high-value target;
  hardening (key rotation, KMS/secrets-manager, mTLS) is deferred and must land
  before broad production use.
- Streaming is supported but adds complexity: sekisho buffers each stream in
  memory to extract usage, and must keep the passthrough faithful (chunk
  boundaries, client disconnects). This is accepted as the cost of working with
  Claude Code (which streams by default).
- No format translation: a client must use the format matching its key's
  upstream. Cross-format routing and provider fallback are later ADRs.
