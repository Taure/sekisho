-module(m20260529043926_update_schema).
-moduledoc false.
-behaviour(kura_migration).
-include_lib("kura/include/kura.hrl").
-export([up/0, down/0]).

-spec up() -> [kura_migration:operation()].
up() ->
    [{create_table, ~"sekisho_audit_log", [
        #kura_column{name = id, type = string, primary_key = true, nullable = false},
        #kura_column{name = event, type = string, nullable = false},
        #kura_column{name = virtual_key_id, type = string},
        #kura_column{name = team, type = string},
        #kura_column{name = model, type = string},
        #kura_column{name = detail, type = jsonb},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, ~"sekisho_upstreams", [
        #kura_column{name = id, type = string, primary_key = true, nullable = false},
        #kura_column{name = name, type = string, nullable = false},
        #kura_column{name = format, type = string, nullable = false},
        #kura_column{name = base_url, type = string, nullable = false},
        #kura_column{name = auth_mode, type = string, nullable = false},
        #kura_column{name = credential_enc, type = binary, nullable = false},
        #kura_column{name = enabled, type = boolean, nullable = false, default = true},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, ~"sekisho_usage_ledger", [
        #kura_column{name = id, type = string, primary_key = true, nullable = false},
        #kura_column{name = virtual_key_id, type = string, nullable = false},
        #kura_column{name = team, type = string, nullable = false},
        #kura_column{name = upstream_id, type = string, nullable = false},
        #kura_column{name = model, type = string, nullable = false},
        #kura_column{name = input_tokens, type = bigint, nullable = false, default = 0},
        #kura_column{name = output_tokens, type = bigint, nullable = false, default = 0},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false}
    ]},
     {create_table, ~"sekisho_virtual_keys", [
        #kura_column{name = id, type = string, primary_key = true, nullable = false},
        #kura_column{name = token_hash, type = string, nullable = false},
        #kura_column{name = token_salt, type = string, nullable = false},
        #kura_column{name = team, type = string, nullable = false},
        #kura_column{name = upstream_id, type = string, nullable = false},
        #kura_column{name = budget_tokens, type = bigint},
        #kura_column{name = spent_tokens, type = bigint, nullable = false, default = 0},
        #kura_column{name = enabled, type = boolean, nullable = false, default = true},
        #kura_column{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_column{name = updated_at, type = utc_datetime, nullable = false}
    ]}].

-spec down() -> [kura_migration:operation()].
down() ->
    [{drop_table, ~"sekisho_audit_log"},
     {drop_table, ~"sekisho_upstreams"},
     {drop_table, ~"sekisho_usage_ledger"},
     {drop_table, ~"sekisho_virtual_keys"}].
