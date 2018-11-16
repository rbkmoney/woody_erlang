-module(woody_server_thrift_http_handler).

-behaviour(woody_server).

-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% woody_server callback
-export([child_spec/2]).

%% API
-export([get_routes/1]).

%% cowboy callbacks
-export([init/2]).
-export([terminate/3]).


%% Types
-type handler_limits() :: #{
    max_heap_size       => integer(), %% process words, see erlang:process_flag(max_heap_size, MaxHeapSize) for details.
    total_mem_threshold => integer()  %% bytes, see erlang:memory() for details.
}.
-export_type([handler_limits/0]).

-type transport_opts() :: [
    ranch_tcp:opt()                       |
    {socket          , inet:socket()}     |
    {max_connections , ranch:max_conns()} |
    {shutdown        , timeout()}
].
-export_type([transport_opts/0]).

-type route(T) :: {woody:path(), module(), T}.
-export_type([route/1]).

%% ToDo: restructure options() to split server options and route options and
%%       get rid of separate route_opts() when backward compatibility isn't an issue.
-type options() :: #{
    handlers              := list(woody:http_handler(woody:th_handler())),
    event_handler         := woody:ev_handler(),
    ip                    := inet:ip_address(),
    port                  := inet:port_number(),
    protocol              => thrift,
    transport             => http,
    transport_opts        => transport_opts(),
    protocol_opts         => cowboy_http:opts(),
    handler_limits        => handler_limits(),
    additional_routes     => [route(_)]
}.
-export_type([options/0]).

-type route_opts() :: #{
    handlers              := list(woody:http_handler(woody:th_handler())),
    event_handler         := woody:ev_handler(),
    protocol              => thrift,
    transport             => http,
    handler_limits        => handler_limits()
}.
-export_type([route_opts/0]).

-type re_mp() :: tuple(). %% fuck otp for hiding the types.
-type server_opts() :: #{
    max_chunk_length => non_neg_integer(),
    regexp_meta     => re_mp()
}.

-type state() :: #{
    th_handler     := woody:th_handler(),
    ev_handler     := woody:ev_handler(),
    server_opts    := server_opts(),
    handler_limits := handler_limits(),
    url            => woody:url(),
    woody_state    => woody_state:st()
}.

-type cowboy_init_result() ::
    {ok       , cowboy_req:req(), state()} |
    {shutdown , cowboy_req:req(), undefined}.

-define(DEFAULT_ACCEPTORS_POOLSIZE, 100).

%% nginx should be configured to take care of various limits.
-define(MAX_CHUNK_LENGTH, 65535). %% 64kbytes

-define(DUMMY_REQ_ID, <<"undefined">>).

%%
%% woody_server callback
%%
-spec child_spec(_Id, options()) ->
    supervisor:child_spec().
