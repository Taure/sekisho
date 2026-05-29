-module(sekisho_keys).
-moduledoc """
Virtual-key issuance and verification.

A token is `sk-sekisho-<id>-<secret>`: the `id` is the (non-secret) row id, used
for an O(1) lookup; the `secret` is verified against a per-key salted SHA-256
hash. The plaintext token is returned once at issue time and never stored - the
database holds only `sha256(salt || secret)` and the salt.
""".

-export([issue/3, verify/1]).
%% Exported for unit tests (pure, no database).
-export([parse_token/1, hash_secret/2]).

-define(SCHEMA, sekisho_virtual_key_schema).

-doc """
Issue a virtual key for a team against an upstream, with an optional token
budget (`infinity` for unlimited). Returns the plaintext token once.
""".
-spec issue(binary(), binary(), non_neg_integer() | infinity) ->
    {ok, #{id := binary(), token := binary()}} | {error, term()}.
issue(Team, UpstreamId, Budget) when is_binary(Team), is_binary(UpstreamId) ->
    Id = rand_hex(16),
    SecretRaw = crypto:strong_rand_bytes(32),
    SaltRaw = crypto:strong_rand_bytes(16),
    SecretHex = binary:encode_hex(SecretRaw, lowercase),
    Now = calendar:universal_time(),
    Base = #{
        id => Id,
        token_hash => hash_secret(SaltRaw, SecretRaw),
        token_salt => binary:encode_hex(SaltRaw, lowercase),
        team => Team,
        upstream_id => UpstreamId,
        spent_tokens => 0,
        enabled => true,
        inserted_at => Now,
        updated_at => Now
    },
    Changes = maybe_budget(Base, Budget),
    CS = kura_changeset:cast(?SCHEMA, #{}, Changes, [
        id,
        token_hash,
        token_salt,
        team,
        upstream_id,
        budget_tokens,
        spent_tokens,
        enabled,
        inserted_at,
        updated_at
    ]),
    case sekisho_repo:insert(CS) of
        {ok, _Row} ->
            {ok, #{id => Id, token => <<"sk-sekisho-", Id/binary, "-", SecretHex/binary>>}};
        {error, _} = Err ->
            Err
    end.

-doc """
Verify a presented token. Returns the key row on success, or `{error, invalid}`
/ `{error, disabled}`. Never logs the token.
""".
-spec verify(binary()) -> {ok, map()} | {error, invalid | disabled}.
verify(Token) when is_binary(Token) ->
    case parse_token(Token) of
        {ok, Id, SecretHex} -> verify_secret(Id, SecretHex);
        error -> {error, invalid}
    end;
verify(_) ->
    {error, invalid}.

verify_secret(Id, SecretHex) ->
    case sekisho_repo:get(?SCHEMA, Id) of
        {ok, #{token_hash := Hash, token_salt := SaltHex, enabled := Enabled} = Row} ->
            SaltRaw = binary:decode_hex(SaltHex),
            SecretRaw = binary:decode_hex(SecretHex),
            case constant_eq(hash_secret(SaltRaw, SecretRaw), Hash) of
                true when Enabled -> {ok, Row};
                true -> {error, disabled};
                false -> {error, invalid}
            end;
        _ ->
            {error, invalid}
    end.

-doc "Parse `sk-sekisho-<id>-<secret>` into its id and secret (hex) parts.".
-spec parse_token(binary()) -> {ok, binary(), binary()} | error.
parse_token(Token) ->
    case binary:split(Token, ~"-", [global]) of
        [~"sk", ~"sekisho", Id, Secret] when byte_size(Id) > 0, byte_size(Secret) > 0 ->
            {ok, Id, Secret};
        _ ->
            error
    end.

-doc "Lowercase hex of `sha256(salt || secret)`.".
-spec hash_secret(binary(), binary()) -> binary().
hash_secret(SaltRaw, SecretRaw) ->
    binary:encode_hex(crypto:hash(sha256, <<SaltRaw/binary, SecretRaw/binary>>), lowercase).

maybe_budget(Base, infinity) -> Base;
maybe_budget(Base, N) when is_integer(N), N >= 0 -> Base#{budget_tokens => N}.

rand_hex(Bytes) ->
    binary:encode_hex(crypto:strong_rand_bytes(Bytes), lowercase).

%% Constant-time comparison over equal-length binaries (no early exit).
constant_eq(A, B) when is_binary(A), is_binary(B), byte_size(A) =:= byte_size(B) ->
    ceq(A, B, 0);
constant_eq(_, _) ->
    false.

ceq(<<>>, <<>>, Acc) -> Acc =:= 0;
ceq(<<X, A/binary>>, <<Y, B/binary>>, Acc) -> ceq(A, B, Acc bor (X bxor Y)).
