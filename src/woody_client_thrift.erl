-module(woody_client_thrift).

-behaviour(woody_client).

-include_lib("thrift/include/thrift_constants.hrl").
-include("woody_defs.hrl").

%% API
-export([start_pool/2]).
-export([stop_pool/1]).

%% woody_client behaviour callback
-export([call/3]).

-type args()    :: any().
-type request() :: {woody_t:service(), woody_t:func(), args()}.

-type except_thrift()  :: _OkException.
-type error_protocol() :: ?error_protocol(_).
-export_type([except_thrift/0, error_protocol/0]).

-define(log_rpc_result(EventHandler, RpcId, Status, Result),
    woody_event_handler:handle_event(EventHandler, ?EV_SERVICE_RESULT, RpcId, #{
        status => Status, result => Result
    })
).

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

-spec call(woody_client:context(), request(), woody_client:options()) ->
    woody_client:result_ok() | no_return().
call(Context = #{event_handler := EventHandler},
    {Service = {_, ServiceName}, Function, Args}, TransportOpts)
->
    RpcId = maps:with([span_id, trace_id, parent_id], Context),
    woody_event_handler:handle_event(EventHandler, ?EV_CALL_SERVICE, RpcId, #{
        service   => ServiceName,
        function  => Function,
        type      => get_rpc_type(Service, Function),
        args      => Args
    }),
    format_return(
        do_call(
            make_thrift_client(RpcId, Service, clean_opts(TransportOpts), EventHandler),
            Function, Args
        ), RpcId, Context
    ).


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

make_thrift_client(RpcId, Service, TransportOpts, EventHandler) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(RpcId, TransportOpts, EventHandler),
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
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, ?thrift_cast),
    {ok, Context};

format_return({ok, Result}, RpcId,
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, Result),
    {{ok, Result}, Context};

%% In case a server violates the requirements and sends
%% #TAppiacationException{} with http status code 200.
format_return({exception, Result = #'TApplicationException'{}}, RpcId,
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Result),
    error({?error_transport(server_error), Context});

%% Service threw valid thrift exception
format_return(Exception = ?except_thrift(_), RpcId,
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, ok, Exception),
    throw({Exception, Context});

format_return({error, Error = ?error_transport(_)}, RpcId,
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Error),
    error({Error, Context});

format_return({error, Error}, RpcId,
    Context = #{event_handler := EventHandler})
->
    ?log_rpc_result(EventHandler, RpcId, error, Error),
    error({?error_protocol(Error), Context}).
