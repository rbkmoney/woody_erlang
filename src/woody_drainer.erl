-module(woody_drainer).
-behaviour(gen_server).

-export([child_spec/1]).
-export([start_link/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([terminate/2]).

child_spec(Opts) ->
    RanchRef = maps:get(ranch_ref, Opts),
    Shutdown = maps:get(shutdown, Opts),
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [RanchRef]},
        shutdown => Shutdown
    }.

start_link(RanchRef) ->
    gen_server:start_link(?MODULE, RanchRef, []).

init(RanchRef) ->
    process_flag(trap_exit, true),
    {ok, RanchRef}.

handle_call(_, _, St) -> {reply, ok, St}.
handle_cast(_, St) -> {noreply, St}.

terminate(shutdown, St) ->
    %%@todo probably need events here
    ok = ranch:suspend_listener(St),
    ok = ranch:wait_for_connections(St, '==', 0).
