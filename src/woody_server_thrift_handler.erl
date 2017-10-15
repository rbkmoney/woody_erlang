-module(woody_server_thrift_handler).

%% API
-export([init_handler/3, invoke_handler/1]).

-include_lib("thrift/include/thrift_constants.hrl").
-include_lib("thrift/include/thrift_protocol.hrl").
-include("woody_defs.hrl").

%% Types
-type client_error() :: {client, woody_error:details()}.
-export_type([client_error/0]).

-type state() :: #{
    woody_state   := woody_state:st(),
    handler       := woody:handler(woody:options()),
    service       := woody:service(),
    th_proto      := term(),
    function      => woody:func(),
    args          => woody:args(),
    th_seqid      => term(),
    th_param_type => term(),
    th_msg_type   => thrift_msg_type(),
    th_reply_type => thrift_reply_type()
}.
-export_type([state/0]).

-type thrift_msg_type() ::
    ?tMessageType_CALL   |
    ?tMessageType_ONEWAY |
    ?tMessageType_REPLY  |
    ?tMessageType_EXCEPTION.

-type thrift_reply_type() :: oneway_void | tuple().

-type reply_type() :: oneway_void | call.
-export_type([reply_type/0]).

-type builtin_thrift_error() :: bad_binary_protocol_version | no_binary_protocol_version | _OtherError.
-type thrift_error()         :: unknown_function | multiplexed_request | builtin_thrift_error().

%% Behaviour definition
-callback handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().


%%
%% API
%%
-spec init_handler(binary(), woody:th_handler(), woody_state:st()) ->
    {ok, reply_type(), state()} | {error, client_error()}.
init_handler(Request, {Service, Handler}, WoodyState) ->
    {ok, Transport} = thrift_membuffer_transport:new(Request),
    {ok, Proto} = thrift_binary_protocol:new(Transport,
        [{strict_read, true}, {strict_write, true}]
    ),
    try handle_decode_result(decode_request(decode_message_begin(#{
            woody_state => WoodyState,
            service     => Service,
            handler     => Handler,
            th_proto    => Proto
        })))
    catch
        throw:{woody_decode_error, Error} ->
            handle_decode_error(Error, WoodyState)
    end.

-spec invoke_handler(state()) ->
    {ok, binary()} | {error, woody_error:error()}.
