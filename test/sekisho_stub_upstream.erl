-module(sekisho_stub_upstream).
-behaviour(cowboy_handler).

-export([init/2]).

init(Req0, State) ->
    {ok, _Body, Req1} = cowboy_req:read_body(Req0),
    Resp =
        case cowboy_req:path(Req1) of
            ~"/v1/messages" ->
                ~"{\"id\":\"msg_1\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],\"usage\":{\"input_tokens\":11,\"output_tokens\":7}}";
            ~"/chat/completions" ->
                ~"{\"id\":\"chatcmpl_1\",\"choices\":[],\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":5}}";
            _ ->
                ~"{}"
        end,
    Req = cowboy_req:reply(200, #{~"content-type" => ~"application/json"}, Resp, Req1),
    {ok, Req, State}.