child_spec(Id, Opts = #{
    ip            := Ip,
    port          := Port
}) ->
    % TODO
    % It's essentially a _transport option_ as it is in the newer ranch versions, therefore we should
    % probably make it such here too. Ultimately we need to stop looking woody environment vars up.
    SocketOpts = [{ip, Ip}, {port, Port}],
    TransportOpts0 = maps:get(transport_opts, Opts, #{}),
    {Transport, TransportOpts} = get_socket_transport(SocketOpts, TransportOpts0),
    CowboyOpts = get_cowboy_config(Opts),
    ct:log("Child_spec call Transport: ~p, TransportOpts: ~p, CowboyOpts: ~p", [Transport, TransportOpts, CowboyOpts]),
    ranch:child_spec({?MODULE, Id}, Transport, TransportOpts, cowboy_clear, CowboyOpts).

get_socket_transport(SocketOpts, TransportOpts) ->
    AcceptorsPool  = genlib_app:env(woody, acceptors_pool_size, ?DEFAULT_ACCEPTORS_POOLSIZE),
    {ranch_tcp, set_ranch_option(socket_opts, SocketOpts, set_ranch_option(num_acceptors, AcceptorsPool, TransportOpts))}.

set_ranch_option(Key, Value, Opts) ->
    Opts#{Key => Value}.

-spec get_cowboy_config(options()) ->
    cowboy_http:opts().
get_cowboy_config(Opts = #{event_handler := EvHandler}) ->
    ok         = validate_event_handler(EvHandler),
    Dispatch   = get_dispatch(Opts),
    CowboyOpts = maps:get(protocol_opts, Opts, #{}),
    HttpTrace  = get_http_trace(EvHandler, config()),
    maps:merge(#{
        env => maps:merge(HttpTrace, #{dispatch => Dispatch}),
        max_header_name_length => 64
    }, CowboyOpts).

validate_event_handler(Handler) ->
    {_, _} = woody_util:get_mod_opts(Handler),
    ok.

-spec get_dispatch(options())->
    cowboy_router:dispatch_rules().
get_dispatch(Opts) ->
    cowboy_router:compile([{'_', get_all_routes(Opts)}]).

-spec get_all_routes(options())->
    [route(_)].
get_all_routes(Opts) ->
    AdditionalRoutes = maps:get(additional_routes, Opts, []),
    AdditionalRoutes ++ get_routes(maps:with([handlers, event_handler, handler_limits, protocol, transport], Opts)).

-spec get_routes(route_opts())->
    [route(state())].
get_routes(Opts = #{handlers := Handlers, event_handler := EvHandler}) ->
    Limits = maps:get(handler_limits, Opts, #{}),
    get_routes(config(), Limits, EvHandler, Handlers, []).

-spec get_routes(server_opts(), handler_limits(), woody:ev_handler(), Handlers, Routes) -> Routes when
    Handlers   :: list(woody:http_handler(woody:th_handler())),
    Routes     :: [route(state())].
get_routes(_, _, _, [], Routes) ->
    Routes;
get_routes(ServerOpts, Limits, EvHandler, [{PathMatch, {Service, Handler}} | T], Routes) ->
    get_routes(ServerOpts, Limits, EvHandler, T, [
        {PathMatch, ?MODULE, #{
            th_handler     => {Service, Handler},
            ev_handler     => EvHandler,
            server_opts    => ServerOpts,
            handler_limits => Limits
        }} | Routes
    ]);
get_routes(_, _, _, [Handler | _], _) ->
    error({bad_handler_spec, Handler}).

-spec config() ->
    server_opts().
config() ->
    #{
       max_chunk_length => ?MAX_CHUNK_LENGTH,
       regexp_meta => compile_filter_meta()
    }.

-spec compile_filter_meta() ->
    re_mp().
compile_filter_meta() ->
    {ok, Re} = re:compile([?NORMAL_HEADER_META_RE], [unicode, caseless]),
    Re.

-spec get_http_trace(woody:ev_handler(), server_opts()) ->
    #{'onrequest':=fun((_) -> any()), 'onresponse':=fun((_,_,_,_) -> any())}.
get_http_trace(EvHandler, ServerOpts) ->
    #{
        onrequest => fun(Req) ->
            trace_req(genlib_app:env(woody, trace_http_server), Req, EvHandler, ServerOpts) end,
        onresponse => fun(Code, Headers, Body, Req) ->
            trace_resp(genlib_app:env(woody, trace_http_server), Req, Code, Headers, Body, EvHandler) end
    }.

-spec trace_req(true, cowboy_req:req(), woody:ev_handler(), server_opts()) ->
    cowboy_req:req().
trace_req(true, Req, EvHandler, ServerOpts) ->
    Url = cowboy_req:uri(Req),
    Headers = cowboy_req:headers(Req),
    Meta = #{
         role    => server,
         event   => <<"http request received">>,
         url     => Url,
         headers => Headers
     },
    Meta1 = case get_body(Req, ServerOpts) of
        {ok, Body, _} ->
             Meta#{body => Body, body_status => ok}
    end,
    _ = woody_event_handler:handle_event(EvHandler, ?EV_TRACE, undefined, Meta1),
    Req;
trace_req(_, Req, _, _) ->
    Req.

trace_resp(true, Req, Code, Headers, Body, EvHandler) ->
    _ = woody_event_handler:handle_event(EvHandler, ?EV_TRACE, undefined, #{
         role    => server,
         event   => <<"http response send">>,
         code    => Code,
         headers => Headers,
         body    => Body}),
    Req;
