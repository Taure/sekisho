-module(sekisho_upstreams).
-moduledoc """
The upstream store and resolver. An upstream is a configured provider target;
its credential is encrypted at rest. `resolve/1` turns a stored upstream into a
ready-to-forward target: the base URL plus the auth headers, decrypting the
credential (and minting a GCP token for `gcp_oauth`) transiently.
""".

-export([create/1, get/1, resolve/1]).

-define(SCHEMA, sekisho_upstream_schema).

-type spec() :: #{
    name := binary(),
    format := binary(),
    base_url := binary(),
    auth_mode := binary(),
    credential := binary()
}.

-type target() :: #{
    base_url := binary(),
    format := binary(),
    auth_mode := binary(),
    headers := [{binary(), binary()}]
}.

-doc "Create an upstream, encrypting its credential at rest. Returns the id.".
-spec create(spec()) -> {ok, binary()} | {error, term()}.
create(#{
    name := Name, format := Format, base_url := BaseUrl, auth_mode := AuthMode, credential := Cred
}) ->
    Id = binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
    Now = calendar:universal_time(),
    Changes = #{
        id => Id,
        name => Name,
        format => Format,
        base_url => BaseUrl,
        auth_mode => AuthMode,
        credential_enc => sekisho_crypto:encrypt(Cred),
        enabled => true,
        inserted_at => Now,
        updated_at => Now
    },
    CS = kura_changeset:cast(?SCHEMA, #{}, Changes, [
        id, name, format, base_url, auth_mode, credential_enc, enabled, inserted_at, updated_at
    ]),
    case sekisho_repo:insert(CS) of
        {ok, _Row} -> {ok, Id};
        {error, _} = Err -> Err
    end.

-doc "Fetch an upstream row by id.".
-spec get(binary()) -> {ok, map()} | {error, not_found}.
get(Id) ->
    case sekisho_repo:get(?SCHEMA, Id) of
        {ok, #{} = Row} -> {ok, Row};
        _ -> {error, not_found}
    end.

-doc "Resolve a stored upstream into a forward target (base URL + auth headers).".
-spec resolve(map()) -> {ok, target()} | {error, term()}.
resolve(#{
    id := Id, format := Format, base_url := BaseUrl, auth_mode := AuthMode, credential_enc := Enc
}) ->
    Cred = sekisho_crypto:decrypt(Enc),
    case headers(AuthMode, Format, Id, Cred) of
        {ok, Headers} ->
            {ok, #{
                base_url => BaseUrl, format => Format, auth_mode => AuthMode, headers => Headers
            }};
        {error, _} = Err ->
            Err
    end.

headers(~"api_key", ~"anthropic", _Id, Key) ->
    {ok, [{~"x-api-key", Key}, {~"anthropic-version", ~"2023-06-01"}]};
headers(~"api_key", ~"openai", _Id, Key) ->
    {ok, [{~"authorization", <<"Bearer ", Key/binary>>}]};
headers(~"gcp_oauth", _Format, Id, ServiceAccountJson) ->
    case sekisho_token_cache:token(Id, json:decode(ServiceAccountJson)) of
        {ok, Token} -> {ok, [{~"authorization", <<"Bearer ", Token/binary>>}]};
        {error, _} = Err -> Err
    end.
