-module(sekisho_stub_upstream).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    {ok, Body, Req1} = cowboy_req:read_body(Req0),
    Path = cowboy_req:path(Req1),
    Req =
        case is_stream(Body) of
            true -> stream_sse(Path, Req1);
            false -> json_reply(Path, Req1)
        end,
    {ok, Req, State}.

is_stream(Body) ->
    try json:decode(Body) of
        #{~"stream" := true} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

json_reply(~"/v1/messages", Req) ->
    Resp =
        ~"{\"id\":\"msg_1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":7}}",
    cowboy_req:reply(200, json_ct(), Resp, Req);
json_reply(~"/chat/completions", Req) ->
    Resp =
        ~"{\"id\":\"chatcmpl_1\",\"choices\":[],\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":5}}",
    cowboy_req:reply(200, json_ct(), Resp, Req);
json_reply(_Path, Req) ->
    cowboy_req:reply(200, json_ct(), ~"{}", Req).

stream_sse(Path, Req0) ->
    Req = cowboy_req:stream_reply(200, #{~"content-type" => ~"text/event-stream"}, Req0),
    %% two chunks, to exercise the gateway's chunk relay loop
    {Head, Tail} = sse(Path),
    ok = cowboy_req:stream_body(Head, nofin, Req),
    ok = cowboy_req:stream_body(Tail, fin, Req),
    Req.

sse(~"/v1/messages") ->
    {
        ~"event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":11,\"output_tokens\":1}}}\n\n",
        ~"event: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":7}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    };
sse(_OpenAI) ->
    {
        ~"data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n",
        ~"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":5}}\n\ndata: [DONE]\n\n"
    }.

json_ct() -> #{~"content-type" => ~"application/json"}.
