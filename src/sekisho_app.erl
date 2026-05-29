-module(sekisho_app).
-behaviour(application).

-include_lib("kernel/include/logger.hrl").

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ok = run_migrations(),
    sekisho_sup:start_link().

stop(_State) ->
    ok.

run_migrations() ->
    case kura_migrator:migrate(sekisho_repo) of
        {ok, Applied} ->
            ?LOG_INFO(#{event => migrations_applied, count => length(Applied)});
        {error, Reason} ->
            %% Don't block boot: liveness endpoints stay up and the failure is
            %% visible. Data paths fail loudly until the database is reachable.
            ?LOG_ERROR(#{event => migration_failed, reason => Reason})
    end,
    ok.
