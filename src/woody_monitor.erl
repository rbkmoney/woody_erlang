-module(woody_monitor).

-behaviour(gen_server).

-export([register_me/0]).
-export([put_woody_state/1]).

-export([child_spec/0]).
-export([start_link/0]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-include("woody_defs.hrl").

-type state() :: #{
    pid() => woody_state:st()
}.

%% API

-spec child_spec() ->
    supervisor:child_spec().

child_spec() ->
    #{
        id => ?MODULE,
        start => {?MODULE, start_link, []},
        restart => permanent
    }.

-spec register_me() -> _.
register_me() ->
   ok = gen_server:call(?MODULE, register).

-spec put_woody_state(woody_state:st()) -> _.
put_woody_state(WoodyState) ->
    ok = gen_server:call(?MODULE, {put_woody_state, WoodyState}).

-spec start_link() ->
    genlib_gen:start_ret().

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, undefined, []).

%% supervisor callbacks

-spec init(_) ->
    {ok, map()}.

init(_) ->
    {ok, #{}}.

-spec handle_call(_, _, state()) ->
    {noreply, state()}.
handle_call(register, {PID, _}, St) ->
    erlang:monitor(process, PID),
    {reply, ok, St#{PID => undefined}};
handle_call({put_woody_state, WoodyState}, {PID, _}, St0) ->
    St = case maps:is_key(PID, St0) of
        true ->
            put_woody_state(PID, WoodyState, St0);
        false ->
            St0
    end,
    {reply, ok, St};
handle_call(_Call, _From, St) ->
    {noreply, St}.

-spec handle_cast(_, state()) ->
    {noreply, state()}.

handle_cast(_Cast, St) ->
    {noreply, St}.

-spec handle_info(_, state()) ->
    {noreply, state()}.
handle_info({'DOWN', Ref, process, PID, Reason}, St) ->
    erlang:demonitor(Ref),
    WoodyState = get_woody_state(PID, St),
    case Reason =/= normal of
        true ->
            woody_event_handler:handle_event(?EV_INTERNAL_ERROR,
                WoodyState,
                #{status => error, reason => woody_util:to_binary(Reason)}
            );
        false ->
            ok
    end,
    {noreply, maps:remove(PID, St)}.

-spec terminate(_, state()) ->
    ok.
terminate(_, _) ->
    ok.

%% private

put_woody_state(PID, ProcessState, State) ->
    State#{PID => ProcessState}.

get_woody_state(PID, State) ->
    genlib_map:get(PID, State).
