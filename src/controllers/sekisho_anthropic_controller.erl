-module(sekisho_anthropic_controller).
-moduledoc "Anthropic Messages API lane: `POST /anthropic/v1/messages`.".

-export([messages/1]).

messages(Req) ->
    sekisho_gateway:forward(anthropic, Req).
