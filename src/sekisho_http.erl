-module(sekisho_http).
-moduledoc """
Shared outbound HTTP settings. Every call that carries a provider credential or
mints a GCP token must verify the server certificate - otherwise a MITM harvests
the secret in transit.
""".

-export([ssl_opts/0]).

-doc "TLS options enforcing peer + hostname verification against the OS CA store.".
-spec ssl_opts() -> [ssl:tls_client_option()].
ssl_opts() ->
    [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {depth, 99},
        {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}
    ].
