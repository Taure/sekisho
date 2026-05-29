# 2. True SSE streaming via a Nova return-handler

Date: 2026-05-29

## Status

Accepted (v0.1). Refines the streaming decision in
[ADR 0001](0001-gateway-security-model.md).

## Context

ADR 0001 put streaming in scope: a client sending `stream: true` should get a
real `text/event-stream` passthrough so tools that stream by default (Claude
Code) work through the gateway. The obstacle is Nova's request lifecycle: after
a controller returns, nova_handler's render_response unconditionally calls
`cowboy_req:reply/2`. A controller that itself called `cowboy_req:stream_reply`
would then hit a second reply and crash with `{response_already_sent}`. So a
plain Nova controller cannot push SSE frames.

`gakudan_liveboard` already solved this for its live run dashboard, and its
pattern is the reference here.

## Decision

Stream from a **registered Nova return-handler that holds the connection and
never returns** on the success path.

- `sekisho_gateway:register/0` calls
  `nova_handlers:register_handler(stream, fun sekisho_gateway:handle_stream/3)`
  at app start. It is registered as a bare `fun/3` (Nova's `{Mod, Fun}` form
  wraps to arity 4 and mismatches the 3-arg handler call).
- The lane controller authenticates, enforces the budget, resolves the upstream,
  and - for a streaming request - returns `{stream, 200, Headers, Spec}` where
  `Spec` carries the resolved URL, auth headers, rewritten body, format, key,
  and model. Non-streaming requests are unchanged (buffered reply).
- `handle_stream/3` forwards to the upstream with `httpc` async streaming
  (`{sync, false}, {stream, self}`) and then:
  - **decides stream-vs-error before `stream_reply`.** It waits for the first
    async message. `stream_start` means a 2xx stream: only then does it call
    `cowboy_req:stream_reply/3`. A non-2xx response (httpc delivers it whole,
    not streamed) or a connection error is returned as a normal buffered reply
    (`{ok, Req}` with a status set), so render_response replies cleanly. This is
    why an upstream failure still yields a correct status instead of a half-open
    stream.
  - **relays each chunk** with `cowboy_req:stream_body(Chunk, nofin, Req)`,
    accumulating the bytes to extract usage.
  - on `stream_end`, **accounts usage first** (so the ledger row is durable
    before the client sees completion), sends the final `fin` frame, and
    **`exit(normal)`** - never returning to `render_response`, so the second
    `cowboy_req:reply` never runs. On client disconnect, Cowboy terminates the
    request process.

Usage from a stream is parsed at the end: OpenAI puts `prompt_tokens` /
`completion_tokens` in the final usage chunk (enabled via
`stream_options.include_usage`); Anthropic splits it across `message_start`
(input) and the last `message_delta` (output).

## Consequences

**Positive.**

- Real low-latency SSE passthrough - the gateway is transparent to streaming
  clients, and usage is still accounted.
- Upstream errors before the stream starts return a proper status, not a broken
  stream.
- No Nova fork and no second Cowboy listener; just a registered handler.

**Negative.**

- The handler runs the upstream call in the Cowboy request process and
  `exit(normal)`s to finish - a deliberate break from Nova's return convention,
  justified by the `render_response` double-reply constraint.
- A client disconnect mid-stream relies on Cowboy tearing down the process; the
  in-flight `httpc` request is not explicitly cancelled in that path (a v0.2
  cleanup).
- Usage parsing is provider-shape-specific; a new provider shape needs a new
  `stream_usage/2` clause.
