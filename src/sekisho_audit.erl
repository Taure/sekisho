-module(sekisho_audit).
-moduledoc """
Append-only audit writer. Callers must pass only non-secret fields - never a
provider credential or a full virtual key. `detail` is a JSON map.
""".

-export([write/1]).

-define(SCHEMA, sekisho_audit_schema).

-type fields() :: #{
    event := binary(),
    virtual_key_id => binary(),
    team => binary(),
    model => binary(),
    detail => map()
}.

-doc "Append an audit row. Returns the insert result.".
-spec write(fields()) -> {ok, map()} | {error, term()}.
write(Fields) ->
    Base = #{
        id => binary:encode_hex(crypto:strong_rand_bytes(16), lowercase),
        event => maps:get(event, Fields),
        inserted_at => calendar:universal_time()
    },
    Changes = maps:merge(Base, maps:with([virtual_key_id, team, model, detail], Fields)),
    CS = kura_changeset:cast(?SCHEMA, #{}, Changes, [
        id, event, virtual_key_id, team, model, detail, inserted_at
    ]),
    sekisho_repo:insert(CS).
