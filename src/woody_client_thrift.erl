-module(woody_client_thrift).

-behaviour(woody_client).

-include_lib("thrift/include/thrift_constants.hrl").
-include("woody_defs.hrl").

%% API
-export([start_pool/2]).
-export([stop_pool/1]).

%% woody_client behaviour callback
-export([call/3]).

%% Types
-type args()    :: any().
-type request() :: {woody_t:service(), woody_t:func(), args()}.

-type except_thrift()  :: _OkException.
-type error_protocol() :: ?ERROR_PROTOCOL(_).
-export_type([except_thrift/0, error_protocol/0]).

-define(WOODY_OPTS, [protocol, transport]).
-define(thrift_cast, oneway_void).

%%
%% API
%%
-spec start_pool(any(), pos_integer()) -> ok.
start_pool(Name, PoolSize) when is_integer(PoolSize) ->
    woody_client_thrift_http_transport:start_client_pool(Name,PoolSize).

-spec stop_pool(any()) -> ok | {error, not_found | simple_one_for_one}.
stop_pool(Name) ->
    woody_client_thrift_http_transport:stop_client_pool(Name).

-spec call(woody_context:ctx(), request(), woody_client:options()) ->
    woody_client:result_ok() | no_return().
call(Context, {Service = {_, ServiceName}, Function, Args}, TransportOpts) ->
    _ = woody_event_handler:handle_event(
            woody_context:get_ev_handler(Context),
            ?EV_CALL_SERVICE,
            woody_context:get_child_rpc_id(Context),
            #{
                service  => ServiceName,
                function => Function,
                type     => get_rpc_type(Service, Function),
                args     => Args,
                context  => Context
            }
        ),
    handle_result(do_call(
        make_thrift_client(Context, Service, clean_opts(TransportOpts)),
        Function, Args
        ), Context).


%%
%% Internal functions
%%
get_rpc_type({Module, Service}, Function) ->
    try get_rpc_type(Module:function_info(Service, Function, reply_type))
    catch
        error:_ ->
            error({badarg, {Service,Function}})
    end.

get_rpc_type(?thrift_cast) -> cast;
get_rpc_type(_) -> call.

clean_opts(Options) ->
    maps:without(?WOODY_OPTS, Options).

make_thrift_client(Context, Service, TransportOpts) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(Context, TransportOpts),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Client} = thrift_client:new(Protocol, Service),
    Client.

do_call(Client, Function, Args) when is_list(Args) ->
    {ClientNext, Result} = try thrift_client:call(Client, Function, Args)
        catch
            throw:Throw = {_, {exception, _}} -> Throw
        end,
    _ = thrift_client:close(ClientNext),
    Result;
do_call(Client, Function, Args) ->
    do_call(Client, Function, [Args]).


handle_result({ok, ok}, Context) ->
    _ = log_rpc_result(ok, ?thrift_cast, Context),
    {ok, Context};
handle_result({ok, Result}, Context) ->
    _ = log_rpc_result(ok, Result, Context),
    {Result, Context};
%% In case a server violates the requirements and sends
%% #TAppiacationException{} with http status code 200.
handle_result({exception, Result = #'TApplicationException'{}}, Context) ->
    _ = log_rpc_result(error, Result, Context),
    error({?ERROR_TRANSPORT(server_error), Context});
%% Service threw a valid thrift exception
handle_result(Exception = ?EXCEPT_THRIFT(_), Context) ->
    _ = log_rpc_result(ok, Exception, Context),
    throw({Exception, Context});
handle_result({error, Error = ?ERROR_TRANSPORT(_)}, Context) ->
    _ = log_rpc_result(error, Error, Context),
    error({Error, Context});
handle_result({error, Error}, Context) ->
    _ = log_rpc_result(error, Error, Context),
    error({?ERROR_PROTOCOL(Error), Context}).

log_rpc_result(Status, Result, Context) ->
    woody_event_handler:handle_event(
        woody_context:get_ev_handler(Context),
        ?EV_SERVICE_RESULT,
        woody_context:get_child_rpc_id(Context),
        #{status => Status, result => Result}
    ).
