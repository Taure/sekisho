-module(sekisho_gcp_oauth).
-moduledoc """
Mint a Google Cloud access token from a service-account key, for Vertex
upstreams (`auth_mode => gcp_oauth`).

Implements the JWT-bearer grant: build a claim set, sign it RS256 with the
service account's private key, and exchange the assertion at the account's
`token_uri` for a short-lived bearer token. The service-account JSON is the
decrypted upstream credential; it is never logged.
""".

-export([fetch_token/1, claims/2, build_assertion/1]).

-define(SCOPE, ~"https://www.googleapis.com/auth/cloud-platform").
-define(GRANT, "urn:ietf:params:oauth:grant-type:jwt-bearer").
-define(TTL, 3600).
-define(TIMEOUT, 15_000).

-doc """
Exchange a service-account key (decoded JSON map, binary keys) for an access
token. Returns the token and its absolute expiry (epoch seconds).
""".
-spec fetch_token(map()) -> {ok, binary(), integer()} | {error, term()}.
fetch_token(Sa) ->
    ensure_started(),
    TokenUri = binary_to_list(maps:get(~"token_uri", Sa)),
    Assertion = build_assertion(Sa),
    Form = uri_string:compose_query([
        {"grant_type", ?GRANT}, {"assertion", binary_to_list(Assertion)}
    ]),
    Request = {TokenUri, [], "application/x-www-form-urlencoded", Form},
    HttpOpts = [{timeout, ?TIMEOUT}, {ssl, sekisho_http:ssl_opts()}],
    case httpc:request(post, Request, HttpOpts, [{body_format, binary}]) of
        {ok, {{_, 200, _}, _Hdrs, Body}} ->
            #{~"access_token" := Token, ~"expires_in" := ExpiresIn} = json:decode(Body),
            {ok, Token, erlang:system_time(second) + ExpiresIn};
        {ok, {{_, Code, _}, _Hdrs, Body}} ->
            {error, {token_endpoint, Code, Body}};
        {error, Reason} ->
            {error, Reason}
    end.

-doc "The signed JWT assertion for a service-account key. Pure.".
-spec build_assertion(map()) -> binary().
build_assertion(Sa) ->
    Now = erlang:system_time(second),
    Header = #{alg => ~"RS256", typ => ~"JWT"},
    SigningInput = <<
        (b64url(json:encode(Header)))/binary, ".", (b64url(json:encode(claims(Sa, Now))))/binary
    >>,
    Key = private_key(maps:get(~"private_key", Sa)),
    Signature = public_key:sign(SigningInput, sha256, Key),
    <<SigningInput/binary, ".", (b64url(Signature))/binary>>.

-doc "The JWT claim set for a service account at a point in time. Pure.".
-spec claims(map(), integer()) -> map().
claims(Sa, Now) ->
    #{
        iss => maps:get(~"client_email", Sa),
        scope => ?SCOPE,
        aud => maps:get(~"token_uri", Sa),
        iat => Now,
        exp => Now + ?TTL
    }.

private_key(Pem) ->
    [Entry] = public_key:pem_decode(Pem),
    public_key:pem_entry_decode(Entry).

b64url(Data) ->
    base64:encode(iolist_to_binary(Data), #{mode => urlsafe, padding => false}).

ensure_started() ->
    _ = inets:start(),
    _ = ssl:start(),
    ok.
