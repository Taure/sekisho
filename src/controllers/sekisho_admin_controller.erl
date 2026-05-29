-module(sekisho_admin_controller).
-moduledoc """
Admin endpoints to register upstreams and issue virtual keys. Guarded by a
bearer token compared against `SEKISHO_ADMIN_TOKEN` (constant-time). The issued
virtual key is returned once; provider credentials are write-only (never read
back).
""".

-include_lib("kernel/include/logger.hrl").

-export([create_upstream/1, issue_key/1]).

create_upstream(Req) ->
    with_admin(Req, fun(Body) ->
        #{
            ~"name" := Name,
            ~"format" := Format,
            ~"base_url" := BaseUrl,
            ~"auth_mode" := AuthMode,
            ~"credential" := Credential
        } = Body,
        case
            sekisho_upstreams:create(#{
                name => Name,
                format => Format,
                base_url => BaseUrl,
                auth_mode => AuthMode,
                credential => Credential
            })
        of
            {ok, Id} ->
                {status, 201, jh(), j(#{id => Id})};
            {error, Reason} ->
                ?LOG_ERROR(#{event => create_upstream_failed, reason => Reason}),
                {status, 500, jh(), j(#{error => ~"internal error"})}
        end
    end).

issue_key(Req) ->
    with_admin(Req, fun(Body) ->
        Team = maps:get(~"team", Body),
        UpstreamId = maps:get(~"upstream_id", Body),
        Budget =
            case maps:get(~"budget_tokens", Body, null) of
                null -> infinity;
                N when is_integer(N) -> N
            end,
        case sekisho_keys:issue(Team, UpstreamId, Budget) of
            {ok, #{id := Id, token := Token}} ->
                {status, 201, jh(), j(#{id => Id, token => Token})};
            {error, Reason} ->
                ?LOG_ERROR(#{event => issue_key_failed, reason => Reason}),
                {status, 500, jh(), j(#{error => ~"internal error"})}
        end
    end).

with_admin(Req0, Fun) ->
    case admin_authorised(Req0) of
        true ->
            {ok, Body, _Req1} = cowboy_req:read_body(Req0),
            try
                Fun(json:decode(Body))
            catch
                _:_ -> {status, 400, jh(), j(#{error => ~"bad request"})}
            end;
        false ->
            {status, 401, jh(), j(#{error => ~"unauthorized"})}
    end.

admin_authorised(Req) ->
    Expected = list_to_binary(os:getenv("SEKISHO_ADMIN_TOKEN", "")),
    case cowboy_req:header(~"authorization", Req) of
        <<"Bearer ", Token/binary>> when byte_size(Expected) > 0 -> constant_eq(Token, Expected);
        _ -> false
    end.

constant_eq(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    ceq(A, B, 0);
constant_eq(_, _) ->
    false.

ceq(<<>>, <<>>, Acc) -> Acc =:= 0;
ceq(<<X, A/binary>>, <<Y, B/binary>>, Acc) -> ceq(A, B, Acc bor (X bxor Y)).

jh() -> #{~"content-type" => ~"application/json"}.
j(Map) -> iolist_to_binary(json:encode(Map)).
