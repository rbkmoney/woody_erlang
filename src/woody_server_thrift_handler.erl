-module(woody_server_thrift_handler).

%% API
-export([start/4]).

-include_lib("thrift/include/thrift_constants.hrl").
-include_lib("thrift/include/thrift_protocol.hrl").
-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-type error_reason() :: any().
-type result()       :: any().
-type handler_opts() :: term().
-type args()         :: tuple().
-export_type([handler_opts/0, args/0, result/0, error_reason/0]).

-type except() :: {_ThriftExcept, woody_context:ctx()}.
-export_type([except/0]).

-callback handle_function(woody_t:func(), args(),
    woody_context:ctx(), handler_opts())
->
    {ok | result(), woody_context:ctx()} | no_return().

%%
%% API
%%
-define(STAGE_READ  , protocol_read).
-define(STAGE_WRITE , protocol_write).

-define(ERROR_UNKNOWN_FUNCTION , no_function).
-define(ERROR_MILTIPLEXED_REQ  , multiplexed_request).
-define(ERROR_PROTOCOL_SEND    , send_error).

-record(state, {
    context           :: woody_context:ctx(),
    service           :: woody_t:service(),
    handler           :: woody_t:handler(),
    handler_opts      :: handler_opts(),
    protocol          :: any(),
    protocol_stage    :: ?STAGE_READ | ?STAGE_WRITE,
    transport_handler :: woody_t:handler()
}).

-type thrift_handler() :: {woody_t:service(), woody_t:handler(), handler_opts()}.
-export_type([thrift_handler/0]).

-type transport_handler() :: woody_t:handler().

-spec start(thrift_transport:t_transport(), thrift_handler(), transport_handler(), woody_context:ctx())
->
    {ok | noreply | {error, _Reason}, cowboy_req:req()}.
