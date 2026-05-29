-module(sekisho_openai_controller).
-moduledoc """
OpenAI-format lanes:
- `POST /openai/v1/chat/completions`
- `POST /openai/v1/embeddings`
""".

-export([chat/1, embeddings/1]).

chat(Req) ->
    sekisho_gateway:forward(openai, chat, Req).

embeddings(Req) ->
    sekisho_gateway:forward(openai, embeddings, Req).
