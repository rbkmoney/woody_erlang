-module(woody_drainer).
-behaviour(gen_server).

-type options() :: #{
    shutdown  := timeout(),
    ranch_ref := ranch:ref()
}.

-export([child_spec/1]).
-export([start_link/1]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([terminate/2]).

-spec child_spec(options()) ->
    supervisor:child_spec().

%% API

child_spec(Opts) ->
    RanchRef = maps:get(ranch_ref, Opts),
    Shutdown = get_shutdown_param(Opts),
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, [RanchRef]},
        shutdown => Shutdown
    }.

start_link(RanchRef) ->
    gen_server:start_link(?MODULE, RanchRef, []).

%% supervisor callbacks

init(RanchRef) ->
    process_flag(trap_exit, true),
    {ok, RanchRef}.

handle_call(_, _, St) -> {reply, ok, St}.
handle_cast(_, St) -> {noreply, St}.

terminate(shutdown, Ref) ->
    ok = ranch:suspend_listener(Ref),
    %ProtoOpts = ranch:get_protocol_options(Ref),
    %ok = ranch:set_protocol_options(Ref, ProtoOpts#{max_keepalive => 1}),
    ok = ranch:wait_for_connections(Ref, '==', 0).

%% internal

get_shutdown_param(#{shutdown := Timeout}) when Timeout =:= 0 ->
    brutal_kill;
get_shutdown_param(#{shutdown := Timeout}) ->
    Timeout.