trace_resp(_, Req, _, _, _, _) ->
    Req.


%%
%% cowboy_http_handler callbacks
%%
-spec init(cowboy_req:req(), state()) ->
    cowboy_init_result().
init(Req, Opts = #{ev_handler := EvHandler, handler_limits := Limits}) ->
    ok = set_handler_limits(Limits),
    Url = cowboy_req:uri(Req),
    DummyRpcID = #{
        span_id   => ?DUMMY_REQ_ID,
        trace_id  => ?DUMMY_REQ_ID,
        parent_id => ?DUMMY_REQ_ID
    },
    WoodyState = woody_state:new(server, woody_context:new(DummyRpcID), EvHandler),
    case have_resources_to_continue(Limits) of
        true ->
            Opts1 = Opts#{url => Url, woody_state => WoodyState},
            ct:log("~p [~p] Req: ~p\nState: ~p", [self(), ?FUNCTION_NAME, Req, Opts1]),
            {ok, Req2, State} = check_request(Req, Opts1),
            ct:log("~p Request passed all checks, state: ~p", [self(), State]),
            handle(Req2, State);
        false ->
            ct:log("Erlang exceeded memory"),
            Details = <<"erlang vm exceeded total memory threshold">>,
            _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState,
                #{url => Url, status => error, reason => Details}),
            Req2 = handle_error({system, {internal, resource_unavailable, Details}}, Req, WoodyState),
            {stop, Req2, undefined}
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

-spec have_resources_to_continue(handler_limits()) ->
    boolean().
have_resources_to_continue(Limits) ->
    case maps:get(total_mem_threshold, Limits, undefined) of
        undefined ->
            true;
        MaxTotalMem when is_integer(MaxTotalMem) ->
            erlang:memory(total) < MaxTotalMem
    end.

-spec handle(cowboy_req:req(), state()) ->
    {ok, cowboy_req:req(), _}.
handle(Req, State = #{
    url         := Url,
    woody_state := WoodyState,
    server_opts := ServerOpts,
    th_handler  := ThriftHandler
}) ->
    ct:log("~p ~p[~p]", [self(), ?MODULE, ?FUNCTION_NAME]),
    Req2 = case get_body(Req, ServerOpts) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState, #{url => Url, status => ok}),
            handle_request(Body, ThriftHandler, WoodyState, Req1);
        {ok, <<>>, Req1} ->
            reply_client_error(400, <<"body empty">>, Req1, State);
        {{error, body_too_large}, _, Req1} ->
            reply_client_error(413, <<"body too large">>, Req1, State);
        {{error, Reason}, _, Req1} ->
            reply_client_error(400, woody_util:to_binary(["body read error: ", Reason]), Req1, State)
    end,
    {ok, Req2, undefined}.

-spec terminate(_Reason, _Req, state() | _) ->
    ok.
terminate(normal, _Req, _Status) ->
    ok;
terminate(Reason, _Req, #{woody_state := WoodyState}) ->
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, WoodyState, #{
            error  => <<"http handler terminated abnormally">>,
            reason => woody_error:format_details(Reason),
            class  => undefined,
            stack  => erlang:get_stacktrace(),
            final  => true
        }),
    ok.


%% init functions

%% First perform basic http checks: method, content type, etc,
%% then check woody related headers: IDs, deadline, meta.

-spec check_request(cowboy_req:req(), state()) ->
    cowboy_init_result().
check_request(Req, State) ->
    ct:log("~p [~p]", [self(), ?FUNCTION_NAME]),
    Method = cowboy_req:method(Req),
    check_method(Method, Req, State).

