-module(sekisho_keys_tests).
-include_lib("eunit/include/eunit.hrl").

parse_valid_test() ->
    ?assertEqual(
        {ok, ~"abc123", ~"deadbeef"},
        sekisho_keys:parse_token(~"sk-sekisho-abc123-deadbeef")
    ).

parse_rejects_foreign_prefix_test() ->
    ?assertEqual(error, sekisho_keys:parse_token(~"sk-ant-abc-def")).

parse_rejects_short_test() ->
    ?assertEqual(error, sekisho_keys:parse_token(~"sk-sekisho")).

hash_is_deterministic_test() ->
    Salt = crypto:strong_rand_bytes(16),
    Secret = crypto:strong_rand_bytes(32),
    ?assertEqual(sekisho_keys:hash_secret(Salt, Secret), sekisho_keys:hash_secret(Salt, Secret)).

hash_varies_by_salt_test() ->
    Secret = crypto:strong_rand_bytes(32),
    ?assertNotEqual(
        sekisho_keys:hash_secret(crypto:strong_rand_bytes(16), Secret),
        sekisho_keys:hash_secret(crypto:strong_rand_bytes(16), Secret)
    ).
