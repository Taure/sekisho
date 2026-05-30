-module(sekisho_gateway).
-moduledoc """
The forward path shared by both lanes. Authenticates the virtual key, enforces
the budget, resolves the upstream, forwards the request (rewriting only what the
upstream needs), accounts the usage, and returns the provider's response.

Non-streaming requests are forwarded synchronously and returned as a buffered
body. Streaming requests (`stream: true`) use true SSE passthrough: the
controller returns `{stream, ...}`, picked up by a Nova return-handler
(`handle_stream/3`, registered via `register/0`). That handler forwards to the
upstream with `httpc` async streaming, relays each chunk to the client with
`cowboy_req:stream_body/3`, accounts usage at `stream_end`, and then exits -
never returning, so Nova's post-handler `cowboy_req:reply` (which would crash
with `{response_already_sent}`) never runs. The stream-vs-error decision is made
before `stream_reply`, so an upstream that errors still yields a clean status.
This mirrors the `gakudan_liveboard_sse` pattern (see novaframework/nova#387).
""".

-include_lib("kernel/include/logger.hrl").

%% handle_stream/3's 2nd arg is Nova's controller callback - part of the
%% return-handler contract, unused here.
-hank([{unnecessary_function_arguments, [{handle_stream, 3, 2}]}]).

-export([forward/2, forward/3, register/0, handle_stream/3]).
%% Pure helpers, exported for unit tests.
-export([key_from_headers/1, target_url/6, rewrite_body/4, usage/3, stream_usage/2]).
-export([upstream_error_body/2]).

-define(TIMEOUT, 120_000).
-define(VERTEX_ANTHROPIC_VERSION, ~"vertex-2023-10-16").

-doc "Register the `{stream, ...}` Nova return-handler. Call once at app start.".
-spec register() -> ok | {error, atom()}.
register() ->
    nova_handlers:register_handler(stream, fun ?MODULE:handle_stream/3).

-doc "Forward a chat request (Anthropic Messages / OpenAI Chat Completions).".
-spec forward(anthropic | openai, cowboy_req:req()) -> tuple().
forward(Lane, Req0) ->
    forward(Lane, chat, Req0).

