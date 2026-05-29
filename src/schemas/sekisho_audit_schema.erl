-module(sekisho_audit_schema).
-moduledoc "Append-only audit trail of requests and admin actions. No secrets.".

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"sekisho_audit_log".

fields() ->
    [
        #kura_field{name = id, type = string, primary_key = true, nullable = false},
        %% request | key_issued | key_disabled | budget_exceeded | upstream_error
        #kura_field{name = event, type = string, nullable = false},
        #kura_field{name = virtual_key_id, type = string, nullable = true},
        #kura_field{name = team, type = string, nullable = true},
        #kura_field{name = model, type = string, nullable = true},
        %% JSON detail, guaranteed free of credentials and full key tokens.
        #kura_field{name = detail, type = jsonb, nullable = true},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false}
    ].
