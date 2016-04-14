-module(rpc_thrift_client).

-behaviour(rpc_client).
-include_lib("thrift/include/thrift_constants.hrl").

%% API
-export([start_pool/2]).
-export([stop_pool/1]).

%% rpc_client behaviour callback
-export([call/3]).

%% ToDo
%% -export([cast/6]).

-type args() :: any().
-type request() :: {rpc_t:service(), rpc_t:func(), args()}.

-define(RPC_ERROR, rpc_failed).

%%
%% API
%%
-spec start_pool(any(), pos_integer()) -> ok.
start_pool(Name, PoolSize) when is_integer(PoolSize) ->
    rpc_thrift_http_transport:start_client_pool(Name,PoolSize).

-spec stop_pool(any()) -> ok | {error, not_found | simple_one_for_one}.
stop_pool(Name) ->
    rpc_thrift_http_transport:stop_client_pool(Name).

-spec call(rpc_client:client(), request(), rpc_client:options()) -> rpc_client:result_ok() | no_return().
call(Client = #{event_handler := EventHandler},
    {Service, Function, Args}, TransportOpts = #{url := Url})
->
    RpcId = maps:with([req_id, root_req_id, parent_req_id], Client),
    rpc_event_handler:handle_event(EventHandler, send_request, RpcId#{
        rpc_role => client,
        direction => request,
        url => Url,
        service => Service,
        function => Function,
        args => Args
    }),
    Result = do_call(make_thrift_client( RpcId, Service, TransportOpts), Function, Args),
    rpc_event_handler:handle_event(EventHandler, receive_response, RpcId#{
        rpc_role => client,
        direction => response,
        rpc_result => Result
    }),
    format_return(Result, Client).

make_thrift_client(RpcId, Service, TransportOpts) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        rpc_thrift_http_transport:new(RpcId, TransportOpts),
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

format_return({ok, Result}, Client) ->
    {ok, Result, Client};
format_return({exception, #'TApplicationException'{}}, Client) ->
    error({?RPC_ERROR, Client});
format_return({exception, Exception}, Client) ->
    throw({Exception, Client});
format_return({error, _}, Client) ->
    error({?RPC_ERROR, Client}).