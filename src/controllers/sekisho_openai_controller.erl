-module(sekisho_openai_controller).
-moduledoc "OpenAI Chat Completions lane: `POST /openai/v1/chat/completions`.".

-export([chat/1]).

chat(Req) ->
    sekisho_gateway:forward(openai, Req).
