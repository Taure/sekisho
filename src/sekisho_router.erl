-module(sekisho_router).
-behaviour(nova_router).

-export([
    routes/1
]).

%% The Environment-variable is defined in your sys.config in {nova, [{environment, Value}]}
routes(_Environment) ->
    [
        #{
            prefix => "",
            security => false,
            routes => [
                {"/", fun(_) -> {json, #{service => ~"sekisho", status => ~"ok"}} end, #{
                    methods => [get]
                }},
                {"/health", fun(_) -> {status, 200} end, #{methods => [get]}},
                {"/anthropic/v1/messages", fun sekisho_anthropic_controller:messages/1, #{
                    methods => [post]
                }},
                {"/openai/v1/chat/completions", fun sekisho_openai_controller:chat/1, #{
                    methods => [post]
                }},
                {"/openai/v1/embeddings", fun sekisho_openai_controller:embeddings/1, #{
                    methods => [post]
                }},
                {"/admin/upstreams", fun sekisho_admin_controller:create_upstream/1, #{
                    methods => [post]
                }},
                {"/admin/keys", fun sekisho_admin_controller:issue_key/1, #{methods => [post]}}
            ]
        }
    ].
