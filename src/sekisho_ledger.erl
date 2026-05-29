-module(sekisho_ledger).
-moduledoc """
Records token usage for a forwarded request: a ledger row, a bump of the key's
running `spent_tokens`, and an audit entry - in one transaction so accounting
and budget state never diverge.
""".

-export([record/4]).

-define(USAGE, sekisho_usage_schema).

-doc "Record `{InputTokens, OutputTokens}` against a verified key + its upstream.".
-spec record(map(), binary(), non_neg_integer(), non_neg_integer()) -> ok | {error, term()}.
record(#{id := KeyId, team := Team, upstream_id := UpstreamId} = Key, Model, In, Out) ->
    sekisho_repo:transaction(fun() ->
        {ok, _} = insert_usage(KeyId, Team, UpstreamId, Model, In, Out),
        {ok, _} = bump_spent(Key, In + Out),
        _ = sekisho_audit:write(#{
            event => ~"request",
            virtual_key_id => KeyId,
            team => Team,
            model => Model,
            detail => #{input_tokens => In, output_tokens => Out}
        }),
        ok
    end).

insert_usage(KeyId, Team, UpstreamId, Model, In, Out) ->
    Changes = #{
        id => binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
        virtual_key_id => KeyId,
        team => Team,
        upstream_id => UpstreamId,
        model => Model,
        input_tokens => In,
        output_tokens => Out,
        inserted_at => calendar:universal_time()
    },
    CS = kura_changeset:cast(?USAGE, #{}, Changes, [
        id, virtual_key_id, team, upstream_id, model, input_tokens, output_tokens, inserted_at
    ]),
    sekisho_repo:insert(CS).

%% Atomic increment: a read-modify-write would lose updates under concurrent
%% requests on the same key, making the budget gate unreliable.
bump_spent(#{id := KeyId}, Add) ->
    sekisho_repo:query(
        ~"UPDATE sekisho_virtual_keys SET spent_tokens = spent_tokens + $1, updated_at = now() WHERE id = $2",
        [Add, KeyId]
    ).
