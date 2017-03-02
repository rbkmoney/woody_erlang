-module(woody_client_thrift).

-behaviour(woody_client_behaviour).

-include_lib("thrift/include/thrift_constants.hrl").
-include("woody_defs.hrl").

%% API
-export([child_spec/1]).
-export([start_pool/2]).
-export([stop_pool /1]).
-export([find_pool /1]).

%% woody_client_behaviour callback
-export([call/3]).

%% Types
-type thrift_client() :: term().

-define(WOODY_OPTS, [protocol, transport, event_handler]).
-define(THRIFT_CAST, oneway_void).

%%
%% API
%%
-spec child_spec(term()) ->
    supervisor:child_spec().
child_spec(Options) ->
    woody_client_thrift_http_transport:child_spec(get_transport_opts(Options)).

-spec start_pool(any(), term()) ->
    ok.
start_pool(Name, Options) ->
    woody_client_thrift_http_transport:start_client_pool(Name, get_transport_opts(Options)).

-spec stop_pool(any()) ->
    ok | {error, not_found | simple_one_for_one}.
stop_pool(Name) ->
    woody_client_thrift_http_transport:stop_client_pool(Name).

-spec find_pool(any()) ->
    pid() | undefined.
find_pool(Name) ->
    woody_client_thrift_http_transport:find_client_pool(Name).

-spec call(woody:request(), woody_client:options(), woody_context:ctx()) ->
    woody_client:result().
call({Service = {_, ServiceName}, Function, Args}, Opts, Context) ->
    _ = log_event(?EV_CALL_SERVICE, Context,
            #{
                service  => ServiceName,
                function => Function,
                type     => get_rpc_type(Service, Function),
                args     => Args
            }
        ),
    do_call(make_thrift_client(Service, Opts, Context), Function, Args, Context).

%%
%% Internal functions
%%
-spec get_rpc_type(woody:service(), woody:func()) ->
    woody:rpc_type().
get_rpc_type(ThriftService = {Module, Service}, Function) ->
    try get_rpc_type(Module:function_info(Service, Function, reply_type))
    catch
        error:Reason when Reason =:= undef orelse Reason =:= badarg ->
            error(badarg, [ThriftService, Function])
    end.

-spec get_rpc_type(atom()) ->
    woody:rpc_type().
get_rpc_type(?THRIFT_CAST) -> cast;
get_rpc_type(_) -> call.

-spec make_thrift_client(woody:service(), woody_client:options(), woody_context:ctx()) ->
    thrift_client().
make_thrift_client(Service, Opts = #{url := Url}, Context) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(Url, get_transport_opts(Opts), Context),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Client} = thrift_client:new(Protocol, Service),
    Client.

-spec get_transport_opts(woody_client:options()) ->
    woody_client_thrift_http_transport:options().
get_transport_opts(Opts) ->
    maps:get(transport_opts, Opts, []).

-spec do_call(thrift_client(), woody:func(), woody:args(), woody_context:ctx()) ->
    woody_client:result().
do_call(Client, Function, Args, Context) ->
    {ClientNext, Result} = try thrift_client:call(Client, Function, Args)
        catch
            %% In case a server violates the requirements and sends
            %% #TAppiacationException{} with http status code 200.
            throw:{Client1, {exception, #'TApplicationException'{}}} ->
                {Client1, {error, {external, result_unexpected, <<"thrift application exception unknown">>}}};
            throw:{Client1, {exception, ThriftExcept}} ->
                {Client1, {error, {business, ThriftExcept}}}
        end,
    _ = thrift_client:close(ClientNext),
    log_result(Result, Context),
    map_result(Result).

log_result({error, {business, ThriftExcept}}, Context) ->
    log_event(?EV_SERVICE_RESULT, Context, #{status => ok, result => ThriftExcept});
log_result({Status, Result}, Context) ->
    log_event(?EV_SERVICE_RESULT, Context, #{status => Status, result => Result}).

-spec map_result(woody_client:result() | {error, _ThriftError}) ->
    woody_client:result().
map_result(Res = {ok, _}) ->
    Res;
map_result(Res = {error, {Type, _}}) when Type =:= business orelse Type =:= system ->
    Res;
map_result({error, _ThriftError}) ->
    {error, {system, {internal, result_unexpected, <<"client thrift error">>}}}.

log_event(Event, Context, Meta) ->
    woody_event_handler:handle_event(Event, Meta, Context).
