-module(sekisho_gateway_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    anthropic_lane_proxies_and_accounts/1,
    openai_lane_proxies/1,
    openai_embeddings_proxies_and_accounts/1,
    budget_enforced/1,
    invalid_key_rejected/1,
    admin_requires_token/1,
    admin_issue_via_api/1,
    upstream_error_is_generic/1,
    atomic_budget_under_concurrency/1,
    anthropic_stream_proxies_and_accounts/1,
    openai_stream_proxies_and_accounts/1
]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MASTER_KEY, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef").
-define(STUB, stub_upstream).

all() ->
    [
        anthropic_lane_proxies_and_accounts,
        openai_lane_proxies,
        openai_embeddings_proxies_and_accounts,
        budget_enforced,
        invalid_key_rejected,
        admin_requires_token,
        admin_issue_via_api,
        upstream_error_is_generic,
        atomic_budget_under_concurrency,
        anthropic_stream_proxies_and_accounts,
        openai_stream_proxies_and_accounts
    ].

init_per_suite(Config) ->
    os:putenv("SEKISHO_MASTER_KEY", ?MASTER_KEY),
    {ok, _} = application:ensure_all_started(sekisho),
    {ok, _} = application:ensure_all_started(inets),
    Dispatch = cowboy_router:compile([{'_', [{"/[...]", sekisho_stub_upstream, []}]}]),
    {ok, _} = cowboy:start_clear(?STUB, [{port, 0}], #{env => #{dispatch => Dispatch}}),
    [
        {stub_base, list_to_binary("http://127.0.0.1:" ++ integer_to_list(ranch:get_port(?STUB)))}
        | Config
    ].

end_per_suite(_Config) ->
    _ = cowboy:stop_listener(?STUB),
    application:stop(sekisho),
    ok.

anthropic_lane_proxies_and_accounts(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-anthropic",
        format => ~"anthropic",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"sk-stub"
    }),
    {ok, #{id := KeyId, token := Token}} = sekisho_keys:issue(~"team-x", UpId, 1000),
    {Code, Resp} = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
    ?assertEqual(200, Code),
    ?assertMatch(#{~"id" := ~"msg_1"}, json:decode(Resp)),
    %% usage was recorded (11 + 7) and the key's spend bumped
    [Row] = ledger_rows(KeyId),
    ?assertEqual(11, maps:get(input_tokens, Row)),
    ?assertEqual(7, maps:get(output_tokens, Row)),
    {ok, Key} = sekisho_upstreams_get_key(KeyId),
    ?assertEqual(18, maps:get(spent_tokens, Key)).

openai_lane_proxies(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-openai",
        format => ~"openai",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"AIza-stub"
    }),
    {ok, #{token := Token}} = sekisho_keys:issue(~"team-y", UpId, infinity),
    {Code, Resp} = post("/openai/v1/chat/completions", Token, #{
        ~"model" => ~"gemini", ~"messages" => []
    }),
    ?assertEqual(200, Code),
    ?assertMatch(#{~"id" := ~"chatcmpl_1"}, json:decode(Resp)).

openai_embeddings_proxies_and_accounts(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-embeddings",
        format => ~"openai",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"AIza-stub"
    }),
    {ok, #{id := KeyId, token := Token}} = sekisho_keys:issue(~"team-e", UpId, infinity),
    {Code, Resp} = post("/openai/v1/embeddings", Token, #{
        ~"model" => ~"text-embedding-3-small", ~"input" => ~"hello"
    }),
    ?assertEqual(200, Code),
    ?assertMatch(#{~"object" := ~"list"}, json:decode(Resp)),
    %% prompt_tokens accounted as input, output 0
    [Row] = ledger_rows(KeyId),
    ?assertEqual(9, maps:get(input_tokens, Row)),
    ?assertEqual(0, maps:get(output_tokens, Row)),
    {ok, Key} = sekisho_upstreams_get_key(KeyId),
    ?assertEqual(9, maps:get(spent_tokens, Key)).

budget_enforced(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-budget",
        format => ~"anthropic",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"sk-stub"
    }),
    {ok, #{token := Token}} = sekisho_keys:issue(~"team-z", UpId, 5),
    {Code1, _} = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
    ?assertEqual(200, Code1),
    %% first request spent 18 > budget 5; the next is rejected
    {Code2, _} = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
    ?assertEqual(429, Code2).

invalid_key_rejected(_Config) ->
    {Code, _} = post("/anthropic/v1/messages", ~"sk-sekisho-deadbeef-cafebabe", #{
        ~"model" => ~"claude"
    }),
    ?assertEqual(401, Code).

admin_requires_token(_Config) ->
    os:unsetenv("SEKISHO_ADMIN_TOKEN"),
    {Code, _} = admin_post("/admin/keys", ~"anything", #{}),
    ?assertEqual(401, Code).

admin_issue_via_api(Config) ->
    Base = ?config(stub_base, Config),
    os:putenv("SEKISHO_ADMIN_TOKEN", "admin-secret"),
    {C1, R1} = admin_post("/admin/upstreams", ~"admin-secret", #{
        name => ~"via-api",
        format => ~"anthropic",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"sk-x"
    }),
    ?assertEqual(201, C1),
    #{~"id" := UpId} = json:decode(R1),
    {C2, R2} = admin_post("/admin/keys", ~"admin-secret", #{
        team => ~"t", upstream_id => UpId, budget_tokens => 1000
    }),
    ?assertEqual(201, C2),
    #{~"token" := Token} = json:decode(R2),
    {C3, _} = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
    ?assertEqual(200, C3).

