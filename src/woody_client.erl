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
-callback call(woody_context:ctx(), request(), options()) -> result().

%% Types
-export_type([result/0, result_ok/0]).
-export_type([options/0, callback/0]).

-type request() :: any().

-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody:url() %% mandatory
}.

-type result_ok() :: woody_server_thrift_handler:result().

-type result() ::
    {ok    , result_ok        ()} |
    {error , woody_error:error()}.

-type callback() :: fun((result()) -> _).


%%
%% API
%%
-spec call(woody_context:ctx(), request(), options()) ->
    result_ok() | no_return().
call(Context, Request, Options) ->
    case call_safe(Context, Request, Options) of
        {ok, Result} ->
            Result;
        {error, {business, Error}} ->
            erlang:throw(Error);
        {error, {system, Error}} ->
            erlang:error(Error)
    end.

-spec call_safe(woody_context:ctx(), request(), options()) ->
    result().
call_safe(Context, Request, Options) ->
    ProtocolHandler = woody:get_protocol_handler(client, Options),
    try ProtocolHandler:call(woody_context:next(Context), Request, Options) of
        Resp = {ok, _} ->
            Resp;
        Error = {error, {system, _}} ->
            Error;
        Other ->
            {error, {system, {internal, result_unexpected, format_error(Other)}}}
    catch
        error:Error = {system, _} ->
            {error, Error};
        Class:Reason ->
            {error, {system, {internal, result_unexpected, format_error(Class, Reason, erlang:get_stacktrace())}}}
    end.

-spec call_async(woody:sup_ref(), callback(), woody_context:ctx(), request(), options()) ->
    {ok, pid()} | {error, _}.
call_async(Sup, Callback, Context, Request, Options) ->
    _ = woody:get_protocol_handler(client, Options),
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
-spec init_call_async(callback(), woody_context:ctx(), request(), options()) -> {ok, pid()}.
init_call_async(Callback, Context, Request, Options) ->
    proc_lib:start_link(?MODULE, do_call_async, [Callback, Context, Request, Options]).

-spec do_call_async(callback(), woody_context:ctx(), request(), options()) -> _.
do_call_async(Callback, Context, Request, Options) ->
    proc_lib:init_ack({ok, self()}),
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
-spec format_error(term()) -> binary().
format_error(Error) ->
    genlib:to_binary(Error).

-spec format_error(atom(), term(), term()) -> binary().
format_error(Class, Reason, Stacktrace) ->
    genlib:to_binary([Class, Reason, Stacktrace]).
