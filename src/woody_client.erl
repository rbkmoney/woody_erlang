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

%% Types
-export_type([result/0, result_ok/0]).
-export_type([callback/0, request/0, options/0]).

-type request() :: woody_client_thrift:request().

-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody:url() %% mandatory
    %% Hint: for now hackney options can be passed thru this map as: key => value too
    %% and will be converted to hackney options list. See hackney:request/5 for more info.
    %% ToDo: disable this hack as soon as woody is coupled with nginx in µ container!
}.

-type result_ok() :: woody_server_thrift_handler:result().

-type result() ::
    {ok    , result_ok        ()} |
    {error , woody_error:error()}.

-type callback() :: fun((result()) -> _).

%% Behaviour definition
-callback call(woody_context:ctx(), request(), options()) -> result().

%%
%% API
%%
-spec call(woody_context:ctx(), request(), options()) ->
    result_ok() | no_return().
call(Context, Request, Options) ->
    case call_safe(Context, Request, Options) of
        {ok, Result} ->
            Result;
        {error, {Type, Error}} ->
            woody_error:raise(Type, Error)
    end.

-spec call_safe(woody_context:ctx(), request(), options()) ->
    result().
call_safe(Context, Request, Options) ->
    ProtocolHandler = woody_util:get_protocol_handler(client, Options),
    try ProtocolHandler:call(woody_context:new_child(Context), Request, Options) of
        Resp = {ok, _} ->
            Resp;
        Error = {error, {Type, _}} when Type =:= system ; Type =:= business ->
            Error;
        Other ->
            handle_client_error(Other, Context)
    catch
        _:Reason ->
            handle_client_error(Reason, Context)
    end.

-spec call_async(woody_context:ctx(), request(), options(), woody:sup_ref(), callback()) ->
    {ok, pid()} | {error, _}.
call_async(Context, Request, Options, Sup, Callback) ->
    _ = woody_util:get_protocol_handler(client, Options),
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
-spec handle_client_error(_Error, woody_context:ctx()) ->
    {error, {system, {internal, result_unexpected, woody_error:details()}}}.
handle_client_error(Error, Context) ->
    Details = woody_error:format_details_short(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR,
            #{error => client_error, reason => Details, stack => erlang:get_stacktrace()},
            Context
        ),
    {error, {system, {internal, result_unexpected, <<"client error">>}}}.