invoke_handler(State) ->
    {Result, #{th_proto := Proto, th_reply_type := MsgType}} = call_handler_safe(State),
    {_, {ok, Reply}} = thrift_protocol:close_transport(Proto),
    handle_result(Result, Reply, MsgType).

%%
%% Internal functions
%%

%% Decode request
-spec decode_message_begin(state()) ->
    state() | no_return().
decode_message_begin(State = #{th_proto := Proto}) ->
    case thrift_protocol:read(Proto, message_begin) of
        {Proto1, #protocol_message_begin{name = Function, type = Type, seqid = SeqId}} when
            Type =:= ?tMessageType_CALL orelse
            Type =:= ?tMessageType_ONEWAY
        ->
            match_reply_type(get_params_type(
                get_function_name(Function),
                State#{th_proto := Proto1, th_msg_type => Type, th_seqid => SeqId}
            ));
        {_, {error, Reason}} ->
            throw_decode_error(Reason)
    end.

get_function_name(Function) ->
    case string:tokens(Function, ?MULTIPLEXED_SERVICE_SEPARATOR) of
        [_ServiceName, _FunctionName] ->
            throw_decode_error(multiplexed_request);
        _ ->
            try list_to_existing_atom(Function)
            catch
                error:badarg -> throw_decode_error(unknown_function)
            end
    end.

-spec get_params_type(woody:func() , state()) ->
    state() | no_return().
get_params_type(Function, State = #{service := Service}) ->
    try get_function_info(Service, Function, params_type) of
        ParamsType ->
            State#{function => Function, th_param_type => ParamsType}
    catch
        error:badarg -> throw_decode_error(unknown_function)
    end.

-spec match_reply_type(state()) ->
    state() | no_return().
match_reply_type(State = #{
    service     := Service,
    function    := Function,
    th_msg_type := ReqType,
    woody_state := WoodyState
}) ->
    ReplyType = get_function_info(Service, Function, reply_type),
    ok = match_reply_type(ReplyType, ReqType),
    State#{th_reply_type => ReplyType, woody_state := add_ev_meta(WoodyState, Service, Function, ReplyType)}.

match_reply_type(ReplyType, ReqType) when
    ReplyType =:= oneway_void , ReqType =/= ?tMessageType_ONEWAY orelse
    ReplyType =/= oneway_void , ReqType =:= ?tMessageType_ONEWAY
->
    throw_decode_error(request_reply_type_mismatch);
match_reply_type(_, _) ->
    ok.

add_ev_meta(WoodyState, Args) ->
    woody_state:add_ev_meta(#{args => Args}, WoodyState).

add_ev_meta(WoodyState, {_, ServiceName}, Function, ReplyType) ->
    woody_state:add_ev_meta(#{
        service  => ServiceName,
        function => Function,
        type     => woody_util:get_rpc_reply_type(ReplyType)
    }, WoodyState).

-spec decode_request(state()) ->
    state() | no_return().
decode_request(State = #{th_proto := Proto, th_param_type := ParamsType, woody_state := WoodyState}) ->
    case thrift_protocol:read(Proto, ParamsType) of
        {Proto1, {ok, Args}} ->
            Args1 = tuple_to_list(Args),
            State#{th_proto => Proto1, args => Args1, woody_state := add_ev_meta(WoodyState, Args1)};
        {_, {error, Error}} ->
            throw_decode_error(Error)
    end.

-spec handle_decode_result(state()) ->
    {ok, reply_type(), state()}.
handle_decode_result(State = #{th_reply_type := oneway_void}) ->
    {ok, oneway_void, State};
handle_decode_result(State) ->
    {ok, call, State}.

-spec handle_decode_error(thrift_error(), woody_state:st()) ->
    {error, client_error()}.
handle_decode_error(Error, WoodyState) ->
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, WoodyState, #{
            error  => <<"thrift protocol read failed">>,
            reason => woody_error:format_details(Error)
        }),
    {error, client_error(Error)}.

-spec client_error(thrift_error()) ->
    client_error().
client_error({bad_binary_protocol_version, Version}) ->
    BinVersion = genlib:to_binary(Version),
    {client, <<"thrift: bad binary protocol version: ", BinVersion/binary>>};
client_error(no_binary_protocol_version) ->
    {client, <<"thrift: no binary protocol version">>};
client_error(unknown_function) ->
    {client, <<"thrift: unknown method">>};
client_error(multiplexed_request) ->
    {client, <<"thrift: multiplexing (not supported)">>};
client_error(request_reply_type_mismatch) ->
    {client, <<"thrift: request reply type mismatch">>};
client_error(Reason) ->
    {client, woody_util:to_binary(["thrift decode error: ", woody_error:format_details(Reason)])}.

-spec throw_decode_error(_) ->
    no_return().
throw_decode_error(Error) ->
    throw({woody_decode_error, Error}).

%% Handle request
-spec call_handler_safe(state()) ->
    {ok | {error, woody_error:error()}, state()}.
call_handler_safe(State) ->
    try handle_success(call_handler(State), State)
    catch
        Class:Reason ->
            handle_function_catch(Class, Reason, erlang:get_stacktrace(), State)
    end.

-spec call_handler(state()) ->
    {ok, woody:result()} | no_return().
call_handler(#{
    woody_state := WoodyState,
    handler     := Handler,
    function    := Function,
    args        := Args})
->
    _ = woody_event_handler:handle_event(?EV_INVOKE_SERVICE_HANDLER, WoodyState, #{}),
    {Module, Opts} = woody_util:get_mod_opts(Handler),
    Module:handle_function(Function, Args, woody_state:get_context(WoodyState), Opts).

-spec handle_success({ok, woody:result()}, state()) ->
    {ok | {error, {system, woody_error:system_error()}}, state()}.
handle_success(Result, State = #{
    function      := Function,
    th_reply_type := ReplyType,
    woody_state   := WoodyState
}) ->
    _ = log_handler_result(ok, WoodyState, #{result => Result}),
    StructName = atom_to_list(Function) ++ "_result",
    case Result of
        {ok, ok} when ReplyType == oneway_void ->
            {ok, State};
        {ok, ok} when ReplyType == {struct, struct, []} ->
            encode_reply(ok, {ReplyType, {StructName}}, State#{th_msg_type => ?tMessageType_REPLY});
        {ok, ReplyData} ->
            Reply = {
                {struct, struct, [{0, undefined, ReplyType, undefined, undefined}]},
                {StructName, ReplyData}
            },
            encode_reply(ok, Reply, State#{th_msg_type => ?tMessageType_REPLY})
    end.

-spec handle_function_catch(woody_error:erlang_except(), _Except,
    woody_error:stack(), state())
->
    {{error, woody_error:error()}, state()}.
handle_function_catch(throw, Except, Stack, State) ->
    handle_exception(Except, Stack, State);
handle_function_catch(error, {woody_error, Error = {_, _, _}}, _Stack, State) ->
    handle_woody_error(Error, State);
handle_function_catch(Class, Error, Stack, State) when
    Class =:= error orelse Class =:= exit
->
    handle_internal_error(Error, Class, Stack, State).


-spec handle_exception(woody_error:business_error() | _Throw, woody_error:stack(), state())
->
    {{error, woody_error:error()}, state()}.
handle_exception(Except, Stack, State = #{
    service       := Service,
    function      := Function,
    th_reply_type := ReplyType,
    woody_state   := WoodyState
}) ->
    {struct, _, XInfo} = ReplySpec = get_function_info(Service, Function, exceptions),
    {ExceptionList, FoundExcept} = lists:mapfoldl(
        fun(X, A) -> get_except(Except, X, A) end, undefined, XInfo),
    case {FoundExcept, ReplyType} of
        {undefined, _} ->
            handle_internal_error(Except, throw, Stack, State);
        {{_Module, _Type}, oneway_void} ->
            log_handler_result(error, WoodyState,
                #{class => business, result => Except, ignore => true}),
            {{error, {business, ignore}}, State};
        {{Module, Type}, _} ->
            log_handler_result(error, WoodyState,
                #{class => business, result => Except, ignore => false}),
            ExceptTuple = list_to_tuple([Function | ExceptionList]),
            encode_reply(
                {error, {business, genlib:to_binary(get_except_name(Module, Type))}},
                {ReplySpec, ExceptTuple},
                State#{th_msg_type => ?tMessageType_REPLY}
            )
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

-spec handle_woody_error(woody_error:system_error() | _Except, state()) ->
    {{error, {system, woody_error:system_error()}}, state()}.
handle_woody_error(Error, State = #{woody_state := WoodyState, th_reply_type := oneway_void}) ->
    log_handler_result(error, WoodyState, #{class => system, result => Error, ignore => true}),
    {{error, {system, Error}}, State};
handle_woody_error(Error, State = #{woody_state := WoodyState}) ->
    log_handler_result(error, WoodyState, #{class => system, result => Error, ignore => false}),
    {{error, {system, Error}}, State}.

-spec handle_internal_error(_Error, woody_error:erlang_except(), woody_error:stack(), state()) ->
    {{error, {system, {internal, woody_error:source(), woody_error:details()}}}, state()}.
handle_internal_error(Error, ExcClass, Stack, State = #{woody_state := WoodyState, th_reply_type := oneway_void}) ->
    log_handler_result(error, WoodyState,
        #{class => system, result => Error, except_class => ExcClass, stack => Stack, ignore => true}),
    {{error, {system, {internal, result_unexpected, <<>>}}}, State};
handle_internal_error(Error, ExcClass, Stack, State = #{woody_state := WoodyState}) ->
    log_handler_result(error, WoodyState,
        #{class => system, result => Error, except_class => ExcClass, stack => Stack, ignore => false}),
    {{error, {system, {internal, result_unexpected,
        format_unexpected_error(ExcClass, woody_error:format_details(Error), Stack)}}}, State}.

-spec encode_reply(ok | {error, woody_error:business_error()}, _Result, state()) ->
    {ok | {error, woody_error:error()}, state()}.
encode_reply(Status, Reply, State = #{
    th_proto    := Proto,
    function    := Function,
    th_msg_type := ReplyMessageType,
    th_seqid    := SeqId,
    woody_state := WoodyState
}) ->
    try
        StartMessage = #protocol_message_begin{
            name = atom_to_list(Function), type = ReplyMessageType, seqid = SeqId
        },
        {Protocol1, ok} = thrift_protocol:write(Proto, StartMessage),
        {Protocol2, ok} = thrift_protocol:write(Protocol1, Reply),
        {Protocol3, ok} = thrift_protocol:write(Protocol2, message_end),
        {Protocol4, ok} = thrift_protocol:flush_transport(Protocol3),
        {Status, State#{th_proto => Protocol4}}
    catch
        error:{badmatch, {_, {error, Error}}} ->
            Stack = erlang:get_stacktrace(),
            Reason = woody_error:format_details(Error),
            _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, WoodyState, #{
                    error  => <<"thrift protocol write failed">>,
                    reason => Reason,
                    class  => error,
                    stack  => Stack
                }),
            {{error, {system, {internal, result_unexpected, format_unexpected_error(error, Reason, Stack)}}}, State}
    end.

-spec handle_result(ok | {error, woody_error:error()}, binary(), thrift_reply_type()) ->
    {ok, binary()} | {error, woody_error:error()}.
handle_result(_, _, oneway_void) ->
    {ok, <<>>};
handle_result(ok, Reply, _) ->
    {ok, Reply};
handle_result({error, {business, ExceptName}}, Except, _) ->
    {error, {business, {ExceptName, Except}}};
handle_result(Error = {error, _}, _, _) ->
    Error.

get_function_info({Module, Service}, Function, Info) ->
    Module:function_info(Service, Function, Info).

log_handler_result(Status, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(?EV_SERVICE_HANDLER_RESULT, WoodyState, ExtraMeta#{status => Status}).

format_unexpected_error(Class, Reason, Stack) ->
    woody_util:to_binary(
        [Class, ":", Reason, " ", genlib_format:format_stacktrace(Stack)]
    ).
