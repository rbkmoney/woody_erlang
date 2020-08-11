-module(woody_server_thrift_v2).

-behaviour(woody_server).

-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% woody_server callback
-export([child_spec/2]).

%% API
-export([get_routes/1]).

%% cowboy_handler callbacks
-behaviour(cowboy_handler).
-export([init/2]).
-export([terminate/3]).

%% Types
-type handler_limits() :: #{
    max_heap_size => integer() %% process words, see erlang:process_flag(max_heap_size, MaxHeapSize) for details.
}.
-export_type([handler_limits/0]).

-type transport_opts() :: #{
    connection_type   => worker | supervisor,
    handshake_timeout => timeout(),
    max_connections   => ranch:max_conns(),
    logger            => module(),
    num_acceptors     => pos_integer(),
    shutdown          => timeout() | brutal_kill,
    socket            => any(),
    socket_opts       => any(),
    transport         => module() % ranch_tcp | ranch_ssl
}.

-export_type([transport_opts/0]).

-type route(T) :: {woody:path(), module(), T}.
-export_type([route/1]).

-type read_body_opts() :: cowboy_req:read_body_opts().

%% ToDo: restructure options() to split server options and route options and
%%       get rid of separate route_opts() when backward compatibility isn't an issue.

-type options() :: #{
    handlers              := list(woody:http_handler(woody:th_handler())),
    event_handler         := woody:ev_handlers(),
    ip                    := inet:ip_address(),
    port                  := inet:port_number(),
    protocol              => thrift,
    transport             => http,
    transport_opts        => transport_opts(),
    read_body_opts        => read_body_opts(),
    protocol_opts         => protocol_opts(),
    handler_limits        => handler_limits(),
    additional_routes     => [route(_)],
    %% shutdown_timeout: time to drain current connections when shutdown signal is recieved
    %% NOTE: when changing this value make sure to take into account the request_timeout and
    %% max_keepalive settings of protocol_opts() to achieve the desired effect
    shutdown_timeout      => timeout()
}.
-export_type([options/0]).

-type route_opts() :: #{
    handlers              := list(woody:http_handler(woody:th_handler())),
    event_handler         := woody:ev_handlers(),
    protocol              => thrift,
    transport             => http,
    read_body_opts        => read_body_opts(),
    handler_limits        => handler_limits()
}.
-export_type([route_opts/0]).
-define(ROUTE_OPT_NAMES, [
    handlers,
    event_handler,
    protocol,
    transport,
    read_body_opts,
    handler_limits
]).

-type re_mp() :: tuple().
-type protocol_opts() :: cowboy_http:opts().

-export_type([protocol_opts/0]).

-type state() :: #{
    th_handler     => woody:th_handler(),
    ev_handler     := woody:ev_handlers(),
    read_body_opts := read_body_opts(),
    handler_limits := handler_limits(),
    regexp_meta    := re_mp(),
    url            => woody:url(),
    woody_state    => woody_state:st()
}.

-type cowboy_init_result() ::
    {ok, cowboy_req:req(), state() | undefined}
    | {module(), cowboy_req:req(), state() | undefined, any()}.

-type check_result() ::
    {ok, cowboy_req:req(), state() | undefined}
    | {stop, cowboy_req:req(), undefined}.

-define(DEFAULT_ACCEPTORS_POOLSIZE, 100).
-define(DEFAULT_SHUTDOWN_TIMEOUT,   0).

%% nginx should be configured to take care of various limits.

-define(DUMMY_REQ_ID, <<"undefined">>).

%%
%% woody_server callback
%%
-spec child_spec(atom(), options()) ->
    supervisor:child_spec().
child_spec(Id, Opts) ->
    {Transport, TransportOpts} = get_socket_transport(Opts),
    CowboyOpts = get_cowboy_config(Opts),
    RanchRef = {?MODULE, Id},
    DrainSpec = make_drain_childspec(RanchRef, Opts),
    RanchSpec = ranch:child_spec(RanchRef, Transport, TransportOpts, cowboy_clear, CowboyOpts),
    make_server_childspec(Id, [RanchSpec, DrainSpec]).

make_drain_childspec(Ref, Opts) ->
    ShutdownTimeout = maps:get(shutdown_timeout, Opts, ?DEFAULT_SHUTDOWN_TIMEOUT),
    DrainOpts = #{shutdown => ShutdownTimeout, ranch_ref => Ref},
    woody_server_http_drainer:child_spec(DrainOpts).

