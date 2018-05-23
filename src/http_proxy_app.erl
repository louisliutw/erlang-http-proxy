-module(http_proxy_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    ibrowse:start(),
    lager:start(),
    Dispatch = cowboy_router:compile([
            {'_', [ { '_', toppage_handler, [] } ] }
        ]),
    %{ok, Port} = application:get_env(port),
    {ok, Port} = application:get_env(http_proxy, port, {ok, 8080}),
    {ok, Timeout} = application:get_env(http_proxy, timeout, {ok, 10000}),
    %{ok, Workers} = application:get_env(workers),
    {ok, _} = cowboy:start_clear(http,
        [{port, Port}],
	#{env => #{dispatch => Dispatch}, request_timeout => Timeout}
    ),
    http_proxy_sup:start_link().

stop(_State) ->
    ok.