-spec check_method(woody:http_header_val(), cowboy_req:req(), state()) ->
    cowboy_init_result().
check_method(<<"POST">>, Req, State) ->
    ct:log("~p [~p] POST", [self(), ?FUNCTION_NAME]),
    Header = cowboy_req:header(<<"content-type">>, Req),
    check_content_type(Header, Req, State);

check_method(Method, Req, State) ->
    ct:log("~p ~p[~p]", [self(), ?MODULE, ?FUNCTION_NAME]),
    Req1 = cowboy_req:set_resp_header(<<"allow">>, <<"POST">>, Req),
    Reason = woody_util:to_binary(["wrong method: ", Method]),
    ct:log("~p ~p[~p] Reason: ~p, Req: ~p", [self(), ?MODULE, ?FUNCTION_NAME, Reason, Req1]),
    reply_bad_header(405, Reason, Req1, State).

-spec check_content_type(woody:http_header_val() | undefined, cowboy_req:req(), state()) ->
    cowboy_init_result().
check_content_type(?CONTENT_TYPE_THRIFT, Req, State) ->
    ct:log("~p [~p]", [self(), ?FUNCTION_NAME]),
    Header = cowboy_req:header(<<"accept">>, Req),
    check_accept(Header, Req, State);
check_content_type(BadCType, Req, State) ->
    ct:log("~p [~p] BadType", [self(), ?FUNCTION_NAME]),
    reply_bad_header(415, woody_util:to_binary(["wrong content type: ", BadCType]), Req, State).

-spec check_accept(woody:http_header_val() | undefined, cowboy_req:req(), state()) ->
    cowboy_init_result().
check_accept(Accept, Req, State) when
    Accept =:= ?CONTENT_TYPE_THRIFT ;
    Accept =:= undefined
->
    ct:log("~p [~p]", [self(), ?FUNCTION_NAME]),
    check_woody_headers(Req, State);
check_accept(BadAccept, Req1, State) ->
    ct:log("~p [~p] BadAccept", [self(), ?FUNCTION_NAME]),
    reply_bad_header(406, woody_util:to_binary(["wrong client accept: ", BadAccept]), Req1, State).

-spec check_woody_headers(cowboy_req:req(), state()) ->
    cowboy_init_result().
