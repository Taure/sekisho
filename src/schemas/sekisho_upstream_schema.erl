-module(sekisho_upstream_schema).
-moduledoc "A configured provider target. Credentials are stored encrypted.".

-behaviour(kura_schema).

-include_lib("kura/include/kura.hrl").

-export([table/0, fields/0]).

table() -> ~"sekisho_upstreams".

fields() ->
    [
        #kura_field{name = id, type = string, primary_key = true, nullable = false},
        #kura_field{name = name, type = string, nullable = false},
        %% anthropic | openai
        #kura_field{name = format, type = string, nullable = false},
        #kura_field{name = base_url, type = string, nullable = false},
        %% api_key | gcp_oauth
        #kura_field{name = auth_mode, type = string, nullable = false},
        %% AES-256-GCM: nonce || tag || ciphertext. Never logged or returned.
        #kura_field{name = credential_enc, type = binary, nullable = false},
        #kura_field{name = enabled, type = boolean, nullable = false, default = true},
        #kura_field{name = inserted_at, type = utc_datetime, nullable = false},
        #kura_field{name = updated_at, type = utc_datetime, nullable = false}
    ].
