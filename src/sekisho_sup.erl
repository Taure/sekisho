-module(sekisho_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{
            id => sekisho_token_cache,
            start => {sekisho_token_cache, start_link, []}
        }
    ],
    {ok, {#{strategy => one_for_one}, Children}}.
