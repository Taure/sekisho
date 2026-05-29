-module(sekisho_gateway).
-moduledoc """
The forward path shared by both lanes. Authenticates the virtual key, enforces
the budget, resolves the upstream, forwards the request (rewriting only what the
upstream needs), accounts the usage, and returns the provider's response.

Streaming (`stream: true`) is handled by buffering the upstream SSE and replaying
it as a single `text/event-stream` body - protocol-correct, with usage accounted.
True incremental push-streaming is a fast-follow (needs a Nova streaming handler;
Nova finalises the reply after a controller, so a controller cannot push chunks).
""".

-include_lib("kernel/include/logger.hrl").

-export([forward/2]).
%% Pure helpers, exported for unit tests.
-export([key_from_headers/1, target_url/5, rewrite_body/4, usage/2]).

-define(TIMEOUT, 120_000).
-define(VERTEX_ANTHROPIC_VERSION, ~"vertex-2023-10-16").

-doc "Forward an Anthropic- or OpenAI-format request through the gateway.".
-spec forward(anthropic | openai, cowboy_req:req()) -> tuple().
forward(Lane, Req0) ->
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
                    forward_authorized(Lane, Key, Body)
            end
    end.

forward_authorized(Lane, Key, Body) ->
    {ok, Upstream} = sekisho_upstreams:get(maps:get(upstream_id, Key)),
    Format = atom_to_binary(Lane),
    case sekisho_upstreams:resolve(Upstream) of
        {ok, #{base_url := BaseUrl, auth_mode := AuthMode, headers := AuthHeaders}} ->
            BodyMap = json:decode(Body),
            Model = maps:get(~"model", BodyMap, ~"unknown"),
            Stream = maps:get(~"stream", BodyMap, false) =:= true,
            Sent = rewrite_body(Format, AuthMode, BodyMap, Stream),
            Url = target_url(Format, AuthMode, BaseUrl, Sent, Stream),
            do_request(Format, Key, Model, Url, AuthHeaders, Sent, Stream);
        {error, Reason} ->
            ?LOG_ERROR(#{event => upstream_resolve_failed, reason => Reason}),
            {status, 502, json_headers(), json(#{error => ~"upstream unavailable"})}
    end.

do_request(Format, Key, Model, Url, AuthHeaders, BodyMap, Stream) ->
    ensure_started(),
    Headers = http_headers(AuthHeaders),
    Request = {
        binary_to_list(Url), Headers, "application/json", iolist_to_binary(json:encode(BodyMap))
    },
    HttpOpts = [{timeout, ?TIMEOUT}, {ssl, sekisho_http:ssl_opts()}],
    case httpc:request(post, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            {In, Out} = extract_usage(Format, RespBody, Stream),
            _ = sekisho_ledger:record(Key, Model, In, Out),
            {status, 200, resp_headers(Stream), RespBody};
        {ok, {{_, Code, _}, _RespHeaders, RespBody}} ->
            {status, Code, resp_headers(Stream), RespBody};
        {error, Reason} ->
            ?LOG_ERROR(#{event => upstream_request_failed, reason => Reason}),
            {status, 502, json_headers(), json(#{error => ~"upstream error"})}
    end.

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

-doc "Build the upstream URL for a request (per format, auth mode, and stream flag).".
-spec target_url(binary(), binary(), binary(), map(), boolean()) -> binary().
target_url(~"anthropic", ~"api_key", Base, _Body, _Stream) ->
    <<Base/binary, "/v1/messages">>;
target_url(~"openai", _AuthMode, Base, _Body, _Stream) ->
    <<Base/binary, "/chat/completions">>;
target_url(~"anthropic", ~"gcp_oauth", Base, Body, Stream) ->
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

extract_usage(Format, RespBody, false) ->
    usage(Format, json:decode(RespBody));
extract_usage(Format, RespBody, true) ->
    usage(Format, last_sse_object(RespBody)).

-doc "Pull `{input, output}` tokens from a decoded provider response.".
-spec usage(binary(), map()) -> {non_neg_integer(), non_neg_integer()}.
usage(~"anthropic", #{~"usage" := #{~"input_tokens" := In, ~"output_tokens" := Out}}) ->
    {In, Out};
usage(~"openai", #{~"usage" := #{~"prompt_tokens" := In, ~"completion_tokens" := Out}}) ->
    {In, Out};
usage(_Format, _Other) ->
    {0, 0}.

%% The last `data:` JSON object in an SSE body that carries a usage field.
last_sse_object(Body) ->
    Lines = binary:split(Body, ~"\n", [global]),
    Objects = [decode_data(L) || L <- Lines, is_data_line(L)],
    last_with_usage(Objects).

is_data_line(<<"data:", _/binary>>) -> true;
is_data_line(_) -> false.

decode_data(<<"data:", Rest/binary>>) ->
    Trimmed = string:trim(Rest),
    try
        json:decode(Trimmed)
    catch
        _:_ -> #{}
    end.

last_with_usage(Objects) ->
    last_with_usage(Objects, #{}).

last_with_usage([], Acc) ->
    Acc;
last_with_usage([#{~"usage" := U} = Obj | Rest], _Acc) when is_map(U) ->
    last_with_usage(Rest, Obj);
last_with_usage([_ | Rest], Acc) ->
    last_with_usage(Rest, Acc).

%% --- helpers ---

http_headers(AuthHeaders) ->
    [{binary_to_list(K), binary_to_list(V)} || {K, V} <- AuthHeaders].

resp_headers(true) ->
    #{~"content-type" => ~"text/event-stream"};
resp_headers(false) ->
    json_headers().

json_headers() ->
    #{~"content-type" => ~"application/json"}.

json(Map) ->
    iolist_to_binary(json:encode(Map)).

ensure_started() ->
    _ = inets:start(),
    _ = ssl:start(),
    ok.
