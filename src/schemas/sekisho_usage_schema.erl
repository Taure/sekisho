-module(sekisho_usage_schema).
-moduledoc "One row per forwarded request: the authoritative token usage.".

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"sekisho_usage_ledger".

fields() ->
    [
        #kura_field{name = id, type = string, primary_key = true, nullable = false},
        #kura_field{name = virtual_key_id, type = string, nullable = false},
        #kura_field{name = team, type = string, nullable = false},
        #kura_field{name = upstream_id, type = string, nullable = false},
        #kura_field{name = model, type = string, nullable = false},
        #kura_field{name = input_tokens, type = bigint, nullable = false, default = 0},
        #kura_field{name = output_tokens, type = bigint, nullable = false, default = 0},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].
