# AGENTS.md

Working agreement for agents and contributors on **sekisho** (関所, "barrier
checkpoint") - an LLM gateway for the BEAM. A deployable Nova service on
kura/Postgres that custodies provider credentials, issues per-team virtual keys,
accounts every request, enforces budgets, and writes an audit trail.

## Ecosystem

Part of a BEAM-native multi-agent stack (all under https://github.com/Taure):

- **[gakudan](https://github.com/Taure/gakudan)** - agent orchestration runtime.
- **[saiten](https://github.com/Taure/saiten)** - runtime-agnostic eval/scoring
  + CI gate.
- **[madoguchi](https://github.com/Taure/madoguchi)** - MCP *server* framework.
- **sekisho** - LLM gateway / control plane: virtual keys, budgets, and audit in
  front of Anthropic + OpenAI (chat and embeddings) + Vertex.
- **[bunko](https://github.com/Taure/bunko)** - agent memory + RAG (pgvector).
- **[banto](https://github.com/Taure/banto)** - multi-agent repo concierge; the
  showcase consumer that wires the pillars together.

Gakudan sister libs: **gakudan_metrics**, **gakudan_otel**, **gakudan_tickets**
(+ **gakudan_tickets_github**), **gakudan_liveboard** (Nova + Datastar
dashboard).

**This repo** is the control plane beneath everything: any agent, tool, or
service (in any language) routes its LLM traffic here for central keys, cost
attribution, budgets, and audit. It custodies provider credentials, so security
is the priority - see [ADR 0001](docs/adr/0001-gateway-security-model.md).

## Design pillars

- **Control plane, not a library.** One endpoint every team/tool points at
  instead of the provider. It is an app (Nova + kura), not a dependency.
- **Security first.** It custodies secrets. Provider credentials are encrypted
  at rest (AES-256-GCM, key from `SEKISHO_MASTER_KEY`); virtual keys are stored
  hashed; secrets are never logged, returned, or echoed in errors. See
  [ADR 0001](docs/adr/0001-gateway-security-model.md).
- **Upstreams are config.** `{format, base_url, auth_mode, credential}` - public
  APIs and Vertex differ only in config (`api_key` vs `gcp_oauth`).
- **Passthrough, not translation.** Each client wire format (Anthropic Messages,
  OpenAI Chat Completions, OpenAI Embeddings) forwards to a matching-format
  upstream. Cross-format routing is deferred.

## Scope - what belongs here

- **In (v0.1):** two lanes (Anthropic-format, OpenAI-format - chat completions +
  embeddings); four upstreams
  (Anthropic, Claude-on-Vertex, Gemini OpenAI-compat, Gemini-on-Vertex);
  virtual-key issuance + verification; provider-credential encryption; GCP
  service-account OAuth; SSE streaming passthrough with usage accounting; usage
  ledger; per-key budgets; audit log.
- **Out (deferred):** cross-format translation; provider fallback/load-balancing;
  response caching; rate limiting beyond budgets; key rotation automation;
  KMS/secrets-manager integration; mTLS.

## Commands

```bash
docker compose up -d        # Postgres for kura (port 5556)
rebar3 compile
rebar3 ct                   # Common Test against Docker Postgres
rebar3 fmt                  # erlfmt (write); CI runs fmt --check
rebar3 xref
rebar3 dialyzer
rebar3 ex_doc
```

## Conventions

- OTP 29+. The `~"..."` sigil, never `<<"...">>`.
- No `lists:foldl/foldr` - comprehensions / `maps:from_list` / named recursion.
- JSON via the OTP `json` module. Structured logging via `nova_jsonlogger` with
  `?LOG_*` map reports - and NEVER log secrets.
- Migrations are generated with `rebar3 kura`, never hand-written.
- Nova app scaffolded with the Nova generator, never hand-built.
- `{vsn, git}` - version derives from git tags.

## Security rules (non-negotiable)

- Never log, return, or error with a provider credential or a full virtual key.
- Provider credentials only ever decrypted transiently in memory for a forward.
- Enforce budgets before the upstream call.
- New auth modes, persistence changes, or anything touching secret handling get
  an ADR and a security pass before merge.

## Decisions live in ADRs

Read [docs/adr/](docs/adr/) before changing the security model, an auth mode,
the wire handling, or the schema. Write a new ADR for any such change.

## Git and PRs

Conventional commits. Always open a PR - never push to `main`. Every merge to
`main` tags a release.
