-module(rpc_thrift_handler).

%% API
-export([start/6]).

-include_lib("thrift/include/thrift_constants.hrl").
-include_lib("thrift/include/thrift_protocol.hrl").

%%
%% rpc_thrift_handler behaviour definition
%%
-type result() :: any().
-export_type([result/0]).

-type handler_opts() :: list().
-type args() :: list().
-export_type([handler_opts/0, args/0]).

-callback handle_function(rpc_t:func(), rpc_client:client(), args(), handler_opts()) ->
    ok | {ok, result()} | {error, result()} | no_return().

-callback handle_error(rpc_t:func(), rpc_client:client(), args(), handler_opts()) -> _.

%%
%% API
%%
-define(log_rpc_result(EventHandler, Event, ReqId, Status, Meta),
    rpc_event_handler:handle_event(EventHandler, Event, [
        {rpc_role, server},
        {req_id, ReqId},
        {status, Status}
    ] ++ Meta)
).

-record(state, {
    req_id :: rpc_t:req_id(),
    rpc_client :: rpc_client:client(),
    service :: module(),
    handler :: rpc_t:handler(),
    handler_opts :: handler_opts(),
    protocol :: any(),
    protocol_stage :: read_request | write_response,
    event_handler :: rpc_t:handler(),
    transport_handler :: rpc_t:handler()
}).

-type thrift_handler() :: {rpc_t:service(), rpc_t:handler(), handler_opts()}.
-export_type([thrift_handler/0]).

-type event_handler() :: rpc_t:handler().
-type transport_handler() :: rpc_t:hander().

-spec start(thrift_transport:t_transport(), rpc_t:req_id(), rpc_client:client(),
    thrift_handler(), event_handler(), transport_handler())
->
    ok | noreply | {error, _Reason}.
start(Transport, ReqId, RpcClient, {Service, Handler, Opts}, EventHandler, TransportHandler) ->
    {ok, Protocol} = thrift_binary_protocol:new(Transport,
        [{strict_read, true}, {strict_write, true}]
    ),
    {Result, Protocol1} = process(#state{
            req_id = ReqId,
            rpc_client = RpcClient,
            service = Service,
            handler = Handler,
            handler_opts = Opts,
            protocol = Protocol,
            protocol_stage = read_request,
            event_handler = EventHandler,
            transport_handler = TransportHandler
    }),
    thrift_protocol:close_transport(Protocol1),
    Result.