upstream_error_is_generic(_Config) ->
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"refused",
        format => ~"anthropic",
        base_url => ~"https://127.0.0.1:1",
        auth_mode => ~"api_key",
        credential => ~"sk-x"
    }),
    {ok, #{token := Token}} = sekisho_keys:issue(~"t", UpId, infinity),
    {Code, Resp} = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
    ?assertEqual(502, Code),
    %% generic message only - no internal error term leaked
    ?assertEqual(#{~"error" => ~"upstream error"}, json:decode(Resp)).

atomic_budget_under_concurrency(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"conc",
        format => ~"anthropic",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"sk-x"
    }),
    {ok, #{id := KeyId, token := Token}} = sekisho_keys:issue(~"t", UpId, infinity),
    Self = self(),
    N = 10,
    [
        spawn(fun() ->
            _ = post("/anthropic/v1/messages", Token, #{~"model" => ~"claude", ~"messages" => []}),
            Self ! done
        end)
     || _ <- lists:seq(1, N)
    ],
    [
        receive
            done -> ok
        end
     || _ <- lists:seq(1, N)
    ],
    {ok, Key} = sekisho_repo:get(sekisho_virtual_key_schema, KeyId),
    %% atomic increment: every concurrent forward counted, none lost (N * 18)
    ?assertEqual(N * 18, maps:get(spent_tokens, Key)).

anthropic_stream_proxies_and_accounts(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-stream-a",
        format => ~"anthropic",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"sk-stub"
    }),
    {ok, #{id := KeyId, token := Token}} = sekisho_keys:issue(~"team-s", UpId, infinity),
    {Code, CT, Resp} = post_stream("/anthropic/v1/messages", Token, #{
        ~"model" => ~"claude", ~"messages" => [], ~"stream" => true
    }),
    ?assertEqual(200, Code),
    ?assertMatch(<<"text/event-stream", _/binary>>, CT),
    ?assertNotEqual(nomatch, binary:match(Resp, ~"message_stop")),
    [Row] = ledger_rows(KeyId),
    ?assertEqual(11, maps:get(input_tokens, Row)),
    ?assertEqual(7, maps:get(output_tokens, Row)).

openai_stream_proxies_and_accounts(Config) ->
    Base = ?config(stub_base, Config),
    {ok, UpId} = sekisho_upstreams:create(#{
        name => ~"stub-stream-o",
        format => ~"openai",
        base_url => Base,
        auth_mode => ~"api_key",
        credential => ~"AIza-stub"
    }),
    {ok, #{id := KeyId, token := Token}} = sekisho_keys:issue(~"team-s", UpId, infinity),
    {Code, CT, Resp} = post_stream("/openai/v1/chat/completions", Token, #{
        ~"model" => ~"gemini", ~"messages" => [], ~"stream" => true
    }),
    ?assertEqual(200, Code),
    ?assertMatch(<<"text/event-stream", _/binary>>, CT),
    ?assertNotEqual(nomatch, binary:match(Resp, ~"[DONE]")),
    [Row] = ledger_rows(KeyId),
    ?assertEqual(13, maps:get(input_tokens, Row)),
    ?assertEqual(5, maps:get(output_tokens, Row)).

%% --- helpers ---

post_stream(Path, Token, BodyMap) ->
    Url = "http://127.0.0.1:8080" ++ Path,
    Body = iolist_to_binary(json:encode(BodyMap)),
    Headers = [{"x-api-key", binary_to_list(Token)}],
    {ok, {{_, Code, _}, RespHeaders, Resp}} =
        httpc:request(post, {Url, Headers, "application/json", Body}, [], [{body_format, binary}]),
    CT = list_to_binary(proplists:get_value("content-type", RespHeaders, "")),
    {Code, CT, Resp}.

admin_post(Path, Token, BodyMap) ->
    Url = "http://127.0.0.1:8080" ++ Path,
    Body = iolist_to_binary(json:encode(BodyMap)),
    Headers = [{"authorization", "Bearer " ++ binary_to_list(Token)}],
    {ok, {{_, Code, _}, _H, Resp}} =
        httpc:request(post, {Url, Headers, "application/json", Body}, [], [{body_format, binary}]),
    {Code, Resp}.

post(Path, Token, BodyMap) ->
    Url = "http://127.0.0.1:8080" ++ Path,
    Body = iolist_to_binary(json:encode(BodyMap)),
    Headers = [{"x-api-key", binary_to_list(Token)}],
    {ok, {{_, Code, _}, _H, Resp}} =
        httpc:request(post, {Url, Headers, "application/json", Body}, [], [{body_format, binary}]),
    {Code, Resp}.

ledger_rows(KeyId) ->
    Q0 = kura_query:from(sekisho_usage_schema),
    Q1 = kura_query:where(Q0, {virtual_key_id, '=', KeyId}),
    {ok, Rows} = sekisho_repo:all(Q1),
    Rows.

sekisho_upstreams_get_key(KeyId) ->
    sekisho_repo:get(sekisho_virtual_key_schema, KeyId).
