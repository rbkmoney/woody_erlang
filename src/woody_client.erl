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

-type options() :: #{
    protocol  => thrift,     %% optional
    transport => http,       %% optional
    url       => woody:url() %% mandatory
    %% Hint: for now hackney options can be passed thru this map as: key => value too
    %% and will be converted to hackney options list. See hackney:request/5 for more info.
    %% ToDo: disable this hack as soon as woody is coupled with nginx in µ container!
}.
-export_type([options/0]).

-type safe_result() ::
    {ok    , woody:result     ()} |
    {error , woody_error:error()}.
-export_type([safe_result/0]).

-type async_cb() :: fun((safe_result()) -> _).
-export_type([async_cb/0]).

%% Internal API
%% Behaviour definition
-callback call(woody_context:ctx(), woody:request(), options()) -> safe_result().

%%
%% API
%%
-spec call(woody:request(), options(), woody_context:ctx()) ->
    woody:result() | no_return().
call(Request, Options, Context = #{rpc_id := _, ev_handler := _}) ->
    case call_safe(Request, Options, Context) of
        {ok, Result} ->
            Result;
        {error, {Type, Error}} ->
            woody_error:raise(Type, Error)
    end.

%% Use call/4, call/5 only for root calls.
-spec call(woody:request(), options(), id(), woody:ev_handler())
->
    woody:result() | no_return().
call(Request, Options, Id, EvHandler) ->
    call(Request, Options, Id, EvHandler, undefined).

-spec call(woody:request(), options(), id(), woody:ev_handler(),
    woody_context:meta() | undefined)
->
    woody:result() | no_return().
call(Request, Options, Id, EvHandler, Meta) ->
    call(Request, Options, woody_context:new(Id, EvHandler, Meta)).


-spec call_async(woody:request(), options(), woody:sup_ref(), async_cb(),
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
-spec call_async(woody:request(), options(), woody:sup_ref(), async_cb(),
    id(), woody:ev_handler())
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler) ->
    call_async(Request, Options, Sup, Callback, Id, EvHandler, undefined).

-spec call_async(woody:request(), options(), woody:sup_ref(), async_cb(),
    id(), woody:ev_handler(), woody_context:meta() | undefined)
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler, Meta) ->
    call_async(Request, Options, Sup, Callback, woody_context:new(Id, EvHandler, Meta)).

%%
%% Internal API
%%
-spec init_call_async(async_cb(), woody:request(), options(), woody_context:ctx()) ->
    {ok, pid()}.
init_call_async(Callback, Request, Options, Context) ->
    proc_lib:start_link(?MODULE, do_call_async, [Callback, Request, Options, Context]).

-spec do_call_async(async_cb(), woody:request(), options(), woody_context:ctx()) -> _.
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
-spec call_safe(woody:request(), options(), woody_context:ctx()) ->
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
    Details = woody_error:format_details(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, #{
            role     => client,
            severity => error,
            error    => woody_util:to_binary([?EV_CALL_SERVICE, " error"]),
            reason   => Details,
            stack    => erlang:get_stacktrace()
        }, Context),
    {error, {system, {internal, result_unexpected, <<"client error">>}}}.