%%
%% Internal functions
%%
process(State = #state{protocol = Protocol, service = Service}) ->
    {Protocol1, MessageBegin} = thrift_protocol:read(Protocol, message_begin),
    State1 = State#state{protocol = Protocol1},
    case MessageBegin of
        #protocol_message_begin{name = Function, type = Type, seqid = SeqId} when
            Type =:= ?tMessageType_CALL orelse
            Type =:= ?tMessageType_ONEWAY
        ->
            FunctionName = list_to_existing_atom(Function),
            prepare_result(handle_function(FunctionName,
                Service:function_info(FunctionName, params_type),
                State1,
                SeqId
            ), FunctionName);
        {error, Reason} ->
            handle_protocol_error(State1, undefined, Reason)
    end.

handle_function(_, no_function, State, _SeqId) ->
    {State, {error, function_undefined}};

handle_function(Function, InParams, State = #state{protocol = Protocol}, SeqId) ->
    {Protocol1, ReadResult} = thrift_protocol:read(Protocol, InParams),
    State1 = State#state{protocol = Protocol1},
    case ReadResult of
        {ok, Args} ->
            try_call_handler(Function, Args,
                State1#state{protocol_stage = write_response}, SeqId);
        Error = {error, _} ->
            {State1, Error}
    end.

try_call_handler(Function, Args, State, SeqId) ->
    try handle_result(call_handler(Function, Args, State), State, Function, SeqId)
    catch
        Class:Reason ->
            handle_function_catch(State, Function, Class, Reason,
                erlang:get_stacktrace(), SeqId)
    end.

call_handler(Function,Args, #state{
    req_id = ReqId,
    rpc_client = RpcClient,
    handler = Handler,
    handler_opts = Opts,
    event_handler = EventHandler})
->
    rpc_event_handler:handle_event(EventHandler, calling_rpc_handler, [
        {req_id, ReqId},
        {function, Function},
        {args, Args},
        {options, Opts}
    ]),
    Result = Handler:handle_function(Function, RpcClient, Args, Opts),
    ?log_rpc_result(EventHandler, rpc_handler_result, ReqId, ok, [{result, Result}]),
    Result.

handle_result(ok, State, Function, SeqId) ->
    handle_success(State, Function, ok, SeqId);
handle_result({ok, Response}, State, Function, SeqId) ->
    handle_success(State, Function, Response, SeqId);
handle_result({error, Error}, State, Function, SeqId) ->
    handle_error(State, Function, Error, SeqId).

handle_success(State = #state{service = Service}, Function, Result, SeqId) ->
    ReplyType = Service:function_info(Function, reply_type),
    StructName = atom_to_list(Function) ++ "_result",
    case Result of
        ok when ReplyType == {struct, []} ->
            send_reply(State, Function, ?tMessageType_REPLY,
                {ReplyType, {StructName}}, SeqId);
        ok when ReplyType == oneway_void ->
            {State, noreply};
        ReplyData ->
            Reply = {
                {struct, [{0, undefined, ReplyType, undefined, undefined}]},
                {StructName, ReplyData}
            },
            send_reply(State, Function, ?tMessageType_REPLY, Reply, SeqId)
    end.

handle_function_catch(State = #state{
    req_id = ReqId,
    service = Service,
    event_handler = EventHandler}, Function, Class, Reason,
    Stack, SeqId)
->
    ReplyType = Service:function_info(Function, reply_type),
    case {Class, Reason} of
        _Error when ReplyType =:= oneway_void ->
            ?log_rpc_result(EventHandler, rpc_handler_exception, ReqId, error, [
                {exception_type, Class},
                {reason, Reason},
                {ignore, true}
            ]),
            {State, noreply};
        {throw, Exception} when is_tuple(Exception), size(Exception) > 0 ->
            ?log_rpc_result(EventHandler, rpc_handler_exception, ReqId, error, [
                {exception_type, throw},
                {reason, Reason},
                {ignore, false}
            ]),
            handle_exception(State, Function, Exception, SeqId);
        {error, Reason} ->
            ?log_rpc_result(EventHandler, rpc_handler_exception, ReqId, error, [
                {exception_type, error},
                {reason, Reason},
                {stacktrace, Stack},
                {ignore, false}
            ]),
            Reason1 = if is_tuple(Reason) -> element(1, Reason); true -> Reason end,
            handle_error(State, Function, Reason1, SeqId)
    end.

handle_exception(State = #state{service = Service, transport_handler = Trans}, Function, Exception, SeqId) ->
    {struct, XInfo} = ReplySpec = Service:function_info(Function, exceptions),
    ExceptionList = lists:map(fun(X) -> get_except(Exception, X) end, XInfo),
    ExceptionTuple = list_to_tuple([Function | ExceptionList]),
    case lists:all(fun(X) -> X =:= undefined end, ExceptionList) of
        true ->
            handle_unknown_exception(State, Function, Exception, SeqId);
        false ->
            mark_error_to_transport(Trans, logic, element(1, Exception)),
            send_reply(State, Function, ?tMessageType_REPLY,
                {ReplySpec, ExceptionTuple}, SeqId)
    end.

get_except(Exception, {_Fid, _, {struct, {_Module, Type}}, _, _}) when
    element(1, Exception) =:= Type
->
    Exception;
get_except(_, _) ->
    undefined.

%% Called when an exception has been explicitly thrown by the service, but it was
%% not one of the exceptions that was defined for the function.
handle_unknown_exception(State, Function, Exception, SeqId) ->
    handle_error(State, Function, {exception_not_declared_as_thrown, Exception}, SeqId).

handle_error(State = #state{transport_handler = Trans}, Function, Error, SeqId) ->
    Message = genlib:format("An error occurred: ~p", [Error]),
    Exception = #'TApplicationException'{message = Message,
        type = ?TApplicationException_UNKNOWN},
    Reply = {?TApplicationException_Structure, Exception},
    mark_error_to_transport(Trans, transport, "unknown"),
    send_reply(State, Function, ?tMessageType_EXCEPTION, Reply, SeqId).

send_reply(State = #state{protocol = Protocol}, Function, ReplyMessageType, Reply, SeqId) ->
    try
        StartMessage = #protocol_message_begin{
            name = atom_to_list(Function), type = ReplyMessageType, seqid = SeqId
        },
        {Protocol1, ok} = thrift_protocol:write(Protocol, StartMessage),
        {Protocol2, ok} = thrift_protocol:write(Protocol1, Reply),
        {Protocol3, ok} = thrift_protocol:write(Protocol2, message_end),
        {Protocol4, ok} = thrift_protocol:flush_transport(Protocol3),
        {State#state{protocol = Protocol4}, ok}
    catch
        error:{badmatch, {_, {error, _} = Error}} ->
            {State, {error, {send_error, [Error, erlang:get_stacktrace()]}}}
    end.

prepare_result({State, ok}, _) ->
    {ok, State#state.protocol};
prepare_result({State, noreply}, _) ->
    {noreply, State#state.protocol};
prepare_result({State, {error, Reason}}, FunctionName) ->
    {handle_protocol_error(State, FunctionName, Reason), State#state.protocol}.

handle_protocol_error(#state{
    req_id = ReqId,
    rpc_client = RpcClient,
    handler = Handler,
    handler_opts = Opts,
    protocol_stage = Stage,
    transport_handler = Trans,
    event_handler = EventHandler}, Function, Reason)
->
    Handler:handle_error(Function, RpcClient, Reason, Opts),
    ?log_rpc_result(EventHandler, Stage, ReqId, error, [{reason, Reason}]),
    format_protocol_error(Reason, Trans).

format_protocol_error({bad_binary_protocol_version, _Version}, Trans) ->
    mark_error_to_transport(Trans, transport, "bad binary protocol version"),
    {error, badrequest};
format_protocol_error(no_binary_protocol_version, Trans) ->
    mark_error_to_transport(Trans, transport, "no binary protocol version"),
    {error, badrequest};
format_protocol_error({function_undefined, _Fun}, Trans) ->
    mark_error_to_transport(Trans, transport, "unknown method"),
    {error, badrequest};
format_protocol_error({send_error, _}, Trans) ->
    mark_error_to_transport(Trans, transport, "internal error"),
    {error, server_error};
format_protocol_error(_Reason, Trans) ->
    mark_error_to_transport(Trans, transport, "bad request"),
    {error, badrequest}.

-spec mark_error_to_transport(transport_handler(), transport | logic, _Error) -> _.
mark_error_to_transport(TransportHandler, Type, Error) ->
    TransportHandler:mark_thrift_error(Type, Error).
