%%% @doc Client API
%%% @end

-module(woody_client).

-behaviour(supervisor).

-include("woody_defs.hrl").

%% API
-export([call/3]).
-export([call_async/5]).

%% for root calls only
-export([call/4, call/5]).
-export([call_async/6, call_async/7]).


%% Internal API
-export([init_call_async/4, do_call_async/4]).

%% Supervisor callbacks
-export([init/1]).

%% Types
-type id() :: woody:rpc_id() | woody:trace_id() | undefined.
-export_type([id/0]).

-type request() :: woody_client_thrift:request().
-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody:url() %% mandatory
    %% Hint: for now hackney options can be passed thru this map as: key => value too
    %% and will be converted to hackney options list. See hackney:request/5 for more info.
    %% ToDo: disable this hack as soon as woody is coupled with nginx in µ container!
}.
-export_type([request/0, options/0]).

-type result() :: woody_server_thrift_handler:result().
-type safe_result() ::
    {ok    , result           ()} |
    {error , woody_error:error()}.
-export_type([result/0, safe_result/0]).

-type async_cb() :: fun((safe_result()) -> _).
-export_type([async_cb/0]).

%% Behaviour definition
-callback call(woody_context:ctx(), request(), options()) -> safe_result().

%%
%% API
%%
-spec call(request(), options(), woody_context:ctx()) ->
    result() | no_return().
call(Request, Options, Context = #{rpc_id := _, ev_handler := _}) ->
    case call_safe(Request, Options, Context) of
        {ok, Result} ->
            Result;
        {error, {Type, Error}} ->
            woody_error:raise(Type, Error)
    end.

%% Use call/4, call/5 only for root calls.
-spec call(request(), options(), id(), woody:handler())
->
    result() | no_return().
call(Request, Options, Id, EvHandler) ->
    call(Request, Options, Id, EvHandler, undefined).

-spec call(request(), options(), id(), woody:handler(),
    woody_context:meta() | undefined)
->
    result() | no_return().
call(Request, Options, Id, EvHandler, Meta) ->
    call(Request, Options, woody_context:new(Id, EvHandler, Meta)).


-spec call_async(request(), options(), woody:sup_ref(), async_cb(),
    woody_context:ctx()) ->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Context = #{rpc_id := _, ev_handler := _}) ->
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
        [Callback, Request, Options, Context]).

%% Use call_async/6, call_async/7 only for root calls.
-spec call_async(request(), options(), woody:sup_ref(), async_cb(),
    id(), woody:handler())
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler) ->
    call_async(Request, Options, Sup, Callback, Id, EvHandler, undefined).

-spec call_async(request(), options(), woody:sup_ref(), async_cb(),
    id(), woody:handler(), woody_context:meta() | undefined)
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler, Meta) ->
    call_async(Request, Options, Sup, Callback, woody_context:new(Id, EvHandler, Meta)).

%%
%% Internal API
%%
-spec init_call_async(async_cb(), request(), options(), woody_context:ctx()) -> {ok, pid()}.
init_call_async(Callback, Request, Options, Context) ->
    proc_lib:start_link(?MODULE, do_call_async, [Callback, Request, Options, Context]).

-spec do_call_async(async_cb(), request(), options(), woody_context:ctx()) -> _.
do_call_async(Callback, Request, Options, Context) ->
    proc_lib:init_ack({ok, self()}),
    Callback(call_safe(Request, Options, Context)).

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
-spec call_safe(request(), options(), woody_context:ctx()) ->
    safe_result().
call_safe(Request, Options, Context) ->
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

-spec handle_client_error(_Error, woody_context:ctx()) ->
    {error, {system, {internal, result_unexpected, woody_error:details()}}}.
handle_client_error(Error, Context) ->
    Details = woody_error:format_details_short(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR,
            #{error => client_error, reason => Details, stack => erlang:get_stacktrace()},
            Context
        ),
    {error, {system, {internal, result_unexpected, <<"client error">>}}}.
