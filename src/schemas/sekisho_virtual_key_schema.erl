-module(sekisho_virtual_key_schema).
-moduledoc "A per-team virtual key. Only a salted hash of the token is stored.".

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"sekisho_virtual_keys".

fields() ->
    [
        #kura_field{name = id, type = string, primary_key = true, nullable = false},
        %% sha256(salt || token), hex. The token itself is never stored.
        #kura_field{name = token_hash, type = string, nullable = false},
        #kura_field{name = token_salt, type = string, nullable = false},
        #kura_field{name = team, type = string, nullable = false},
        #kura_field{name = upstream_id, type = string, nullable = false},
        %% null = unlimited
        #kura_field{name = budget_tokens, type = bigint, nullable = true},
        #kura_field{name = spent_tokens, type = bigint, nullable = false, default = 0},
        #kura_field{name = enabled, type = boolean, nullable = false, default = true},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].
