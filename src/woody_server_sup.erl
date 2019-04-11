-module(woody_server_sup).
-behaviour(supervisor).

-export([child_spec/1]).

-export([start_link/2]).
-export([init/1]).

%%

-spec child_spec([supervisor:child_spec()]) ->
    supervisor:child_spec().
child_spec(Children) ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, Children},
        restart => permanent,
        shutdown => infinity,
        type => supervisor
    }.

%% supervisor callbacks

start_link(RanchSpec, DrainSpec) ->
    supervisor:start_link(?MODULE, [RanchSpec, DrainSpec]).

init(Specs) ->
    SupFlags = #{strategy => one_for_all}, %%@todo maybe needs to be configurable
    {ok, {SupFlags, Specs}}.
