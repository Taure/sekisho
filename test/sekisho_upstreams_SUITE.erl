-module(sekisho_upstreams_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([create_get_resolve_anthropic/1, resolve_openai/1, credential_encrypted_at_rest/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MASTER_KEY, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").

all() ->
    [create_get_resolve_anthropic, resolve_openai, credential_encrypted_at_rest].

init_per_suite(Config) ->
    os:putenv("SEKISHO_MASTER_KEY", ?MASTER_KEY),
    case application:ensure_all_started(sekisho) of
        {ok, _} -> Config;
        {error, Reason} -> {skip, {sekisho_start_failed, Reason}}
    end.

end_per_suite(_Config) ->
    application:stop(sekisho),
    ok.

create_get_resolve_anthropic(_Config) ->
    {ok, Id} = sekisho_upstreams:create(#{
        name => ~"anthropic-prod",
        format => ~"anthropic",
        base_url => ~"https://api.anthropic.com",
        auth_mode => ~"api_key",
        credential => ~"sk-ant-secret"
    }),
    {ok, Row} = sekisho_upstreams:get(Id),
    {ok, Target} = sekisho_upstreams:resolve(Row),
    ?assertEqual(~"https://api.anthropic.com", maps:get(base_url, Target)),
    Headers = maps:get(headers, Target),
    ?assertEqual(~"sk-ant-secret", proplists:get_value(~"x-api-key", Headers)),
    ?assertEqual(~"2023-06-01", proplists:get_value(~"anthropic-version", Headers)).

resolve_openai(_Config) ->
    {ok, Id} = sekisho_upstreams:create(#{
        name => ~"gemini",
        format => ~"openai",
        base_url => ~"https://generativelanguage.googleapis.com/v1beta/openai",
        auth_mode => ~"api_key",
        credential => ~"AIzaSecret"
    }),
    {ok, Row} = sekisho_upstreams:get(Id),
    {ok, #{headers := Headers}} = sekisho_upstreams:resolve(Row),
    ?assertEqual(~"Bearer AIzaSecret", proplists:get_value(~"authorization", Headers)).

credential_encrypted_at_rest(_Config) ->
    {ok, Id} = sekisho_upstreams:create(#{
        name => ~"leak-check",
        format => ~"anthropic",
        base_url => ~"https://api.anthropic.com",
        auth_mode => ~"api_key",
        credential => ~"sk-plaintext-secret"
    }),
    {ok, Row} = sekisho_upstreams:get(Id),
    Enc = maps:get(credential_enc, Row),
    ?assertEqual(nomatch, binary:match(Enc, ~"sk-plaintext-secret")),
    ?assertEqual(~"sk-plaintext-secret", sekisho_crypto:decrypt(Enc)).