start(Transport, {Service, Handler, Opts}, TransportHandler, Context) ->
    {ok, Protocol} = thrift_binary_protocol:new(Transport,
        [{strict_read, true}, {strict_write, true}]
    ),
    {Result, Protocol1} = process(#state{
            context           = Context,
            service           = Service,
            handler           = Handler,
            handler_opts      = Opts,
            protocol          = Protocol,
            protocol_stage    = ?STAGE_READ,
            transport_handler = TransportHandler
    }),
    {_, Req} = thrift_protocol:close_transport(Protocol1),
    {Result, Req}.


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
            ));
        {error, Reason} ->
            {handle_protocol_error(State1, Reason), State1#state.protocol}
    end.

release_oneway(?tMessageType_ONEWAY, State = #state{protocol = Protocol}) ->
    {Protocol1, ok} = thrift_protocol:flush_transport(Protocol),
    State#state{protocol = Protocol1};
release_oneway(_, State) ->
    State.

get_function_name(Function) ->
    case string:tokens(Function, ?MULTIPLEXED_SERVICE_SEPARATOR) of
        [_ServiceName, _FunctionName] ->
            {error, ?ERROR_MILTIPLEXED_REQ};
        _ ->
            try list_to_existing_atom(Function)
            catch
                error:badarg -> {error, ?ERROR_UNKNOWN_FUNCTION}
            end
    end.

get_params_type(Service, Function) ->
    try get_function_info(Service, Function, params_type)
    catch
        error:badarg -> ?ERROR_UNKNOWN_FUNCTION
    end.

handle_function(Error = {error, _}, _, State, _SeqId) ->
    {State, Error};

handle_function(_, ?ERROR_UNKNOWN_FUNCTION, State, _SeqId) ->
    {State, {error, ?ERROR_UNKNOWN_FUNCTION}};

handle_function(Function, InParams, State = #state{protocol = Protocol}, SeqId) ->
    {Protocol1, ReadResult} = thrift_protocol:read(Protocol, InParams),
    State1 = State#state{protocol = Protocol1},
    case ReadResult of
        {ok, Args} ->
            try_call_handler(Function, Args,
                State1#state{protocol_stage = ?STAGE_WRITE}, SeqId);
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

call_handler(Function, Args, #state{
    context       = Context,
    handler       = Handler,
    handler_opts  = Opts,
    service       = {_, ServiceName}})
->
    _ = woody_event_handler:handle_event(
         woody_context:get_ev_handler(Context),
         ?EV_INVOKE_SERVICE_HANDLER,
         woody_context:get_rpc_id(Context),
         #{service => ServiceName, function => Function, args => Args, options => Opts, context => Context}),
    Result = Handler:handle_function(Function, Args, Context, Opts),
    _ = log_rpc_result(ok, Context, #{result => Result}),
    Result.

handle_result({ok, _Context}, State, Function, SeqId) ->
    handle_success(State, Function, ok, SeqId);
handle_result({Response, _Context}, State, Function, SeqId) ->
    handle_success(State, Function, Response, SeqId).

handle_success(State = #state{service = Service}, Function, Result, SeqId) ->
    ReplyType = get_function_info(Service, Function, reply_type),
    StructName = atom_to_list(Function) ++ "_result",
    case Result of
        ok when ReplyType == {struct, struct, []} ->
            send_reply(State, Function, ?tMessageType_REPLY,
                {ReplyType, {StructName}}, SeqId);
        ok when ReplyType == oneway_void ->
            {State, noreply};
        ReplyData ->
            Reply = {
                {struct, struct, [{0, undefined, ReplyType, undefined, undefined}]},
                {StructName, ReplyData}
            },
            send_reply(State, Function, ?tMessageType_REPLY, Reply, SeqId)
    end.

handle_function_catch(State = #state{
        context       = Context,
        service       = Service
    }, Function, Class, Reason, Stack, SeqId)
->
    ReplyType = get_function_info(Service, Function, reply_type),
    case {Class, Reason} of
        _Error when ReplyType =:= oneway_void ->
            _ = log_rpc_result(error, Context,
                #{class => Class, reason => Reason, ignore => true}),
            {State, noreply};
        {throw, {Exception, _Context}} when is_tuple(Exception), size(Exception) > 0 ->
            _ = log_rpc_result(error, Context,
                #{class => throw, reason => Exception, ignore => false}),
            handle_exception(State, Function, Exception, SeqId);
        {throw, Exception} ->
            _ = log_rpc_result(error, Context,
                #{class => throw, reason => Exception, ignore => false}),
            handle_unknown_exception(State, Function, Exception, SeqId);
        {error, Reason} ->
            _ = log_rpc_result(error, Context,
                #{class => error, reason => Reason, stack => Stack, ignore => false}),
            Reason1 = short_reason(Reason),
            handle_error(State, Function, Reason1, SeqId)
    end.

short_reason(Reason) when is_tuple(Reason) ->
    element(1, Reason);
short_reason(Reason) ->
    Reason.

handle_exception(State, Function, {exception, Exception}, SeqId) ->
    handle_exception(State, Function, Exception, SeqId);
handle_exception(State = #state{service = Service, transport_handler = Trans},
    Function, Exception, SeqId)
->
    {struct, _, XInfo} = ReplySpec = get_function_info(Service, Function, exceptions),
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

get_except(Exception, {_Fid, _, {struct, exception, {Module, Type}}, _, _}, TypesModule) ->
    case Module:record_name(Type) of
        Name when Name =:= element(1, Exception) ->
            {Exception, {Module, Type}};
        _ ->
            {undefined, TypesModule}
    end.

get_except_name(Module, Type) ->
    {struct, exception, Fields} = Module:struct_info(Type),
    case lists:keyfind(exception_name, 4, Fields) of
        false -> Type;
        Field -> element(5, Field)
    end.

%% Called
%% - when an exception has been explicitly thrown by the service, but it was
%% not one of the exceptions that was defined for the function.
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
            {State, {error, {?ERROR_PROTOCOL_SEND, [Error, erlang:get_stacktrace()]}}}
    end.

prepare_response({State, ok}) ->
    {ok, State#state.protocol};
prepare_response({State, noreply}) ->
    {noreply, State#state.protocol};
prepare_response({State, {error, Reason}}) ->
    {handle_protocol_error(State, Reason), State#state.protocol}.

handle_protocol_error(#state{
    context           = Context,
    protocol_stage    = Stage,
    transport_handler = Trans}, Reason)
->
    _ = woody_event_handler:handle_event(
        woody_context:get_ev_handler(Context),
        ?EV_THRIFT_ERROR,
        woody_context:get_rpc_id(Context),
        #{stage => Stage, reason => Reason}),
    format_protocol_error(Reason, Trans).

format_protocol_error({bad_binary_protocol_version, _Version}, Trans) ->
    mark_error_to_transport(Trans, transport, "bad binary protocol version"),
    {error, bad_request};
format_protocol_error(no_binary_protocol_version, Trans) ->
    mark_error_to_transport(Trans, transport, "no binary protocol version"),
    {error, bad_request};
format_protocol_error({?ERROR_UNKNOWN_FUNCTION, _Fun}, Trans) ->
    mark_error_to_transport(Trans, transport, "unknown method"),
    {error, bad_request};
format_protocol_error({?ERROR_MILTIPLEXED_REQ, _Fun}, Trans) ->
    mark_error_to_transport(Trans, transport, "multiplexing not supported"),
    {error, bad_request};
format_protocol_error({?ERROR_PROTOCOL_SEND, _}, Trans) ->
    mark_error_to_transport(Trans, transport, "internal error"),
    {error, server_error};
format_protocol_error(_Reason, Trans) ->
    mark_error_to_transport(Trans, transport, "bad request"),
    {error, bad_request}.

get_function_info({Module, Service}, Function, Info) ->
    Module:function_info(Service, Function, Info).

%% Unfortunately there is no proper way to provide additional info to
%% the transport, where the actual send happens: the Protocol object
%% representing thrift protocol and transport in this module is opaque.
%% So we have to use the hack with a proc dict here.
-spec mark_error_to_transport(transport_handler(), transport | logic, _Error) -> _.
mark_error_to_transport(TransportHandler, Type, Error) ->
    TransportHandler:mark_thrift_error(Type, Error).

log_rpc_result(Status, Context, Meta) ->
    woody_event_handler:handle_event(
      woody_context:get_ev_handler(Context),
      ?EV_SERVICE_HANDLER_RESULT,
      woody_context:get_rpc_id(Context),
      Meta#{status => Status}).
