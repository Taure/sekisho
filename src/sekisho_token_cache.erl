-module(sekisho_token_cache).
-moduledoc """
Caches GCP access tokens per upstream, minting via `sekisho_gcp_oauth` on a miss
or near expiry. Minting is serialised through this process to avoid a stampede.
Tokens live only in process state, never logged.
""".

-behaviour(gen_server).

-export([start_link/0, token/2, invalidate/1]).
-export([init/1, handle_call/3, handle_cast/2]).

%% Refresh this many seconds before the token actually expires.
-define(SKEW, 60).

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-doc "Get a valid token for an upstream, minting from the service-account map if needed.".
-spec token(binary(), map()) -> {ok, binary()} | {error, term()}.
token(UpstreamId, ServiceAccount) ->
    gen_server:call(?MODULE, {token, UpstreamId, ServiceAccount}, 20_000).

-doc "Drop any cached token for an upstream (e.g. after a 401).".
-spec invalidate(binary()) -> ok.
invalidate(UpstreamId) ->
    gen_server:cast(?MODULE, {invalidate, UpstreamId}).

init([]) ->
    {ok, #{}}.

handle_call({token, Id, Sa}, _From, Cache) ->
    Now = erlang:system_time(second),
    case Cache of
        #{Id := {Token, ExpiresAt}} when ExpiresAt - ?SKEW > Now ->
            {reply, {ok, Token}, Cache};
        _ ->
            case sekisho_gcp_oauth:fetch_token(Sa) of
                {ok, Token, ExpiresAt} ->
                    {reply, {ok, Token}, Cache#{Id => {Token, ExpiresAt}}};
                {error, _} = Err ->
                    {reply, Err, Cache}
            end
    end.

handle_cast({invalidate, Id}, Cache) ->
    {noreply, maps:remove(Id, Cache)}.