check_woody_headers(Req, State = #{woody_state := WoodyState}) ->
    ct:log("~p [~p] Req: ~p\nState: ~p", [self(), ?FUNCTION_NAME, Req, State]),
    {Mode, Req0} = woody_util:get_req_headers_mode(Req),
    case get_rpc_id(Req0, Mode) of
        {ok, RpcId, Req1} ->
            ct:log("~p ~p[~p] case {ok, ~p, ~p}", [self(), ?MODULE, ?FUNCTION_NAME, RpcId, Req1]),
            Header = cowboy_req:header(?HEADER_DEADLINE(Mode), Req1),
            check_deadline_header(
                Header, 
                Req1,
                Mode,
                State#{woody_state => set_rpc_id(RpcId, WoodyState)}
            );
        {error, BadRpcId, Req1} ->
            ct:log("~p [~p] case {error, _, _}", [self(), ?FUNCTION_NAME]),
            reply_bad_header(400, woody_util:to_binary(["bad ", ?HEADER_PREFIX(Mode), " id header"]),
                Req1, State#{woody_state => set_rpc_id(BadRpcId, WoodyState)}
            )
    end.

-spec get_rpc_id(cowboy_req:req(), woody_util:headers_mode()) ->
    {ok | error, woody:rpc_id(), cowboy_req:req()}.
get_rpc_id(Req, Mode) ->
    ct:log("~p ~p[~p]", [self(), ?MODULE, ?FUNCTION_NAME]),
    check_ids(maps:fold(
        fun get_rpc_id/3,
        #{req => Req},
        #{
            span_id   => ?HEADER_RPC_ID(Mode),
            trace_id  => ?HEADER_RPC_ROOT_ID(Mode),
            parent_id => ?HEADER_RPC_PARENT_ID(Mode)
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

-spec check_deadline_header(Header, Req, woody_util:headers_mode(), state()) -> cowboy_init_result() when
    Header :: woody:http_header_val() | undefined, Req :: cowboy_req:req().
check_deadline_header(undefined, Req, Mode, State) ->
    ct:log("~p [~p] undefined", [self(), ?FUNCTION_NAME]),
    Headers = cowboy_req:headers(Req),
    check_metadata_headers(Headers, Req, Mode, State);
check_deadline_header(DeadlineBin, Req, Mode, State) ->
    ct:log("~p [~p]", [self(), ?FUNCTION_NAME]),
    try woody_deadline:from_binary(DeadlineBin) of
        Deadline -> check_deadline(Deadline, Req, Mode, State)
    catch
        error:{bad_deadline, Error} ->
            ErrorDescription = woody_util:to_binary(["bad ", ?HEADER_DEADLINE(Mode), " header: ", Error]),
            reply_bad_header(400, ErrorDescription, Req, State)
    end.

-spec check_deadline(woody:deadline(), cowboy_req:req(), woody_util:headers_mode(), state()) ->
    cowboy_init_result().
check_deadline(Deadline, Req, Mode, State = #{url := Url, woody_state := WoodyState}) ->
    ct:log("~p [~p]", [self(), ?FUNCTION_NAME]),
    case woody_deadline:is_reached(Deadline) of
        true ->
            woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState,
                #{url => Url, status => error, reason => <<"Deadline reached">>}),
            Req1 = handle_error({system, {internal, resource_unavailable, <<"deadline reached">>}}, Req, WoodyState),
            {stop, Req1, undefined};
        false ->
            NewState = State#{woody_state => set_deadline(Deadline, WoodyState)},
            Headers = cowboy_req:headers(Req),
            check_metadata_headers(Headers, Req, Mode, NewState)
    end.

-spec check_metadata_headers(woody:http_headers(), cowboy_req:req(), woody_util:headers_mode(), state()) ->
    cowboy_init_result().
check_metadata_headers(Headers, Req, Mode, State = #{woody_state := WoodyState, server_opts := ServerOpts}) ->
    {ok, Req, State#{woody_state => set_metadata(find_metadata(Headers, Mode, ServerOpts), WoodyState)}}.

-spec find_metadata(woody:http_headers(), woody_util:headers_mode(), server_opts()) ->
    woody_context:meta().
find_metadata(Headers, Mode, #{regexp_meta := _Re}) ->
    %% TODO: Use compiled Re after headers transition ends
    ct:log("~p ~p[~p] Headers: ~p", [self(), ?MODULE, ?FUNCTION_NAME, Headers]),
    RpcId = ?HEADER_RPC_ID(Mode),
    RootId = ?HEADER_RPC_ROOT_ID(Mode),
    ParentId = ?HEADER_RPC_PARENT_ID(Mode),
    maps:fold(
        fun(H, V, Acc) when
            H =/= RpcId andalso
            H =/= RootId andalso
            H =/= ParentId
        ->
            case re:replace(H, ?HEADER_META_RE(Mode), "", [{return, binary}, anchored]) of
                H -> Acc;
                MetaHeader -> Acc#{MetaHeader => V}
            end;
           (_ ,_, Acc) -> Acc
        end,
      #{}, Headers).

-spec set_rpc_id(woody:rpc_id(), woody_state:st()) ->
    woody_state:st().
set_rpc_id(RpcId, WoodyState) ->
    ct:log("~p ~p[~p] RpcId: ~p", [self(), ?MODULE, ?FUNCTION_NAME, RpcId]),
    Res = woody_state:update_context(woody_context:new(RpcId), WoodyState),
    ct:log("~p ~p[~p] Res: ~p", [self(), ?MODULE, ?FUNCTION_NAME, Res]),
    Res.

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
    ct:log("~p ~p[~p]", [self(), ?MODULE, ?FUNCTION_NAME]),
    Req1 = reply_client_error(Code, Reason, Req, State),
    {stop, Req1, undefined}.

-spec reply_client_error(woody:http_code(), woody:http_header_val(), cowboy_req:req(), state()) ->
    cowboy_req:req().
reply_client_error(Code, Reason, Req, #{url := Url, woody_state := WoodyState}) ->
    ct:log("~p ~p[~p] code: ~p", [self(), ?MODULE, ?FUNCTION_NAME, Code]),
    _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState,
            #{url => Url, status => error, reason => Reason}),
    ct:log("~p ~p[~p] back to ~p", [self(), ?MODULE, ?FUNCTION_NAME, ?FUNCTION_NAME]),
    reply(Code, set_error_headers(<<"Result Unexpected">>, Reason, Req), WoodyState).

%% handle functions
-spec get_body(cowboy_req:req(), server_opts()) ->
    {ok | {error, atom()}, woody:http_body(), cowboy_req:req()}.
get_body(Req, #{max_chunk_length := MaxChunk}) ->
    ct:log("~p ~p[~p]", [self(), ?MODULE, ?FUNCTION_NAME]),
    do_get_body(<<>>, Req, [{length, MaxChunk}]).

do_get_body(Body, Req, Opts) ->
    ct:log("~p ~p[~p] opts: ~p", [self(), ?MODULE, ?FUNCTION_NAME, Opts]),
    case cowboy_req:read_body(Req, maps:from_list(Opts)) of
        {ok, Body1, Req1} ->
            {ok, <<Body/binary, Body1/binary>>, Req1};
        {more, Body1, Req1} ->
            do_get_body(<<Body/binary, Body1/binary>>, Req1, Opts)
    end.

-spec handle_request(woody:http_body(), woody:th_handler(), woody_state:st(), cowboy_req:req()) ->
    cowboy_req:req().
handle_request(Body, ThriftHander, WoodyState, Req) ->
    case woody_server_thrift_handler:init_handler(Body, ThriftHander, WoodyState) of
        {ok, oneway_void, HandlerState} ->
            Req1 = reply(200, Req, WoodyState),
            _ = woody_server_thrift_handler:invoke_handler(HandlerState),
            Req1;
        {ok, call, HandlerState} ->
            handle_result(woody_server_thrift_handler:invoke_handler(HandlerState), Req, WoodyState);
        {error, Error} ->
            handle_error(Error, Req, WoodyState)
    end.

-spec handle_result({ok, woody:http_body()} | {error, woody_error:error()}, cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
handle_result({ok, Body}, Req, WoodyState) ->
    reply(200, cowboy_req:set_resp_body(Body, Req), WoodyState);
handle_result({error, Error}, Req, WoodyState) ->
    handle_error(Error, Req, WoodyState).

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
        ?NORMAL_HEADER_E_CLASS => Class,
        ?NORMAL_HEADER_E_REASON => Reason,
        ?LEGACY_HEADER_E_CLASS => Class,
        ?LEGACY_HEADER_E_REASON =>Reason
    },
    cowboy_req:set_resp_headers(Headers, Req).

-spec reply(woody:http_code(), cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
reply(200, Req, WoodyState) ->
    Req1 = cowboy_req:set_resp_header(<<"content-type">>, ?CONTENT_TYPE_THRIFT, Req),
    do_reply(200, Req1, WoodyState);
reply(Code, Req, WoodyState) ->
    do_reply(Code, Req, WoodyState).

do_reply(Code, Req, WoodyState) ->
    _ = log_event(?EV_SERVER_SEND, WoodyState, #{code => Code, status => reply_status(Code)}),
    cowboy_req:reply(Code, Req).

reply_status(200) -> ok;
reply_status(Code) when is_integer(Code), Code > 0 -> error.

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
