%%% @doc Client API
%%% @end

-module(woody_client).

-behaviour(supervisor).

-include("woody_defs.hrl").

%% API
-export([new_context/2]).
-export([get_rpc_id/1]).
-export([make_id/1]).
-export([make_id_int/0]).
-export([make_child_context/2]).

-export([call/3]).
-export([call_safe/3]).
-export([call_async/5]).

-export_type([context/0, options/0, result_ok/0, result_error/0, exception/0, error/0]).

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).

%% Internal API
-export([init_call_async/4, do_call_async/4]).

%% supervisor callbacks
-export([init/1]).

%% behaviour definition
-callback call(context(), request(), options()) -> result_ok() | no_return().


%%
%% API
%%
-type context() :: #{  %% all elements are mandatory
    root_rpc      => boolean(),
    span_id       => woody_t:req_id() | undefined,
    trace_id      => woody_t:req_id(),
    parent_id     => woody_t:req_id(),
    event_handler => woody_t:handler(),
    seq           => non_neg_integer(),
    rpc_id        => woody_t:rpc_id() | undefined
}.

-type result_ok() :: {ok | _Response, context()}.

-type result_error() ::
    {{exception, exception()}, context()} |
    {{error    , error()}    , context()}.

-type exception() :: woody_client_thrift:except_thrift().
-type error() ::
    woody_client_thrift:error_protocol() |
    woody_client_thrift_http_transport:error() |
    {class(), _Reason, stacktrace()}.

-type class() :: throw | error | exit.
-type stacktrace() :: list().

-type request() :: any().

-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody_t:url() %% mandatory
}.

-type callback() :: fun((result_ok() | result_error()) -> _).

-spec new_context(woody_t:req_id(), woody_t:handler()) -> context().
new_context(ReqId, EventHandler) ->
    #{
        root_rpc      => true,
        span_id       => ReqId,
        trace_id      => ReqId,
        parent_id     => ?ROOT_REQ_PARENT_ID,
        seq           => 0,
        event_handler => EventHandler,
        rpc_id        => undefined
    }.

-spec make_child_context(woody_t:rpc_id(), woody_t:handler()) -> context().
make_child_context(RpcId = #{span_id := ReqId, trace_id := TraceId}, EventHandler) ->
    #{
        root_rpc      => false,
        span_id       => undefined,
        trace_id      => TraceId,
        parent_id     => ReqId,
        seq           => 0,
        event_handler => EventHandler,
        rpc_id        => RpcId
    }.

-spec get_rpc_id(context()) -> woody_t:rpc_id() | undefined | no_return().
get_rpc_id(#{rpc_id := RpcId}) ->
    RpcId;
get_rpc_id(_) ->
    error(badarg).

-spec call(context(), request(), options()) -> result_ok() | no_return().
call(Context, Request, Options) ->
    ProtocolHandler = woody_t:get_protocol_handler(client, Options),
    ProtocolHandler:call(next(Context), Request, Options).

-spec call_safe(context(), request(), options()) -> result_ok() | result_error().
call_safe(Context, Request, Options) ->
    try call(Context, Request, Options)
    catch
        %% valid thrift exception
        throw:{Except = ?EXCEPT_THRIFT(_), Context1} ->
            {Except, Context1};
        %% rpc send failed
        error:{TError = ?ERROR_TRANSPORT(_), Context1} ->
            {{error, TError}, Context1};
        %% thrift protocol error
        error:{PError = ?ERROR_PROTOCOL(_), Context1} ->
            {{error, PError}, Context1};
        %% what else could have happened?
        Class:Reason ->
            {{error, {Class, Reason, erlang:get_stacktrace()}}, Context}
    end.

-spec call_async(woody_t:sup_ref(), callback(), context(), request(), options()) ->
    {ok, pid(), context()} | {error, _}.
call_async(Sup, Callback, Context, Request, Options) ->
    _ = woody_t:get_protocol_handler(client, Options),
    SupervisorSpec = #{
        id       => {?MODULE, woody_clients_sup},
        start    => {supervisor, start_link, [?MODULE, woody_client_sup]},
        restart  => permanent,
        shutdown => infinity,
        type     => supervisor,
        modules  => [?MODULE]
    },
    ClientSup = case supervisor:start_child(Sup, SupervisorSpec) of
        {ok, Pid} -> Pid;
        {error, {already_started, Pid}} -> Pid
    end,
    supervisor:start_child(ClientSup,
        [Callback, Context, Request, Options]).

-spec make_id_int() -> pos_integer().
make_id_int() ->
    <<Id:64>> = snowflake:new(?MODULE),
    Id.

-spec make_id(binary()) -> woody_t:req_id().
make_id(Suffix) when is_binary(Suffix) ->
    IdInt = make_id_int(),
    IdBin = genlib:to_binary(IdInt),
    <<IdBin/binary, $:, Suffix/binary>>.

%%
%% Internal API
%%
-spec init_call_async(callback(), context(), request(), options()) -> {ok, pid(), context()}.
init_call_async(Callback, Context, Request, Options) ->
    proc_lib:start_link(?MODULE, do_call_async, [Callback, Context, Request, Options]).

-spec do_call_async(callback(), context(), request(), options()) -> _.
do_call_async(Callback, Context, Request, Options) ->
    proc_lib:init_ack({ok, self(), next(Context)}),
    Callback(call_safe(Context, Request, Options)).

%%
%% Supervisor callbacks
%%
-spec init(woody_client_sup) -> {ok, {#{}, [#{}, ...]}}.
init(woody_client_sup) ->
    {ok, {
        #{
            strategy  => simple_one_for_one,
            intensity => 1,
            period    => 1
        },
        [#{
            id       => undefined,
            start    => {?MODULE, init_call_async, []},
            restart  => temporary,
            shutdown => brutal_kill,
            type     => worker,
            modules  => []
        }]
    }
}.

%%
%% Internal functions
%%
-spec next(context()) -> context().
next(Context = #{root_rpc := true}) ->
    Context;
next(Context = #{root_rpc := false, seq := Seq}) ->
    NextSeq = Seq +1,
    Context#{span_id => make_id(genlib:to_binary(NextSeq)), seq => NextSeq}.

