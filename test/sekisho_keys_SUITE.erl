-module(sekisho_keys_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([issue_and_verify/1, verify_unknown_fails/1, issue_unlimited_budget/1]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

all() ->
    [issue_and_verify, verify_unknown_fails, issue_unlimited_budget].

init_per_suite(Config) ->
    case application:ensure_all_started(sekisho) of
        {ok, _} -> Config;
        {error, Reason} -> {skip, {sekisho_start_failed, Reason}}
    end.

end_per_suite(_Config) ->
    application:stop(sekisho),
    ok.

issue_and_verify(_Config) ->
    {ok, #{id := Id, token := Token}} = sekisho_keys:issue(~"team-a", ~"up-1", 1000),
    {ok, Row} = sekisho_keys:verify(Token),
    ?assertEqual(Id, maps:get(id, Row)),
    ?assertEqual(~"team-a", maps:get(team, Row)),
    ?assertEqual(1000, maps:get(budget_tokens, Row)).

verify_unknown_fails(_Config) ->
    ?assertEqual({error, invalid}, sekisho_keys:verify(~"sk-sekisho-deadbeef-cafebabe")),
    ?assertEqual({error, invalid}, sekisho_keys:verify(~"not even a token")).

issue_unlimited_budget(_Config) ->
    {ok, #{token := Token}} = sekisho_keys:issue(~"team-b", ~"up-1", infinity),
    {ok, _} = sekisho_keys:verify(Token),
    ok.
