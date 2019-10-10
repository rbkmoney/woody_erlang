-module(woody_monitor).

-behaviour(gen_server).

-export([monitor/0]).
-export([put_woody_state/2]).

-export([child_spec/0]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-include("woody_defs.hrl").

-type state() :: woody_state:st().

%% API

-spec monitor() -> pid().
monitor() ->
    {ok, Pid} = start(self()),
    Pid.

-spec child_spec() ->
    supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent
    }.

-spec put_woody_state(pid(), woody_state:st()) -> _.
put_woody_state(MonitorPid, WoodyState) ->
    ok = gen_server:cast(MonitorPid, {put_woody_state, WoodyState}).

-spec start(pid()) ->
    genlib_gen:start_ret().

start(Pid) ->
    gen_server:start(?MODULE, Pid, []).

%% supervisor callbacks

-spec init(pid()) ->
    {ok, undefined}.

init(Parent) ->
    erlang:monitor(process, Parent),
    {ok, undefined}.

-spec handle_call(_, _, state()) ->
    {noreply, state()}.
handle_call(_Call, _From, St) ->
    {noreply, St}.

-spec handle_cast(_, state()) ->
    {noreply, state()}.

handle_cast({put_woody_state, WoodyState}, _) ->
    {noreply, WoodyState};
handle_cast(_Cast, St) ->
    {noreply, St}.

-spec handle_info(_, state()) ->
    {stop, normal, ok}.
handle_info({'DOWN', Ref, process, _PID, Reason}, WoodyState) ->
    erlang:demonitor(Ref),
    case Reason =/= normal of
        true ->
            woody_event_handler:handle_event(?EV_INTERNAL_ERROR,
                WoodyState,
                #{status => error, reason => woody_util:to_binary(Reason)}
            );
        false ->
            ok
    end,
    {stop, normal, ok}.

-spec terminate(_, state()) ->
    ok.
terminate(_, _) ->
    ok.
