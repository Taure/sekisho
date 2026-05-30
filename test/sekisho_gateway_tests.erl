-module(sekisho_gateway_tests).
-include_lib("eunit/include/eunit.hrl").

%% --- key_from_headers ---

key_from_bearer_test() ->
    ?assertEqual(
        {ok, ~"vk123"}, sekisho_gateway:key_from_headers(#{~"authorization" => ~"Bearer vk123"})
    ).

key_from_x_api_key_test() ->
    ?assertEqual({ok, ~"vk456"}, sekisho_gateway:key_from_headers(#{~"x-api-key" => ~"vk456"})).

key_absent_test() ->
    ?assertEqual(error, sekisho_gateway:key_from_headers(#{~"accept" => ~"application/json"})).

%% --- target_url ---

target_anthropic_public_test() ->
    ?assertEqual(
        ~"https://api.anthropic.com/v1/messages",
        sekisho_gateway:target_url(
            ~"anthropic", chat, ~"api_key", ~"https://api.anthropic.com", #{}, false
        )
    ).

target_openai_public_test() ->
    ?assertEqual(
        ~"https://gen.googleapis.com/v1beta/openai/chat/completions",
        sekisho_gateway:target_url(
            ~"openai", chat, ~"api_key", ~"https://gen.googleapis.com/v1beta/openai", #{}, false
        )
    ).

target_openai_embeddings_test() ->
    ?assertEqual(
        ~"https://gen.googleapis.com/v1beta/openai/embeddings",
        sekisho_gateway:target_url(
            ~"openai",
            embeddings,
            ~"api_key",
            ~"https://gen.googleapis.com/v1beta/openai",
            #{},
            false
        )
    ).

target_anthropic_vertex_test() ->
    Base = ~"https://eu-aiplatform.googleapis.com/v1/projects/p/locations/eu",
    ?assertEqual(
        <<Base/binary, "/publishers/anthropic/models/claude-x:rawPredict">>,
        sekisho_gateway:target_url(
            ~"anthropic", chat, ~"gcp_oauth", Base, #{~"model" => ~"claude-x"}, false
        )
    ).

target_anthropic_vertex_stream_test() ->
    Base = ~"https://eu-aiplatform.googleapis.com/v1/projects/p/locations/eu",
    Url = sekisho_gateway:target_url(
        ~"anthropic", chat, ~"gcp_oauth", Base, #{~"model" => ~"claude-x"}, true
    ),
    ?assertEqual(nomatch =/= binary:match(Url, ~":streamRawPredict"), true).

%% --- rewrite_body ---

rewrite_vertex_anthropic_test() ->
    Out = sekisho_gateway:rewrite_body(
        ~"anthropic", ~"gcp_oauth", #{~"model" => ~"claude-x", ~"max_tokens" => 10}, false
    ),
    ?assertNot(maps:is_key(~"model", Out)),
    ?assertEqual(~"vertex-2023-10-16", maps:get(~"anthropic_version", Out)).

rewrite_openai_stream_injects_usage_test() ->
    Out = sekisho_gateway:rewrite_body(~"openai", ~"api_key", #{~"model" => ~"gemini"}, true),
    ?assertEqual(true, maps:get(~"include_usage", maps:get(~"stream_options", Out))).

rewrite_noop_test() ->
    In = #{~"model" => ~"claude", ~"max_tokens" => 5},
    ?assertEqual(In, sekisho_gateway:rewrite_body(~"anthropic", ~"api_key", In, false)).

%% --- usage ---

usage_anthropic_test() ->
    ?assertEqual(
        {11, 7},
        sekisho_gateway:usage(~"anthropic", chat, #{
            ~"usage" => #{~"input_tokens" => 11, ~"output_tokens" => 7}
        })
    ).

usage_openai_test() ->
    ?assertEqual(
        {13, 5},
        sekisho_gateway:usage(~"openai", chat, #{
            ~"usage" => #{~"prompt_tokens" => 13, ~"completion_tokens" => 5}
        })
    ).

usage_openai_embeddings_test() ->
    %% embeddings carry only prompt_tokens; output is 0
    ?assertEqual(
        {9, 0},
        sekisho_gateway:usage(~"openai", embeddings, #{
            ~"usage" => #{~"prompt_tokens" => 9, ~"total_tokens" => 9}
        })
    ).

usage_missing_test() ->
    ?assertEqual({0, 0}, sekisho_gateway:usage(~"anthropic", chat, #{~"content" => []})).

%% --- upstream_error_body (ADR 0004) ---

upstream_error_passthrough_default_test() ->
    application:unset_env(sekisho, mask_upstream_errors),
    Raw = ~"{\"error\":{\"type\":\"not_found_error\",\"message\":\"model: x\"}}",
    ?assertEqual(Raw, sekisho_gateway:upstream_error_body(404, Raw)).

upstream_error_masked_when_enabled_test() ->
    application:set_env(sekisho, mask_upstream_errors, true),
    try
        Raw = ~"{\"error\":{\"message\":\"provider detail\"}}",
        Masked = sekisho_gateway:upstream_error_body(404, Raw),
        ?assertNotEqual(Raw, Masked),
        ?assertEqual(nomatch, binary:match(Masked, ~"provider detail")),
        ?assertNotEqual(nomatch, binary:match(Masked, ~"upstream error"))
    after
        application:unset_env(sekisho, mask_upstream_errors)
    end.
