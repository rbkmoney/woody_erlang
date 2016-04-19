-module(rpc_thrift_client).

-behaviour(rpc_client).

-include_lib("thrift/include/thrift_constants.hrl").
-include("rpc_defs.hrl").

%% API
-export([start_pool/2]).
-export([stop_pool/1]).

%% rpc_client behaviour callback
-export([call/3]).

-type args() :: any().
-type request() :: {rpc_t:service(), rpc_t:func(), args()}.

-type except_thrift() :: _OkException.
-export_type([except_thrift/0]).

-define(log_rpc_result(EventHandler, RpcId, Status, Result),
    rpc_event_handler:handle_event(EventHandler, ?EV_SERVICE_RESULT, RpcId#{
        status => Status, result => Result
    })
).

-define(thrift_cast, oneway_void).

%%
%% API
%%
-spec start_pool(any(), pos_integer()) -> ok.
start_pool(Name, PoolSize) when is_integer(PoolSize) ->
    rpc_thrift_http_transport:start_client_pool(Name,PoolSize).

-spec stop_pool(any()) -> ok | {error, not_found | simple_one_for_one}.
stop_pool(Name) ->
    rpc_thrift_http_transport:stop_client_pool(Name).

-spec call(rpc_client:client(), request(), rpc_client:options()) ->
    rpc_client:result_ok() | no_return().
call(Client = #{event_handler := EventHandler},
    {Service, Function, Args}, TransportOpts)
->
    RpcId = maps:with([span_id, trace_id, parent_id], Client),
    rpc_event_handler:handle_event(EventHandler, ?EV_CALL_SERVICE, RpcId#{
        service   => Service,
        function  => Function,
        type      => get_rpc_type(Service, Function),
        args      => Args
    }),
    format_return(
        do_call(
            make_thrift_client(RpcId, Service, TransportOpts, EventHandler),
            Function, Args
        ), RpcId, Client
    ).


%%
%% Internal functions
%%
get_rpc_type(Service, Function) ->
    try get_rpc_type(Service:function_info(Function, reply_type))
    catch
        error:_ ->
            error({badarg, {Service,Function}})
    end.

get_rpc_type(?thrift_cast) -> cast;
get_rpc_type(_) -> call.

make_thrift_client(RpcId, Service, TransportOpts, EventHandler) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        rpc_thrift_http_transport:new(RpcId, TransportOpts, EventHandler),
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


format_return({ok, ok}, RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, ?thrift_cast),
    {ok, Client};

format_return({ok, Result}, RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, Result),
    {{ok, Result}, Client};

%% In case a server violates the requirements and sends
%% #TAppiacationException{} with http status code 200.
format_return({exception, Result = #'TApplicationException'{}}, RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Result),
    error({?error_transport(server_error), Client});

%% Service threw valid thrift exception
format_return(Exception = ?except_thrift(_), RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, Exception),
    throw({Exception, Client});

format_return({error, Error = ?error_transport(_)}, RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Error),
    error({Error, Client});

format_return({error, Error}, RpcId,
    Client = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Error),
    error({?error_protocol(Error), Client}).