-doc "Forward a request for a given operation (`chat` or `embeddings`).".
-spec forward(anthropic | openai, chat | embeddings, cowboy_req:req()) -> tuple().
forward(Lane, Op, Req0) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    case authenticate(Req1) of
        {error, _} ->
            {status, 401, json_headers(), json(#{error => ~"invalid api key"})};
        {ok, Key} ->
            case over_budget(Key) of
                true ->
                    _ = sekisho_audit:write(#{
                        event => ~"budget_exceeded",
                        virtual_key_id => maps:get(id, Key),
                        team => maps:get(team, Key)
                    }),
                    {status, 429, json_headers(), json(#{error => ~"token budget exceeded"})};
                false ->
                    forward_authorized(Lane, Op, Key, Body)
            end
    end.

forward_authorized(Lane, Op, Key, Body) ->
    {ok, Upstream} = sekisho_upstreams:get(maps:get(upstream_id, Key)),
    Format = atom_to_binary(Lane),
    case sekisho_upstreams:resolve(Upstream) of
        {ok, #{base_url := BaseUrl, auth_mode := AuthMode, headers := AuthHeaders}} ->
            BodyMap = json:decode(Body),
            Model = maps:get(~"model", BodyMap, ~"unknown"),
            %% Only chat streams; embeddings have no streaming semantics.
            Stream = (maps:get(~"stream", BodyMap, false) =:= true) andalso Op =:= chat,
            Sent = rewrite_body(Format, AuthMode, BodyMap, Stream),
            Url = target_url(Format, Op, AuthMode, BaseUrl, Sent, Stream),
            case Stream of
                true ->
                    {stream, 200, sse_headers(), #{
                        url => Url,
                        auth_headers => AuthHeaders,
                        body => Sent,
                        format => Format,
                        key => Key,
                        model => Model
                    }};
                false ->
                    do_request(Format, Op, Key, Model, Url, AuthHeaders, Sent)
            end;
        {error, Reason} ->
            ?LOG_ERROR(#{event => upstream_resolve_failed, reason => Reason}),
            {status, 502, json_headers(), json(#{error => ~"upstream unavailable"})}
    end.

%% --- non-streaming forward ---

do_request(Format, Op, Key, Model, Url, AuthHeaders, BodyMap) ->
    ensure_started(),
    Request = {
        binary_to_list(Url),
        http_headers(AuthHeaders),
        "application/json",
        iolist_to_binary(json:encode(BodyMap))
    },
    HttpOpts = [{timeout, ?TIMEOUT}, {ssl, sekisho_http:ssl_opts()}],
    case httpc:request(post, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            {In, Out} = usage(Format, Op, json:decode(RespBody)),
            _ = sekisho_ledger:record(Key, Model, In, Out),
            {status, 200, json_headers(), RespBody};
        {ok, {{_, Code, _}, _RespHeaders, RespBody}} ->
            {status, Code, json_headers(), upstream_error_body(Code, RespBody)};
        {error, Reason} ->
            ?LOG_ERROR(#{event => upstream_request_failed, reason => Reason}),
            {status, 502, json_headers(), json(#{error => ~"upstream error"})}
    end.

%% --- streaming forward (true SSE passthrough) ---

-doc "Nova `{stream, ...}` return-handler. Holds the connection; never returns on success.".
handle_stream({stream, Code, Headers, Spec}, _Callback, Req0) ->
    ensure_started(),
    #{url := Url, auth_headers := AuthHeaders, body := Body} = Spec,
    Request = {
        binary_to_list(Url),
        [{"accept", "text/event-stream"} | http_headers(AuthHeaders)],
        "application/json",
        iolist_to_binary(json:encode(Body))
    },
    HttpOpts = [{timeout, ?TIMEOUT}, {ssl, sekisho_http:ssl_opts()}],
    AsyncOpts = [{sync, false}, {stream, self}, {body_format, binary}],
    case httpc:request(post, Request, HttpOpts, AsyncOpts) of
        {ok, ReqId} ->
            await_first(ReqId, Code, Headers, Req0, Spec);
        {error, Reason} ->
            ?LOG_ERROR(#{event => upstream_stream_failed, reason => Reason}),
            error_reply(Req0, 502, ~"upstream error")
    end.

%% Decide stream-vs-error from the first async message, before stream_reply.
await_first(ReqId, Code, Headers, Req0, Spec) ->
    receive
        {http, {ReqId, stream_start, _Hdrs}} ->
            Req = cowboy_req:stream_reply(Code, Headers, Req0),
            relay(ReqId, Req, Spec, <<>>);
        {http, {ReqId, {{_, UpCode, _}, _Hdrs, UpBody}}} ->
            %% Non-2xx: httpc does not stream it. Pass the provider status + body
            %% through as a normal buffered reply (masked when configured).
            passthrough_reply(Req0, UpCode, upstream_error_body(UpCode, UpBody));
        {http, {ReqId, {error, Reason}}} ->
            ?LOG_ERROR(#{event => upstream_stream_error, reason => Reason}),
            error_reply(Req0, 502, ~"upstream error")
    after ?TIMEOUT ->
        _ = httpc:cancel_request(ReqId),
        error_reply(Req0, 504, ~"upstream timeout")
    end.

%% Relay each upstream chunk to the client, accumulating for usage accounting.
relay(ReqId, Req, Spec, Acc) ->
    receive
        {http, {ReqId, stream, Chunk}} ->
            ok = cowboy_req:stream_body(Chunk, nofin, Req),
            relay(ReqId, Req, Spec, <<Acc/binary, Chunk/binary>>);
        {http, {ReqId, stream_end, _Hdrs}} ->
            %% Account before fin, so usage is durable before the client sees the
            %% stream complete.
            account_stream(Spec, Acc),
            ok = cowboy_req:stream_body(<<>>, fin, Req),
            exit(normal);
        {http, {ReqId, {error, Reason}}} ->
            ?LOG_ERROR(#{event => upstream_stream_interrupted, reason => Reason}),
            _ = cowboy_req:stream_body(<<>>, fin, Req),
            exit(normal)
    after ?TIMEOUT ->
        _ = httpc:cancel_request(ReqId),
        _ = cowboy_req:stream_body(<<>>, fin, Req),
        exit(normal)
    end.

account_stream(#{format := Format, key := Key, model := Model}, Acc) ->
    {In, Out} = stream_usage(Format, Acc),
    _ = sekisho_ledger:record(Key, Model, In, Out),
    ok.

%% Buffered reply built without stream_reply, so Nova's render_response replies.
error_reply(Req0, Code, Message) ->
    passthrough_reply(Req0, Code, json(#{error => Message})).

passthrough_reply(Req0, Code, Body) ->
    Req1 = cowboy_req:set_resp_headers(json_headers(), Req0),
    Req2 = cowboy_req:set_resp_body(Body, Req1#{resp_status_code => Code}),
    {ok, Req2}.

%% --- auth ---

authenticate(Req) ->
    case key_from_headers(cowboy_req:headers(Req)) of
        {ok, Token} -> sekisho_keys:verify(Token);
        error -> {error, no_key}
    end.

-doc "Extract the virtual key from `authorization: Bearer ...` or `x-api-key`.".
-spec key_from_headers(map()) -> {ok, binary()} | error.
key_from_headers(Headers) ->
    case Headers of
        #{~"authorization" := <<"Bearer ", Token/binary>>} -> {ok, Token};
        #{~"x-api-key" := Token} when is_binary(Token) -> {ok, Token};
        _ -> error
    end.

over_budget(#{budget_tokens := Budget, spent_tokens := Spent}) when is_integer(Budget) ->
    Spent >= Budget;
over_budget(_) ->
    false.

%% --- target + body rewriting (pure) ---

-doc "Build the upstream URL for a request (per format, operation, auth mode, and stream flag).".
-spec target_url(binary(), chat | embeddings, binary(), binary(), map(), boolean()) -> binary().
target_url(~"anthropic", chat, ~"api_key", Base, _Body, _Stream) ->
    <<Base/binary, "/v1/messages">>;
target_url(~"openai", chat, _AuthMode, Base, _Body, _Stream) ->
    <<Base/binary, "/chat/completions">>;
target_url(~"openai", embeddings, _AuthMode, Base, _Body, _Stream) ->
    <<Base/binary, "/embeddings">>;
target_url(~"anthropic", chat, ~"gcp_oauth", Base, Body, Stream) ->
    Model = maps:get(~"model", Body, ~""),
    Action =
        case Stream of
            true -> ~":streamRawPredict";
            false -> ~":rawPredict"
        end,
    <<Base/binary, "/publishers/anthropic/models/", Model/binary, Action/binary>>.

-doc "Rewrite the request body only as the upstream requires.".
-spec rewrite_body(binary(), binary(), map(), boolean()) -> map().
rewrite_body(~"anthropic", ~"gcp_oauth", Body, _Stream) ->
    %% Vertex carries the version in the body and the model in the URL.
    (maps:remove(~"model", Body))#{~"anthropic_version" => ?VERTEX_ANTHROPIC_VERSION};
rewrite_body(~"openai", _AuthMode, Body, true) ->
    %% Without this, Gemini's OpenAI-compat stream omits the final usage chunk.
    Opts = maps:get(~"stream_options", Body, #{}),
    Body#{~"stream_options" => Opts#{~"include_usage" => true}};
rewrite_body(_Format, _AuthMode, Body, _Stream) ->
    Body.

%% --- usage extraction ---

-doc """
Pull `{input, output}` tokens from a decoded (non-stream) provider response.
Embeddings responses carry only `prompt_tokens` (no completion), so output is 0.
""".
-spec usage(binary(), chat | embeddings, map()) -> {non_neg_integer(), non_neg_integer()}.
usage(~"anthropic", chat, #{~"usage" := #{~"input_tokens" := In, ~"output_tokens" := Out}}) ->
    {In, Out};
usage(~"openai", chat, #{~"usage" := #{~"prompt_tokens" := In, ~"completion_tokens" := Out}}) ->
    {In, Out};
usage(~"openai", embeddings, #{~"usage" := #{~"prompt_tokens" := In}}) ->
    {In, 0};
usage(_Format, _Op, _Other) ->
    {0, 0}.

-doc """
Pull `{input, output}` tokens from an accumulated SSE stream body. OpenAI puts
both in the final usage chunk; Anthropic splits them across `message_start`
(input) and the last `message_delta` (output).
""".
-spec stream_usage(binary(), binary()) -> {non_neg_integer(), non_neg_integer()}.
stream_usage(~"openai", Body) ->
    usage(~"openai", chat, last_with_usage(sse_objects(Body), #{}));
stream_usage(~"anthropic", Body) ->
    Objects = sse_objects(Body),
    {anthropic_input(Objects), anthropic_output(Objects, 0)};
stream_usage(_Format, _Body) ->
    {0, 0}.

sse_objects(Body) ->
    [decode_data(L) || L <- binary:split(Body, ~"\n", [global]), is_data_line(L)].

is_data_line(<<"data:", _/binary>>) -> true;
is_data_line(_) -> false.

decode_data(<<"data:", Rest/binary>>) ->
    try
        json:decode(string:trim(Rest))
    catch
        _:_ -> #{}
    end.

last_with_usage([], Acc) -> Acc;
last_with_usage([#{~"usage" := U} = Obj | Rest], _Acc) when is_map(U) -> last_with_usage(Rest, Obj);
last_with_usage([_ | Rest], Acc) -> last_with_usage(Rest, Acc).

anthropic_input([#{~"message" := #{~"usage" := #{~"input_tokens" := N}}} | _]) -> N;
anthropic_input([_ | Rest]) -> anthropic_input(Rest);
anthropic_input([]) -> 0.

anthropic_output([#{~"usage" := #{~"output_tokens" := M}} | Rest], _Acc) ->
    anthropic_output(Rest, M);
anthropic_output([_ | Rest], Acc) ->
    anthropic_output(Rest, Acc);
anthropic_output([], Acc) ->
    Acc.

%% --- helpers ---

http_headers(AuthHeaders) ->
    [{binary_to_list(K), binary_to_list(V)} || {K, V} <- AuthHeaders].

sse_headers() ->
    #{~"content-type" => ~"text/event-stream", ~"cache-control" => ~"no-cache"}.

json_headers() ->
    #{~"content-type" => ~"application/json"}.

json(Map) ->
    iolist_to_binary(json:encode(Map)).

-doc """
The body to return for a non-2xx upstream response. Passthrough (the provider's
raw body) by default; a generic masked body when `mask_upstream_errors` is set.
See ADR 0004. The upstream status code is preserved by the caller either way.
""".
-spec upstream_error_body(non_neg_integer(), binary()) -> binary().
upstream_error_body(Code, RawBody) ->
    case application:get_env(sekisho, mask_upstream_errors, false) of
        true ->
            ?LOG_INFO(#{event => upstream_error_masked, status => Code}),
            json(#{error => ~"upstream error"});
        false ->
            RawBody
    end.

ensure_started() ->
    _ = inets:start(),
    _ = ssl:start(),
    ok.
