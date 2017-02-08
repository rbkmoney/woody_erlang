-module(woody_client_thrift).

-behaviour(woody_client_behaviour).

-include_lib("thrift/include/thrift_constants.hrl").
-include("woody_defs.hrl").

%% API
-export([child_spec/2]).
-export([start_pool/2]).
-export([stop_pool /1]).

%% woody_client_behaviour callback
-export([call/3]).

%% Types
-type thrift_client() :: term().

-define(WOODY_OPTS, [protocol, transport, event_handler]).
-define(THRIFT_CAST, oneway_void).

%%
%% API
%%
-spec child_spec(any(), list(tuple())) ->
    supervisor:child_spec().
child_spec(Name, Options) ->
    woody_client_thrift_http_transport:child_spec(Name, Options).

-spec start_pool(any(), pos_integer()) ->
    ok.
start_pool(Name, PoolSize) when is_integer(PoolSize) ->
    woody_client_thrift_http_transport:start_client_pool(Name, PoolSize).

-spec stop_pool(any()) ->
    ok | {error, not_found | simple_one_for_one}.
stop_pool(Name) ->
    woody_client_thrift_http_transport:stop_client_pool(Name).

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
    do_call(make_thrift_client(Service, clean_opts(Opts), Context), Function, Args, Context).

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

-spec clean_opts(woody_client:options()) ->
    woody_client:options().
clean_opts(Options) ->
    maps:without(?WOODY_OPTS, Options).

-spec make_thrift_client(woody:service(), woody_client:options(), woody_context:ctx()) ->
    thrift_client().
make_thrift_client(Service, TransportOpts, Context) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(TransportOpts, Context),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Client} = thrift_client:new(Protocol, Service),
    Client.

-spec do_call(thrift_client(), woody:func(), woody:args(), woody_context:ctx()) ->
    woody_client:result().
do_call(Client, Function, Args, Context) ->
    {ClientNext, Result} = try thrift_client:call(Client, Function, Args)
        catch
            throw:{Client1, Except = {exception, _}} -> {Client1, Except}
        end,
    _ = thrift_client:close(ClientNext),
    log_result(Result, Context),
    map_result(Result).

log_result({Status, Result}, Context) ->
    log_event(?EV_SERVICE_RESULT, Context, #{status => Status, result => Result}).

-spec map_result(woody_client:result() | {error, _ThriftError}) ->
    woody_client:result().
map_result(Res = {ok, _}) ->
    Res;
%% In case a server violates the requirements and sends
%% #TAppiacationException{} with http status code 200.
map_result({exception, #'TApplicationException'{}}) ->
    {error, {external, result_unexpected, <<"thrift application exception unknown">>}};
map_result({exception, ThriftExcept}) ->
    {error, {business, ThriftExcept}};
map_result(Res = {error, {system, _}}) ->
    Res;
map_result({error, _ThriftError}) ->
    {error, {system, {internal, result_unexpected, <<"client thrift error">>}}}.

log_event(Event, Context, Meta) ->
    woody_event_handler:handle_event(Event, Meta, Context).
