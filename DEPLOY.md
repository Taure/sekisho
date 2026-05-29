# Deploying sekisho

sekisho is one deployable Nova service (the LLM gateway). It ships a `Dockerfile`
that builds a self-contained release, so it runs on any container platform. You
supply a PostgreSQL database and the secrets via environment, then mint upstreams
and virtual keys over the admin API once it is up.

## Run

```bash
docker build -t sekisho .
docker run -p 8080:8080 \
  -e SEKISHO_DB=sekisho -e SEKISHO_DB_HOST=... -e SEKISHO_DB_PORT=5432 \
  -e SEKISHO_DB_USER=... -e SEKISHO_DB_PASSWORD=... \
  -e SEKISHO_MASTER_KEY=... -e SEKISHO_ADMIN_TOKEN=... \
  sekisho
```

| Variable | Required | Notes |
| --- | --- | --- |
| `SEKISHO_DB`, `SEKISHO_DB_HOST`, `SEKISHO_DB_PORT`, `SEKISHO_DB_USER`, `SEKISHO_DB_PASSWORD` | yes | Postgres connection. |
| `SEKISHO_MASTER_KEY` | yes | 32-byte hex (or base64); encrypts provider creds at rest. Generate once, keep it. |
| `SEKISHO_ADMIN_TOKEN` | yes | bearer token guarding `/admin/*`. |
| `PORT` | no | listener port (default 8080). |

The schema is created at boot (`kura_migrator:migrate/1`). Check `GET /health`.

## Configure providers + keys

Upstreams (your real provider credentials, encrypted) and virtual keys are
runtime state in the database, not in the image. Seed them once with the admin
token:

```bash
BASE=https://your-sekisho.example.com
ADMIN=$SEKISHO_ADMIN_TOKEN

# An Anthropic upstream (chat lane)
curl -sX POST "$BASE/admin/upstreams" -H "authorization: Bearer $ADMIN" \
  -d '{"name":"anthropic","format":"anthropic","base_url":"https://api.anthropic.com","auth_mode":"api_key","credential":"sk-ant-..."}'

# An OpenAI-format embeddings upstream (OpenAI / Voyage / Gemini OpenAI-compat)
curl -sX POST "$BASE/admin/upstreams" -H "authorization: Bearer $ADMIN" \
  -d '{"name":"embeddings","format":"openai","base_url":"https://api.openai.com","auth_mode":"api_key","credential":"sk-..."}'

# Mint a virtual key for a team/consumer (the token is returned once)
curl -sX POST "$BASE/admin/keys" -H "authorization: Bearer $ADMIN" \
  -d '{"team":"my-app","upstream_id":"<upstream-id>","budget_tokens":2000000}'
```

Consumers then call `POST /anthropic/v1/messages`, `POST /openai/v1/chat/completions`,
or `POST /openai/v1/embeddings` with the virtual key as `authorization: Bearer ...`
or `x-api-key: ...`.
