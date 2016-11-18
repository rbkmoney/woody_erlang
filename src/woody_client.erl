%%% @doc Client API
%%% @end

-module(woody_client).

-behaviour(supervisor).

-include("woody_defs.hrl").

%% API
-export([call/3]).
-export([call_safe/3]).
-export([call_async/5]).

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).

%% Internal API
-export([init_call_async/4, do_call_async/4]).

%% Supervisor callbacks
-export([init/1]).


%% Behaviour definition
-callback call(woody_context:ctx(), request(), options()) -> result_ok() | no_return().


%% Types
-export_type([result_ok/0, result_error/0, exception/0, error/0]).
-export_type([options/0, callback/0]).

-type result_ok() :: {ok | _Response, woody_context:ctx()}.

-type result_error() ::
    {{exception, exception()}, woody_context:ctx()} |
    {{error    , error()}    , woody_context:ctx()}.

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


%%
%% API
%%
-spec call(woody_context:ctx(), request(), options()) ->
    result_ok() | no_return().
call(Context, Request, Options) ->
    ProtocolHandler = woody_t:get_protocol_handler(client, Options),
    ProtocolHandler:call(woody_context:next(Context), Request, Options).

-spec call_safe(woody_context:ctx(), request(), options()) ->
    result_ok() | result_error().
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

-spec call_async(woody_t:sup_ref(), callback(), woody_context:ctx(), request(), options()) ->
    {ok, pid(), woody_context:ctx()} | {error, _}.
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


%%
%% Internal API
%%
-spec init_call_async(callback(), woody_context:ctx(), request(), options()) -> {ok, pid(), woody_context:ctx()}.
init_call_async(Callback, Context, Request, Options) ->
    proc_lib:start_link(?MODULE, do_call_async, [Callback, Context, Request, Options]).

-spec do_call_async(callback(), woody_context:ctx(), request(), options()) -> _.
do_call_async(Callback, Context, Request, Options) ->
    proc_lib:init_ack({ok, self(), woody_context:next(Context)}),
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
