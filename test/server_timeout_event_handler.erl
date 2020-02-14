-module(server_timeout_event_handler).

-include("src/woody_defs.hrl").

-export([handle_event/4]).

-export([child_spec/0]).
-export([start_link/0]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([get_socket_errors_caught/0]).

-type state() :: #{
    socket_errors_caught => pos_integer()
}.
-type event() :: woody_event_handler:event().
-type rpc_id() :: woody:rpc_id().
-type event_meta() :: woody_event_handler:event_meta().
-type options() :: woody:options().

%% API

-define(SOCKET_CLOSED, <<"The socket has been closed.">>).

-spec get_socket_errors_caught() -> pos_integer().

get_socket_errors_caught() ->
    {ok, N} = gen_server:call(?MODULE, get_number_of_events),
    N.

-spec child_spec() -> supervisor:child_spec().

child_spec() -> #{
    id => ?MODULE,
    start => {?MODULE, start_link, []},
    type => worker
}.

%% woody_event_handler callbaacks

-spec handle_event(
    event(),
    rpc_id(),
    event_meta(),
    options()
) -> _.

handle_event(Event, RpcId, Meta, Opts) ->
    gen_server:call(?MODULE, {Event, RpcId, Meta, Opts}).


%% gen_server callbacks

-spec start_link() -> {ok, pid()}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec init(_) -> {ok, state()}.

init(_) ->
    {ok, #{socket_errors_caught => 0}}.

-spec handle_call({event(), rpc_id(), event_meta(), options()}, _, state()) ->
    {reply, ok | {ok, pos_integer()}, state()}.
handle_call({Event = ?EV_SERVICE_HANDLER_RESULT, Rpc, #{status := error, class := system, result := ?SOCKET_CLOSED} = Meta, Opts}, _, #{
    socket_errors_caught := Caught
} = State) ->
    woody_tests_SUITE:handle_event(Event, Rpc, Meta, Opts),
    {reply, ok, State#{socket_errors_caught => Caught + 1}};
handle_call({Event = ?EV_SERVER_RECEIVE, Rpc, #{status := error, reason := ?SOCKET_CLOSED} = Meta, Opts}, _, #{
    socket_errors_caught := Caught
} = State) ->
    woody_tests_SUITE:handle_event(Event, Rpc, Meta, Opts),
    {reply, ok, State#{socket_errors_caught => Caught + 1}};

handle_call({Event, Rpc, Meta, Opts}, _, State) ->
    woody_tests_SUITE:handle_event(Event, Rpc, Meta, Opts),
    {reply, ok, State};

handle_call(get_number_of_events, _, #{socket_errors_caught := N} = State) ->
    {reply, {ok, N}, State}.

-spec handle_cast(_, state()) -> {noreply, state()}.

handle_cast(_, S) ->
    {noreply, S}.
