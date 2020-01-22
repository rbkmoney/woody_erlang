-module(really_slow_event_handler).

-include("src/woody_defs.hrl").

-export([handle_event/4]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([get_number_of_socket_error_events/0]).

-type state() :: #{
    timeout => pos_integer(),
    socket_errors_caught => pos_integer()
}.
-type event() :: woody_event_handler:event().
-type rpc_id() :: woody:rpc_id().
-type event_meta() :: woody_event_handler:event_meta().
-type options() :: woody:options().

%% API

-spec get_number_of_socket_error_events() -> {ok, pos_integer()}.

get_number_of_socket_error_events() ->
    {ok, N} = gen_server:call(?MODULE, get_number_of_events),
    N.

%% woody_event_handler callbaacks

-spec handle_event(
    event(),
    rpc_id(),
    event_meta(),
    options()
) -> _.

handle_event(Event, A, Meta, B) ->
    gen_server:call(?MODULE, {Event, A, Meta, B}).


%% gen_server callbacks

-spec init(pos_integer()) -> {ok, state()}.
init(Timeout) -> {ok, #{timeout => Timeout, socket_errors_caught => 0}}.

-spec handle_call({event(), rpc_id(), event_meta(), options()}, _, state()) ->
    {reply, ok | {ok, pos_integer()}, state()}.
handle_call({Event, Rpc, #{status := error, reason := <<"The socket has been closed.">>} = Meta, Opts}, _, #{
    socket_errors_caught := Caught
} = State) when 
    Event =:= ?EV_SERVICE_HANDLER_RESULT orelse
    Event =:= ?EV_SERVER_RECEIVE ->
    woody_tests_SUITE:handle_event(Event, Rpc, Meta, Opts),
    {reply, ok, State#{socket_errors_caught => Caught + 1}};

handle_call({Event, Rpc, Meta, Opts}, _, #{timeout := Timeout} = State) ->
    woody_tests_SUITE:handle_event(Event, Rpc, Meta, Opts),
    timer:sleep(Timeout),
    {reply, ok, State};

handle_call(get_number_of_events, _, #{socket_errors_caught := N} = State) ->
    {reply, {ok, N}, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.
handle_cast(_, S) ->
    {noreply, S}.
