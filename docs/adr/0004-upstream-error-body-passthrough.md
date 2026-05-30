# 4. Pass through upstream error bodies, with an opt-in mask

Date: 2026-05-30

## Status

Accepted. Builds on [ADR 0001](0001-gateway-security-model.md). Resolves #6.

## Context

On a non-2xx upstream response, the gateway returns the provider's body verbatim
- in both lanes:

- buffered (`sekisho_gateway:do_request/7`): `{status, Code, json_headers(), RespBody}`
- streaming (`await_first/5` -> `passthrough_reply/3`): the provider status + body
  as a normal buffered reply (httpc does not stream non-2xx).

sekisho's *own* failures are already masked: a connection error returns a generic
`502 "upstream error"` in both lanes. Issue #6 asked whether the *provider's*
error body should also be masked.

Two facts narrow the question:

- ADR 0001's invariant is that **sekisho's** secrets (master key, virtual keys,
  decrypted credentials) are never echoed in errors. Provider error bodies do not
  contain those, so passthrough does not breach the security model.
- Response **headers** are already not reflected - both lanes send sekisho's own
  `json_headers()` - so provider headers (rate-limit, set-cookie, account hints)
  never leak regardless of this decision.

So this is a policy/DX call, not a credential-leak fix.

## Decision

**Passthrough is the default.** It is the "passthrough, not translation" pillar:
clients see real provider diagnostics ("model not found", rate-limit detail,
malformed-request specifics) and sekisho stays a drop-in for the provider.

**Add an opt-in `mask_upstream_errors` (default `false`).** When set, non-2xx
upstream bodies are replaced with the generic `{"error":"upstream error"}` body
- uniformly across the buffered and streaming lanes - while the upstream **status
code is preserved** (the code is not sensitive and clients need it). Masking logs
the upstream status server-side (`event => upstream_error_masked`), never the
body.

The masking decision lives in one helper (`upstream_error_body/2`) called at both
non-2xx sites, so the two lanes cannot drift.

## Consequences

- Default behaviour is unchanged; the gateway stays transparent.
- Conservative / multi-tenant operators who do not want to reveal which provider
  backs an upstream can set `{sekisho, [{mask_upstream_errors, true}]}`.
- **Trust assumption made explicit:** passthrough trusts the upstream not to echo
  sekisho's injected `Authorization` header back in an error body. This holds for
  the v0.1 upstreams (Anthropic, OpenAI-format, Vertex). If an *untrusted*
  upstream were ever configured, `mask_upstream_errors` should be enabled - the
  flag is the mitigation for that case.
- Minor, accepted information disclosure when unmasked: the provider's error
  *shape* reveals which provider backs an upstream.
