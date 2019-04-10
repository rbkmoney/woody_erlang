-module(woody_server_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(RanchSpec, DrainSpec) ->
    supervisor:start_link(?MODULE, [RanchSpec, DrainSpec]).

init(Specs) ->
    SupFlags = #{strategy => one_for_all}, %%@todo maybe needs to be configurable
    {ok, {SupFlags, Specs}}.
