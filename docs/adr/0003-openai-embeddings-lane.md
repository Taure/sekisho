# 3. OpenAI embeddings lane

Date: 2026-05-29

## Status

Accepted (v0.1). Extends the OpenAI-format lane from
[ADR 0001](0001-gateway-security-model.md).

## Context

v0.1 shipped two chat lanes (Anthropic Messages, OpenAI Chat Completions). A
gateway that meters and audits chat traffic but ignores **embeddings** leaves a
hole: embeddings are a primary cost driver for any RAG/memory workload, so a
consumer that needs them has to call the provider directly, bypassing the
gateway's key custody, budgets, and audit trail for that traffic. This surfaced
while building `banto` (a multi-agent repo concierge that indexes repos into a
vector store) - exactly the kind of consumer sekisho exists to sit in front of.

## Decision

Add an **OpenAI-format embeddings lane**: `POST /openai/v1/embeddings`, routed to
`sekisho_openai_controller:embeddings/1`, which forwards through the same gateway
path as chat. Embeddings reuse auth, budget enforcement, upstream resolution,
credential custody, and audit unchanged - only two things differ, both modelled
by a new `Op :: chat | embeddings` parameter threaded through
`forward/3 -> target_url/6 -> usage/3`:

- **Target path.** `target_url(~"openai", embeddings, _, Base, _, _)` appends
  `/embeddings` instead of `/chat/completions`.
- **Usage accounting.** An embeddings response carries only `prompt_tokens` (no
  completion), so `usage(~"openai", embeddings, _)` returns `{prompt_tokens, 0}`.
  The ledger and budget thus count embeddings input tokens with zero output.

Embeddings have no streaming semantics, so the streaming path is forced off for
`Op =:= embeddings` regardless of a `stream` flag in the body. Anthropic has no
embeddings API, so there is no Anthropic embeddings lane.

This stays within the v0.1 "passthrough, not translation" pillar: the OpenAI
embeddings wire format forwards unchanged to an OpenAI-format upstream (OpenAI,
Voyage, Gemini's OpenAI-compat endpoint).

## Consequences

**Positive.**

- Embeddings traffic now gets the same key custody, budgets, and audit as chat -
  the gateway is complete for RAG/memory consumers.
- No new auth mode, schema change, or secret-handling change: the forward path,
  credential decryption, and budget enforcement are untouched.

**Negative.**

- The lane is OpenAI-format only. A non-OpenAI embeddings wire shape would need
  another `usage/3` clause and a target-path clause.
- Token accounting trusts the upstream's `usage.prompt_tokens`; an upstream that
  omits usage on embeddings is accounted as zero (same trust model as chat).
