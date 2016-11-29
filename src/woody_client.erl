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
-callback call(woody_context:ctx(), request(), options()) -> result_all().

%% Types
-export_type([result_all/0, result_ok/0]).
-export_type([options/0, callback/0]).

-type request() :: any().

-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody_t:url() %% mandatory
}.

-type result_ok() :: woody_server_thrift_handler:result().

-type result_all() ::
    {ok,        result_ok            ()} |
    {exception, woody_error:exception()} |
    {error    , woody_error:error    ()}.

-type callback() :: fun((result_all()) -> _).


%%
%% API
%%
-spec call(woody_context:ctx(), request(), options()) ->
    result_ok() | no_return().
call(Context, Request, Options) ->
    case call_safe(Context, Request, Options) of
        {ok, Result} ->
            Result;
        {exception, Except} ->
            erlang:throw(Except);
        {error, Error} ->
            erlang:error(Error)
    end.

-spec call_safe(woody_context:ctx(), request(), options()) ->
    result_all().
call_safe(Context, Request, Options) ->
    ProtocolHandler = woody_t:get_protocol_handler(client, Options),
    try ProtocolHandler:call(woody_context:next(Context), Request, Options) of
        Resp = {ok, _} ->
            Resp;
        Except = {exception, _} ->
            Except;
        Error = {error, _} ->
            Error;
        Other ->
            make_error(error, Other)
    catch
        error:Error ->
            return_error(woody_error:is_error(Error), Error);
        Class:Reason ->
            make_error(Class, Reason)
    end.

-spec call_async(woody_t:sup_ref(), callback(), woody_context:ctx(), request(), options()) ->
    {ok, pid()} | {error, _}.
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
return_error(true, Error) ->
    Error;
return_error(false, Error) ->
    make_error(error, Error).

make_error(Class, Reason) ->
    {error, woody_error:make_error(internal, result_unexpected, {Class, Reason, erlang:get_stacktrace()})}.
