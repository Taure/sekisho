-module(sekisho_crypto_tests).
-include_lib("eunit/include/eunit.hrl").

setup() ->
    {ok, _} = application:ensure_all_started(crypto),
    Key = binary:encode_hex(crypto:strong_rand_bytes(32), lowercase),
    os:putenv("SEKISHO_MASTER_KEY", binary_to_list(Key)),
    ok.

crypto_test_() ->
    {setup, fun setup/0, [
        ?_test(roundtrip()),
        ?_test(distinct_nonces()),
        ?_test(tamper_detected()),
        ?_test(base64_key())
    ]}.

roundtrip() ->
    Plain = ~"sk-ant-secret-provider-key",
    ?assertEqual(Plain, sekisho_crypto:decrypt(sekisho_crypto:encrypt(Plain))).

distinct_nonces() ->
    Plain = ~"same plaintext",
    ?assertNotEqual(sekisho_crypto:encrypt(Plain), sekisho_crypto:encrypt(Plain)).

tamper_detected() ->
    <<Head:8/binary, Rest/binary>> = sekisho_crypto:encrypt(~"payload"),
    Flipped = <<(binary:first(Head) bxor 1), (binary:part(Head, 1, 7))/binary, Rest/binary>>,
    ?assertError(decrypt_failed, sekisho_crypto:decrypt(Flipped)).

base64_key() ->
    Raw = crypto:strong_rand_bytes(32),
    os:putenv("SEKISHO_MASTER_KEY", binary_to_list(base64:encode(Raw, #{padding => false}))),
    ?assertEqual(Raw, sekisho_crypto:master_key()).