make_server_childspec(Id, Children) ->
    Flags = #{strategy => one_for_all},
    #{
        id => Id,
        start => {genlib_adhoc_supervisor, start_link, [Flags, Children]},
        type => supervisor
    }.

get_socket_transport(Opts = #{ip := Ip, port := Port}) ->
    Defaults      = #{num_acceptors => ?DEFAULT_ACCEPTORS_POOLSIZE},
    TransportOpts = maps:merge(Defaults, maps:get(transport_opts, Opts, #{})),
    Transport     = maps:get(transport, TransportOpts, ranch_tcp),
    SocketOpts    = [{ip, Ip}, {port, Port} | maps:get(socket_opts, TransportOpts, [])],
    {Transport, set_ranch_option(socket_opts, SocketOpts, TransportOpts)}.

set_ranch_option(Key, Value, Opts) ->
    Opts#{Key => Value}.

-spec get_cowboy_config(options()) ->
    protocol_opts().
get_cowboy_config(Opts = #{event_handler := EvHandler}) ->
    ok         = validate_event_handler(EvHandler),
    Dispatch   = get_dispatch(Opts),
    ProtocolOpts = maps:get(protocol_opts, Opts, #{}),
    CowboyOpts   = maps:put(stream_handlers, [woody_monitor_h, woody_trace_h, cowboy_stream_h], ProtocolOpts),
    Env = woody_trace_h:env(maps:with([event_handler], Opts)),
    maps:merge(#{
        env => Env#{dispatch => Dispatch},
        max_header_name_length => 64
    }, CowboyOpts).

validate_event_handler(Handlers) when is_list(Handlers) ->
    true = lists:all(
        fun(Handler) ->
            is_tuple(woody_util:get_mod_opts(Handler))
        end, Handlers),
    ok;
validate_event_handler(Handler) ->
    validate_event_handler([Handler]).


-spec get_dispatch(options())->
    cowboy_router:dispatch_rules().
get_dispatch(Opts) ->
    cowboy_router:compile([{'_', get_all_routes(Opts)}]).

-spec get_all_routes(options())->
    [route(_)].
get_all_routes(Opts) ->
    AdditionalRoutes = maps:get(additional_routes, Opts, []),
    AdditionalRoutes ++ get_routes(maps:with(?ROUTE_OPT_NAMES, Opts)).

-spec get_routes(route_opts()) ->
    [route(state())].
get_routes(Opts = #{handlers := Handlers}) ->
    State0 = init_state(Opts),
    [get_route(State0, Handler) || Handler <- Handlers].

-spec get_route(state(), woody:http_handler(woody:th_handler())) ->
    route(state()).
get_route(State0, {PathMatch, {Service, Handler}}) ->
    {PathMatch, ?MODULE, State0#{th_handler => {Service, Handler}}};
get_route(_, Handler) ->
    error({bad_handler_spec, Handler}).

-spec init_state(route_opts()) ->
    state().
init_state(Opts = #{}) ->
    #{
        ev_handler     => maps:get(event_handler, Opts),
        read_body_opts => maps:get(read_body_opts, Opts, #{}),
        handler_limits => maps:get(handler_limits, Opts, #{}),
        regexp_meta    => compile_filter_meta()
    }.

-spec compile_filter_meta() ->
    re_mp().
compile_filter_meta() ->
    {ok, Re} = re:compile(?HEADER_META_RE, [unicode, caseless]),
    Re.

%%
%% cowboy_http_handler callbacks
%%
-spec init(cowboy_req:req(), state()) ->
    cowboy_init_result().
init(Req, Opts = #{ev_handler := EvHandler, handler_limits := Limits}) ->
    ok = set_handler_limits(Limits),
    Url = unicode:characters_to_binary(cowboy_req:uri(Req)),
    WoodyState = create_dummy_state(EvHandler),
    Opts1 = update_woody_state(Opts#{url => Url}, WoodyState, Req),
    case check_request(Req, Opts1) of
        {ok, Req1, State} -> handle(Req1, State);
        {stop, Req1, State} -> {ok, Req1, State}
    end.

-spec set_handler_limits(handler_limits()) ->
    ok.
set_handler_limits(Limits) ->
    case maps:get(max_heap_size, Limits, undefined) of
        undefined ->
            ok;
        MaxHeapSize ->
            _ = erlang:process_flag(max_heap_size, #{
                size         => MaxHeapSize,
                kill         => true,
                error_logger => true
            }),
            ok
    end.

-spec handle(cowboy_req:req(), state()) ->
    {ok, cowboy_req:req(), _}.
handle(Req, State = #{
    url            := Url,
    woody_state    := WoodyState,
    read_body_opts := ReadBodyOpts,
    th_handler     := ThriftHandler
}) ->
    Req2 = case get_body(Req, ReadBodyOpts) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            _ = handle_event(?EV_SERVER_RECEIVE, WoodyState, #{url => Url, status => ok}),
            handle_request(Body, ThriftHandler, WoodyState, Req1);
        {ok, <<>>, Req1} ->
            reply_client_error(400, <<"body empty">>, Req1, State)
    end,
    {ok, Req2, undefined}.

create_dummy_state(EvHandler) ->
    DummyRpcID = #{
        span_id   => ?DUMMY_REQ_ID,
        trace_id  => ?DUMMY_REQ_ID,
        parent_id => ?DUMMY_REQ_ID
    },
    woody_state:new(server, woody_context:new(DummyRpcID), EvHandler).

-spec terminate(_Reason, _Req, state() | _) ->
    ok.
terminate(normal, _Req, _Status) ->
    ok;
terminate(Reason, _Req, #{ev_handler := EvHandler} = Opts) ->
    WoodyState = maps:get(woody_state, Opts, create_dummy_state(EvHandler)),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, WoodyState, #{
            error  => <<"http handler terminated abnormally">>,
            reason => woody_error:format_details(Reason),
            class  => undefined,
            final  => true
        }),
    ok.


%% init functions

-define(CODEC, thrift_strict_binary_codec).

%% First perform basic http checks: method, content type, etc,
%% then check woody related headers: IDs, deadline, meta.

-spec check_request(cowboy_req:req(), state()) ->
    check_result().
check_request(Req, State) ->
    check_method(cowboy_req:method(Req), Req, State).

-spec check_method(woody:http_header_val(), cowboy_req:req(), state()) ->
    check_result().
check_method(<<"POST">>, Req, State) ->
    check_content_type(cowboy_req:header(<<"content-type">>, Req), Req, State);

check_method(Method, Req, State) ->
    Req1 = cowboy_req:set_resp_header(<<"allow">>, <<"POST">>, Req),
    Reason = woody_util:to_binary(["wrong method: ", Method]),
    reply_bad_header(405, Reason, Req1, State).

-spec check_content_type(woody:http_header_val() | undefined, cowboy_req:req(), state()) ->
    check_result().
check_content_type(?CONTENT_TYPE_THRIFT, Req, State) ->
    Header = cowboy_req:header(<<"accept">>, Req),
    check_accept(Header, Req, State);
check_content_type(BadCType, Req, State) ->
    reply_bad_header(415, woody_util:to_binary(["wrong content type: ", BadCType]), Req, State).

-spec check_accept(woody:http_header_val() | undefined, cowboy_req:req(), state()) ->
    check_result().
check_accept(Accept, Req, State) when
    Accept =:= ?CONTENT_TYPE_THRIFT ;
    Accept =:= undefined
->
    check_woody_headers(Req, State);
check_accept(BadAccept, Req1, State) ->
    reply_bad_header(406, woody_util:to_binary(["wrong client accept: ", BadAccept]), Req1, State).

-spec check_woody_headers(cowboy_req:req(), state()) ->
    check_result().
check_woody_headers(Req, State = #{woody_state := WoodyState0}) ->
    case get_rpc_id(Req) of
        {ok, RpcId, Req1} ->
            WoodyState1 = set_cert(Req1, set_rpc_id(RpcId, WoodyState0)),
            check_deadline_header(
                cowboy_req:header(?HEADER_DEADLINE, Req1),
                Req1,
                update_woody_state(State, WoodyState1, Req1)
            );
        {error, BadRpcId, Req1} ->
            WoodyState1 = set_rpc_id(BadRpcId, WoodyState0),
            reply_bad_header(400, woody_util:to_binary(["bad ", ?HEADER_PREFIX, " id header"]),
                Req1, update_woody_state(State, WoodyState1, Req1)
            )
    end.

-spec get_rpc_id(cowboy_req:req()) ->
    {ok | error, woody:rpc_id(), cowboy_req:req()}.
get_rpc_id(Req) ->
    check_ids(maps:fold(
        fun get_rpc_id/3,
        #{req => Req},
        #{
            span_id   => ?HEADER_RPC_ID,
            trace_id  => ?HEADER_RPC_ROOT_ID,
            parent_id => ?HEADER_RPC_PARENT_ID
        }
    )).

get_rpc_id(Id, Header, Acc = #{req := Req}) ->
    case cowboy_req:header(Header, Req) of
        undefined ->
            Acc#{Id => ?DUMMY_REQ_ID, req => Req, status => error};
        IdVal ->
            Acc#{Id => IdVal, req => Req}
    end.

check_ids(Map = #{status := error, req := Req}) ->
    {error, maps:without([req, status], Map), Req};
check_ids(Map = #{req := Req}) ->
    {ok, maps:without([req], Map), Req}.

-spec check_deadline_header(Header, Req, state()) -> cowboy_init_result() when
    Header :: woody:http_header_val() | undefined, Req :: cowboy_req:req().
check_deadline_header(undefined, Req, State) ->
    check_metadata_headers(cowboy_req:headers(Req), Req, State);
check_deadline_header(DeadlineBin, Req, State) ->
    try woody_deadline:from_binary(DeadlineBin) of
        Deadline -> check_deadline(Deadline, Req, State)
    catch
        error:{bad_deadline, Error} ->
            ErrorDescription = woody_util:to_binary(["bad ", ?HEADER_DEADLINE, " header: ", Error]),
            reply_bad_header(400, ErrorDescription, Req, State)
    end.

-spec check_deadline(woody:deadline(), cowboy_req:req(), state()) ->
    check_result().
check_deadline(Deadline, Req, State = #{url := Url, woody_state := WoodyState}) ->
    case woody_deadline:is_reached(Deadline) of
        true ->
            _ = handle_event(
                ?EV_SERVER_RECEIVE,
                WoodyState,
                #{url => Url, status => error, reason => <<"Deadline reached">>}
            ),
            Req1 = handle_error({system, {internal, resource_unavailable, <<"deadline reached">>}}, Req, WoodyState),
            {stop, Req1, undefined};
        false ->
            WoodyState1 = set_deadline(Deadline, WoodyState),
            Headers = cowboy_req:headers(Req),
            check_metadata_headers(Headers, Req, update_woody_state(State, WoodyState1, Req))
    end.

-spec check_metadata_headers(woody:http_headers(), cowboy_req:req(), state()) ->
    check_result().
check_metadata_headers(Headers, Req, State = #{woody_state := WoodyState, regexp_meta := ReMeta}) ->
    WoodyState1 = set_metadata(find_metadata(Headers, ReMeta), WoodyState),
    {ok, Req, update_woody_state(State, WoodyState1, Req)}.

-spec find_metadata(woody:http_headers(), re_mp()) ->
    woody_context:meta().
find_metadata(Headers, Re) ->
    RpcId = ?HEADER_RPC_ID,
    RootId = ?HEADER_RPC_ROOT_ID,
    ParentId = ?HEADER_RPC_PARENT_ID,
    maps:fold(
        fun(H, V, Acc) when
            H =/= RpcId andalso
            H =/= RootId andalso
            H =/= ParentId
        ->
            case re:replace(H, Re, "", [{return, binary}, anchored]) of
                H -> Acc;
                MetaHeader -> Acc#{MetaHeader => V}
            end;
           (_, _, Acc) -> Acc
        end,
      #{}, Headers).

-spec set_rpc_id(woody:rpc_id(), woody_state:st()) ->
    woody_state:st().
set_rpc_id(RpcId, WoodyState) ->
    woody_state:update_context(woody_context:new(RpcId), WoodyState).

-spec set_cert(cowboy_req:req(), woody_state:st()) ->
    woody_state:st().
set_cert(Req, WoodyState) ->
    Cert = woody_cert:from_req(Req),
    Context = woody_state:get_context(WoodyState),
    woody_state:update_context(woody_context:set_cert(Cert, Context), WoodyState).

-spec set_deadline(woody:deadline(), woody_state:st()) ->
    woody_state:st().
set_deadline(Deadline, WoodyState) ->
    woody_state:add_context_deadline(Deadline, WoodyState).

-spec set_metadata(woody_context:meta(), woody_state:st()) ->
    woody_state:st().
set_metadata(Meta, WoodyState) ->
    woody_state:add_context_meta(Meta, WoodyState).

-spec reply_bad_header(woody:http_code(), woody:http_header_val(), cowboy_req:req(), state()) ->
    {stop, cowboy_req:req(), undefined}.
reply_bad_header(Code, Reason, Req, State) when is_integer(Code) ->
    Req1 = reply_client_error(Code, Reason, Req, State),
    {stop, Req1, undefined}.

-spec reply_client_error(woody:http_code(), woody:http_header_val(), cowboy_req:req(), state()) ->
    cowboy_req:req().
reply_client_error(Code, Reason, Req, #{url := Url, woody_state := WoodyState}) ->
    _ = handle_event(
        ?EV_SERVER_RECEIVE,
        WoodyState,
        #{url => Url, status => error, reason => Reason}
    ),
    reply(Code, set_error_headers(<<"Result Unexpected">>, Reason, Req), WoodyState).

-spec get_body(cowboy_req:req(), read_body_opts()) ->
    {ok, woody:http_body(), cowboy_req:req()}.
get_body(Req, Opts) ->
    do_get_body(<<>>, Req, Opts).

do_get_body(Body, Req, Opts) ->
    case cowboy_req:read_body(Req, Opts) of
        {ok, Body1, Req1} ->
            {ok, <<Body/binary, Body1/binary>>, Req1};
        {more, Body1, Req1} ->
            do_get_body(<<Body/binary, Body1/binary>>, Req1, Opts)
    end.

-spec handle_request(woody:http_body(), woody:th_handler(), woody_state:st(), cowboy_req:req()) ->
    cowboy_req:req().
handle_request(Body, ThriftHandler = {Service, _}, WoodyState, Req) ->
    ok = woody_monitor_h:set_event(?EV_SERVICE_HANDLER_RESULT, Req),
    Buffer = ?CODEC:new(Body),
    case thrift_processor_codec:read_function_call(Buffer, ?CODEC, Service) of
        {ok, SeqId, Invocation, Leftovers} ->
            case ?CODEC:close(Leftovers) of
                <<>> ->
                    handle_invocation(SeqId, Invocation, ThriftHandler, Req, WoodyState);
                Bytes ->
                    handle_decode_error({excess_response_body, Bytes, Invocation}, Req, WoodyState)
            end;
        {error, Reason} ->
            handle_decode_error(Reason, Req, WoodyState)
    end.

-spec handle_decode_error(_Reason, cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
handle_decode_error(Reason, Req, WoodyState) ->
    _ = handle_event(
        ?EV_INTERNAL_ERROR,
        WoodyState,
        #{
            error  => <<"thrift protocol read failed">>,
            reason => woody_error:format_details(Reason)
        }
    ),
    handle_error(client_error(Reason), Req, WoodyState).

-spec client_error(_Reason) ->
    {client, woody_error:details()}.
client_error({bad_binary_protocol_version, Version}) ->
    BinVersion = genlib:to_binary(Version),
    {client, <<"thrift: bad binary protocol version: ", BinVersion/binary>>};
client_error(no_binary_protocol_version) ->
    {client, <<"thrift: no binary protocol version">>};
client_error({bad_function_name, FName}) ->
    case binary:match(FName, <<":">>) of
        nomatch ->
            {client, woody_util:to_binary([<<"thrift: unknown function: ">>, FName])};
        _ ->
            {client, <<"thrift: multiplexing (not supported)">>}
    end;
client_error(Reason) ->
    {client, woody_util:to_binary([<<"thrift decode error: ">>, woody_error:format_details(Reason)])}.

-spec handle_invocation(integer(), Invocation, woody:th_handler(), cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req() when Invocation :: {call | oneway, woody:func(), woody:args()}.
handle_invocation(SeqId, {ReplyType, Function, Args}, {Service, Handler}, Req, WoodyState) ->
    WoodyState1 = add_ev_meta(WoodyState, Service, ReplyType, Function, Args),
    case ReplyType of
        call ->
            Result = handle_call(Handler, Service, Function, Args, WoodyState1),
            handle_result(Result, Service, Function, SeqId, Req, WoodyState1);
        oneway ->
            Req1 = reply(200, Req, WoodyState1),
            _Result = handle_call(Handler, Service, Function, Args, WoodyState1),
            Req1
    end.

-type call_result() ::
    ok |
    {reply, woody:result()} |
    {exception, _TypeName, _Exception} |
    {error, {system, woody_error:system_error()}}.

-spec handle_call(woody:handler(_), woody:service(), woody:func(), woody:args(), woody_state:st()) ->
    call_result().
handle_call(Handler, Service, Function, Args, WoodyState) ->
    try
        Result = call_handler(Handler, Function, Args, WoodyState),
        _ = handle_event(
            ?EV_SERVICE_HANDLER_RESULT,
            WoodyState,
            #{status => ok, result => Result}
        ),
        case Result of
            {ok, ok} -> ok;
            {ok, Reply} -> {reply, Reply}
        end
    catch
        throw:Exception:Stack ->
            process_handler_throw(Exception, Stack, Service, Function, WoodyState);
        Class:Reason:Stack ->
            process_handler_error(Class, Reason, Stack, WoodyState)
    end.

-spec call_handler(woody:handler(_), woody:func(), woody:args(), woody_state:st()) ->
    {ok, woody:result()} | no_return().
call_handler(Handler, Function, Args, WoodyState) ->
    _ = handle_event(?EV_INVOKE_SERVICE_HANDLER, WoodyState, #{}),
    {Module, Opts} = woody_util:get_mod_opts(Handler),
    Module:handle_function(Function, Args, woody_state:get_context(WoodyState), Opts).

-spec process_handler_throw(_Exception, woody_error:stack(), woody:service(), woody:func(), woody_state:st()) ->
    {exception, _TypeName, _Exception} |
    {error, {system, woody_error:system_error()}}.
process_handler_throw(Exception, Stack, Service, Function, WoodyState) ->
    case thrift_processor_codec:match_exception(Service, Function, Exception) of
        {ok, TypeName} ->
            _ = handle_event(
                ?EV_SERVICE_HANDLER_RESULT,
                WoodyState,
                #{status => error, class => business, result => Exception}
            ),
            {exception, TypeName, Exception};
        {error, _} ->
            process_handler_error(throw, Exception, Stack, WoodyState)
    end.

-spec process_handler_error(_Class :: atom(), _Reason, woody_error:stack(), woody_state:st()) ->
    {error, {system, woody_error:system_error()}}.
process_handler_error(error, {woody_error, Error = {_, _, _}}, _Stack, WoodyState) ->
    _ = handle_event(
        ?EV_SERVICE_HANDLER_RESULT,
        WoodyState,
        #{status => error, class => system, result => Error}
    ),
    {error, {system, Error}};
process_handler_error(Class, Reason, Stack, WoodyState) ->
    _ = handle_event(
        ?EV_SERVICE_HANDLER_RESULT,
        WoodyState,
        #{status => error, class => system, result => Reason, except_class => Class, stack => Stack}
    ),
    Error = {internal, result_unexpected, format_unexpected_error(Class, Reason, Stack)},
    {error, {system, Error}}.

-spec handle_result(call_result(), woody:service(), woody:func(), integer(), Req, woody_state:st()) ->
    Req when Req :: cowboy_req:req().
handle_result(Res, Service, Function, SeqId, Req, WoodyState) when
    Res == ok; element(1, Res) == reply
->
    Buffer = ?CODEC:new(),
    case thrift_processor_codec:write_function_result(Buffer, ?CODEC, Service, Function, Res, SeqId) of
        {ok, Buffer1} ->
            Response = ?CODEC:close(Buffer1),
            reply(200, cowboy_req:set_resp_body(Response, Req), WoodyState);
        {error, Reason} ->
            handle_encode_error(Reason, Req, WoodyState)
    end;
handle_result(Res = {exception, TypeName, Exception}, Service, Function, SeqId, Req, WoodyState) ->
    Buffer = ?CODEC:new(),
    case thrift_processor_codec:write_function_result(Buffer, ?CODEC, Service, Function, Res, SeqId) of
        {ok, Buffer1} ->
            ExceptionName = get_exception_name(TypeName, Exception),
            Response = ?CODEC:close(Buffer1),
            handle_error({business, {ExceptionName, Response}}, Req, WoodyState);
        {error, Reason} ->
            handle_encode_error(Reason, Req, WoodyState)
    end;
handle_result({error, Error}, _Service, _Function, _SeqId, Req, WoodyState) ->
    handle_error(Error, Req, WoodyState).

get_exception_name({{struct, exception, {_Mod, Name}}, _}, _) ->
    genlib:to_binary(Name);
get_exception_name(_TypeName, Exception) ->
    genlib:to_binary(element(1, Exception)).

-spec handle_encode_error(_Reason, cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
handle_encode_error(Reason, Req, WoodyState) ->
    _ = handle_event(
        ?EV_INTERNAL_ERROR,
        WoodyState,
        #{
            error  => <<"thrift protocol write failed">>,
            reason => woody_error:format_details(Reason)
        }
    ),
    Error = {internal, result_unexpected, format_unexpected_error(error, Reason, [])},
    handle_error({system, Error}, Req, WoodyState).

add_ev_meta(WoodyState, Service = {_, ServiceName}, ReplyType, Function, Args) ->
    woody_state:add_ev_meta(#{
        service        => ServiceName,
        service_schema => Service,
        function       => Function,
        args           => Args,
        type           => get_rpc_reply_type(ReplyType),
        deadline       => woody_context:get_deadline(woody_state:get_context(WoodyState))
    }, WoodyState).

get_rpc_reply_type(oneway) -> cast;
get_rpc_reply_type(call) -> call.

format_unexpected_error(Class, Reason, Stack) ->
    woody_util:to_binary(
        [Class, ":", woody_error:format_details(Reason), " ", genlib_format:format_stacktrace(Stack)]
    ).

-spec handle_error(Error, cowboy_req:req(), woody_state:st()) -> cowboy_req:req() when
    Error :: woody_error:error() | woody_server_thrift_handler:client_error().
handle_error({business, {ExceptName, Except}}, Req, WoodyState) ->
    reply(200, set_error_headers(<<"Business Error">>, ExceptName, cowboy_req:set_resp_body(Except, Req)), WoodyState);
handle_error({client, Error}, Req, WoodyState) ->
    reply(400, set_error_headers(<<"Result Unexpected">>, Error, Req), WoodyState);
handle_error({system, {internal, result_unexpected, Details}}, Req, WoodyState) ->
    reply(500, set_error_headers(<<"Result Unexpected">>, Details, Req), WoodyState);
handle_error({system, {internal, resource_unavailable, Details}}, Req, WoodyState) ->
    reply(503, set_error_headers(<<"Resource Unavailable">>, Details, Req), WoodyState);
handle_error({system, {internal, result_unknown, Details}}, Req, WoodyState) ->
    reply(504, set_error_headers(<<"Result Unknown">>, Details, Req), WoodyState);
handle_error({system, {external, result_unexpected, Details}}, Req, WoodyState) ->
    reply(502, set_error_headers(<<"Result Unexpected">>, Details, Req), WoodyState);
handle_error({system, {external, resource_unavailable, Details}}, Req, WoodyState) ->
    reply(502, set_error_headers(<<"Resource Unavailable">>, Details, Req), WoodyState);
handle_error({system, {external, result_unknown, Details}}, Req, WoodyState) ->
    reply(502, set_error_headers(<<"Result Unknown">>, Details, Req), WoodyState).

-spec set_error_headers(woody:http_header_val(), woody:http_header_val(), cowboy_req:req()) ->
    cowboy_req:req().
set_error_headers(Class, Reason, Req) ->
    Headers = #{
        ?HEADER_E_CLASS => Class,
        ?HEADER_E_REASON => Reason
    },
    cowboy_req:set_resp_headers(Headers, Req).

-spec reply(woody:http_code(), cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
reply(200, Req, WoodyState) ->
    do_reply(200, cowboy_req:set_resp_header(<<"content-type">>, ?CONTENT_TYPE_THRIFT, Req), WoodyState);
reply(Code, Req, WoodyState) ->
    do_reply(Code, Req, WoodyState).

do_reply(Code, Req, WoodyState) ->
    _ = handle_event(?EV_SERVER_SEND, WoodyState, #{code => Code, status => reply_status(Code)}),
    cowboy_req:reply(Code, Req).

reply_status(200) -> ok;
reply_status(_) -> error.

handle_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).

update_woody_state(State, WoodyState, Req) ->
    ok = woody_monitor_h:put_woody_state(WoodyState, Req),
    State#{woody_state => WoodyState}.
