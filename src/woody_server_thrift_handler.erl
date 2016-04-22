-module(woody_server_thrift_handler).

%% API
-export([start/6]).

-include_lib("thrift/include/thrift_constants.hrl").
-include_lib("thrift/include/thrift_protocol.hrl").
-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-type error_reason() :: any().
-type result()       :: any().
-type handler_opts() :: list().
-type args()         :: tuple().
-export_type([handler_opts/0, args/0, result/0, error_reason/0]).

-callback handle_function(woody_t:func(), args(), woody_t:rpc_id(),
    woody_client:client(), handler_opts())
->
    ok | {ok, result()} | {error, result()} | no_return().

-callback handle_error(woody_t:func(), error_reason(), woody_t:rpc_id(),
    woody_client:client(), handler_opts())
-> _.

%%
%% API
%%
-define(log_rpc_result(EventHandler, Status, Meta),
    woody_event_handler:handle_event(EventHandler, ?EV_SERVICE_HANDLER_RESULT,
        Meta#{status => Status})
).

-define(stage_read  , protocol_read).
-define(stage_write , protocol_write).

-define(error_unknown_function , no_function).
-define(error_multiplexed_req  , multiplexed_request).
-define(error_protocol_send    , send_error).

-record(state, {
    rpc_id            :: woody_t:rpc_id(),
    woody_client      :: woody_client:client(),
    service           :: module(),
    handler           :: woody_t:handler(),
    handler_opts      :: handler_opts(),
    protocol          :: any(),
    protocol_stage    :: ?stage_read | ?stage_write,
    event_handler     :: woody_t:handler(),
    transport_handler :: woody_t:handler()
}).

-type thrift_handler() :: {woody_t:service(), woody_t:handler(), handler_opts()}.
-export_type([thrift_handler/0]).

-type event_handler() :: woody_t:handler().
-type transport_handler() :: woody_t:handler().

-spec start(thrift_transport:t_transport(), woody_t:rpc_id(), woody_client:client(),
    thrift_handler(), event_handler(), transport_handler())
->
    ok | noreply | {error, _Reason}.
start(Transport, RpcId, WoodyClient, {Service, Handler, Opts},
    EventHandler, TransportHandler)
->
    {ok, Protocol} = thrift_binary_protocol:new(Transport,
        [{strict_read, true}, {strict_write, true}]
    ),
    {Result, Protocol1} = process(#state{
            rpc_id            = RpcId,
            woody_client      = WoodyClient,
            service           = Service,
            handler           = Handler,
            handler_opts      = Opts,
            protocol          = Protocol,
            protocol_stage    = ?stage_read,
            event_handler     = EventHandler,
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
            State2 = release_oneway(Type, State1),
            FunctionName = get_function_name(Function),
            prepare_response(handle_function(FunctionName,
                get_params_type(Service, FunctionName),
                State2,
                SeqId
            ), FunctionName);
        {error, Reason} ->
            handle_protocol_error(State1, undefined, Reason)
    end.

release_oneway(?tMessageType_ONEWAY, State = #state{protocol = Protocol}) ->
    {Protocol1, ok} = thrift_protocol:flush_transport(Protocol),
    State#state{protocol = Protocol1};
release_oneway(_, State) ->
    State.

get_function_name(Function) ->
    case string:tokens(Function, ?MULTIPLEXED_SERVICE_SEPARATOR) of
        [_ServiceName, _FunctionName] ->
            {error, ?error_multiplexed_req};
        _ ->
            try list_to_existing_atom(Function)
            catch
                error:badarg -> {error, ?error_unknown_function}
            end
    end.

get_params_type(Service, Function) ->
    try Service:function_info(Function, params_type)
    catch
        error:badarg -> ?error_unknown_function
    end.

handle_function(Error = {error, _}, _, State, _SeqId) ->
    {State, Error};

handle_function(_, ?error_unknown_function, State, _SeqId) ->
    {State, {error, ?error_unknown_function}};

handle_function(Function, InParams, State = #state{protocol = Protocol}, SeqId) ->
    {Protocol1, ReadResult} = thrift_protocol:read(Protocol, InParams),
    State1 = State#state{protocol = Protocol1},
    case ReadResult of
        {ok, Args} ->
            try_call_handler(Function, Args,
                State1#state{protocol_stage = ?stage_write}, SeqId);
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
    rpc_id        = RpcId,
    woody_client  = WoodyClient,
    handler       = Handler,
    handler_opts  = Opts,
    event_handler = EventHandler})
->
    woody_event_handler:handle_event(EventHandler, ?EV_INVOKE_SERVICE_HANDLER, RpcId#{
        function => Function, args => Args, options => Opts
    }),
    Result = Handler:handle_function(Function, Args, RpcId, WoodyClient, Opts),
    ?log_rpc_result(EventHandler, ok, RpcId#{result => Result}),
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
        rpc_id        = RpcId,
        service       = Service,
        event_handler = EventHandler
    }, Function, Class, Reason, Stack, SeqId)
->
    ReplyType = Service:function_info(Function, reply_type),
    case {Class, Reason} of
        _Error when ReplyType =:= oneway_void ->
            ?log_rpc_result(EventHandler, error,
                RpcId#{class => Class, reason => Reason, ignore => true}),
            {State, noreply};
        {throw, Exception} when is_tuple(Exception), size(Exception) > 0 ->
            ?log_rpc_result(EventHandler, error,
                RpcId#{class => throw, reason => Exception, ignore => false}),
            handle_exception(State, Function, Exception, SeqId);
        {error, Reason} ->
            ?log_rpc_result(EventHandler, error, RpcId#{class => error,
                reason => Reason, stack => Stack, ignore => false}),
            Reason1 = if is_tuple(Reason) -> element(1, Reason); true -> Reason end,
            handle_error(State, Function, Reason1, SeqId)
    end.

handle_exception(State = #state{service = Service, transport_handler = Trans},
    Function, Exception, SeqId)
->
    {struct, XInfo} = ReplySpec = Service:function_info(Function, exceptions),
    {ExceptionList, FoundExcept} = lists:mapfoldl(
        fun(X, A) -> get_except(Exception, X, A) end, undefined, XInfo),
    ExceptionTuple = list_to_tuple([Function | ExceptionList]),
    case FoundExcept of
        undefined ->
            handle_unknown_exception(State, Function, Exception, SeqId);
        {Module, Type} ->
            mark_error_to_transport(Trans, logic, get_except_name(Module, Type)),
            send_reply(State, Function, ?tMessageType_REPLY,
                {ReplySpec, ExceptionTuple}, SeqId)
    end.

get_except(Exception, {_Fid, _, {struct, {Module, Type}}, _, _}, _) when
    element(1, Exception) =:= Type
->
    {Exception, {Module, Type}};
get_except(_, _, TypesModule) ->
    {undefined, TypesModule}.

get_except_name(Module, Type) ->
    {struct, Fields} = Module:struct_info(Type),
    case lists:keyfind(exception_name, 4, Fields) of
        false -> Type;
        Field -> element(5, Field)
    end.

%% Called
%% - when an exception has been explicitly thrown by the service, but it was
%% not one of the exceptions that was defined for the function.
%% - when the service explicitly returned {error, Reason}
handle_unknown_exception(State, Function, Exception, SeqId) ->
    handle_error(State, Function, {exception_not_declared_as_thrown, Exception}, SeqId).

handle_error(State = #state{transport_handler = Trans}, Function, Error, SeqId) ->
    Message = genlib:format("An error occurred: ~p", [Error]),
    Exception = #'TApplicationException'{message = Message,
        type = ?TApplicationException_UNKNOWN},
    Reply = {?TApplicationException_Structure, Exception},
    mark_error_to_transport(Trans, transport, "application exception unknown"),
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
            {State, {error, {?error_protocol_send, [Error, erlang:get_stacktrace()]}}}
    end.

prepare_response({State, ok}, _) ->
    {ok, State#state.protocol};
prepare_response({State, noreply}, _) ->
    {noreply, State#state.protocol};
prepare_response({State, {error, Reason}}, FunctionName) ->
    {handle_protocol_error(State, FunctionName, Reason), State#state.protocol}.

handle_protocol_error(State = #state{
    rpc_id            = RpcId,
    protocol_stage    = Stage,
    transport_handler = Trans,
    event_handler     = EventHandler}, Function, Reason)
->
    call_error_handler(State, Function, Reason),
    woody_event_handler:handle_event(EventHandler, ?EV_THRIFT_ERROR,
        RpcId#{stage => Stage, reason => Reason}),
    format_protocol_error(Reason, Trans).

call_error_handler(#state{
    rpc_id        = RpcId,
    woody_client  = WoodyClient,
    handler       = Handler,
    handler_opts  = Opts,
    event_handler = EventHandler}, Function, Reason) ->
    try
        Handler:handle_error(Function, Reason, RpcId, WoodyClient, Opts)
    catch
        Class:Error ->
            woody_event_handler:handle_event(EventHandler, ?EV_INTERNAL_ERROR, RpcId#{
                error => <<"service error handler failed">>,
                class => Class,
                reason => Error,
                stack => erlang:get_stacktrace()
            })
    end.

format_protocol_error({bad_binary_protocol_version, _Version}, Trans) ->
    mark_error_to_transport(Trans, transport, "bad binary protocol version"),
    {error, bad_request};
format_protocol_error(no_binary_protocol_version, Trans) ->
    mark_error_to_transport(Trans, transport, "no binary protocol version"),
    {error, bad_request};
format_protocol_error({?error_unknown_function, _Fun}, Trans) ->
    mark_error_to_transport(Trans, transport, "unknown method"),
    {error, bad_request};
format_protocol_error({?error_multiplexed_req, _Fun}, Trans) ->
    mark_error_to_transport(Trans, transport, "multiplexing not supported"),
    {error, bad_request};
format_protocol_error({?error_protocol_send, _}, Trans) ->
    mark_error_to_transport(Trans, transport, "internal error"),
    {error, server_error};
format_protocol_error(_Reason, Trans) ->
    mark_error_to_transport(Trans, transport, "bad request"),
    {error, bad_request}.

%% Unfortunately there is no proper way to provide additional info to
%% the transport, where the actual send happens: the Protocol object
%% representing thrift protocol and transport in this module is opaque.
%% So we have to use the hack with a proc dict here.
-spec mark_error_to_transport(transport_handler(), transport | logic, _Error) -> _.
mark_error_to_transport(TransportHandler, Type, Error) ->
    TransportHandler:mark_thrift_error(Type, Error).