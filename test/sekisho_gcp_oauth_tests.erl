-module(sekisho_gcp_oauth_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

gen_sa() ->
    {ok, _} = application:ensure_all_started(crypto),
    Key = public_key:generate_key({rsa, 2048, 65537}),
    Pem = public_key:pem_encode([public_key:pem_entry_encode('RSAPrivateKey', Key)]),
    Sa = #{
        ~"client_email" => ~"svc@proj.iam.gserviceaccount.com",
        ~"token_uri" => ~"https://oauth2.googleapis.com/token",
        ~"private_key" => Pem
    },
    {Key, Sa}.

claims_test() ->
    {_Key, Sa} = gen_sa(),
    C = sekisho_gcp_oauth:claims(Sa, 1000),
    ?assertEqual(~"svc@proj.iam.gserviceaccount.com", maps:get(iss, C)),
    ?assertEqual(~"https://oauth2.googleapis.com/token", maps:get(aud, C)),
    ?assertEqual(~"https://www.googleapis.com/auth/cloud-platform", maps:get(scope, C)),
    ?assertEqual(1000, maps:get(iat, C)),
    ?assertEqual(1000 + 3600, maps:get(exp, C)).

assertion_has_three_parts_test() ->
    {_Key, Sa} = gen_sa(),
    ?assertEqual(3, length(binary:split(sekisho_gcp_oauth:build_assertion(Sa), ~".", [global]))).

assertion_signature_verifies_test() ->
    {Key, Sa} = gen_sa(),
    [H, C, S] = binary:split(sekisho_gcp_oauth:build_assertion(Sa), ~".", [global]),
    SigningInput = <<H/binary, ".", C/binary>>,
    Sig = base64:decode(S, #{mode => urlsafe, padding => false}),
    #'RSAPrivateKey'{modulus = N, publicExponent = E} = Key,
    Pub = #'RSAPublicKey'{modulus = N, publicExponent = E},
    ?assert(public_key:verify(SigningInput, sha256, Sig, Pub)).
