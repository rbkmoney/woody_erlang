-module(woody_server_thrift_http_handler).

-behaviour(woody_server).
-behaviour(cowboy_http_handler).

-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% woody_server callback
-export([child_spec/2]).

%% cowboy_http_handler callbacks
-export([init/3]).
-export([handle/2]).
-export([terminate/3]).


%% Types
-type handler_limits() :: #{
    max_heap_size       => integer(), %% process words, see erlang:process_flag(max_heap_size, MaxHeapSize) for details.
    total_mem_threshold => integer()  %% bytes, see erlang:memory() for details.
}.
-export_type([handler_limits/0]).

-type options() :: #{
    handlers       := list(woody:http_handler(woody:th_handler())),
    event_handler  := woody:ev_handler(),
    ip             := inet:ip_address(),
    port           := inet:port_number(),
    protocol       => thrift,
    transport      => http,
    net_opts       => cowboy_protocol:opts(),
    handler_limits => handler_limits()
}.

-export_type([options/0]).

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


%%
%% woody_server callback
%%
-spec child_spec(_Id, options()) ->
    supervisor:child_spec().
child_spec(Id, Opts = #{
    ip            := Ip,
    port          := Port
}) ->
    AcceptorsPool = genlib_app:env(woody, acceptors_pool_size,
        ?DEFAULT_ACCEPTORS_POOLSIZE
    ),
    {Transport, TransportOpts} = get_socket_transport(Ip, Port),
    CowboyOpts = get_cowboy_config(Opts),
    ranch:child_spec({?MODULE, Id}, AcceptorsPool, Transport, TransportOpts, cowboy_protocol, CowboyOpts).

get_socket_transport(Ip, Port) ->
    {ranch_tcp, [{ip, Ip}, {port, Port}]}.

-spec get_cowboy_config(options()) ->
    cowboy_protocol:opts().
get_cowboy_config(Opts = #{event_handler := EvHandler}) ->
    ok         = validate_event_handler(EvHandler),
    Dispatch   = get_dispatch(Opts),
    CowboyOpts = get_cowboy_opts(maps:get(net_opts, Opts, undefined)),
    HttpTrace  = get_http_trace(EvHandler, config()),
    [
        {env, [{dispatch, Dispatch}]},
        %% Limit woody_context:meta() key length to 53 bytes
        %% according to woody requirements.
        {max_header_name_length, 64}
    ] ++ CowboyOpts ++ HttpTrace.

validate_event_handler(Handler) ->
    {_, _} = woody_util:get_mod_opts(Handler),
    ok.

-spec get_dispatch(options())->
    cowboy_router:dispatch_rules().
get_dispatch(Opts = #{handlers := Handlers, event_handler := EvHandler}) ->
    Limits = maps:get(handler_limits, Opts, #{}),
    Paths  = get_paths(config(), Limits, EvHandler, Handlers, []),
    cowboy_router:compile([{'_', Paths}]).

-spec get_paths(server_opts(), handler_limits(), woody:ev_handler(), Handlers, Paths) -> Paths when
    Handlers :: list(woody:http_handler(woody:th_handler())),
    Paths    :: list({woody:path(), module(), state()}).
get_paths(_, _, _, [], Paths) ->
    Paths;
get_paths(ServerOpts, Limits, EvHandler, [{PathMatch, {Service, Handler}} | T], Paths) ->
    get_paths(ServerOpts, Limits, EvHandler, T, [
        {PathMatch, ?MODULE, #{
            th_handler     => {Service, Handler},
            ev_handler     => EvHandler,
            server_opts    => ServerOpts,
            handler_limits => Limits
        }} | Paths
    ]);
get_paths(_, _, _, [Handler | _], _) ->
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
    {ok, Re} = re:compile([?HEADER_META_PREFIX], [unicode, caseless]),
    Re.

-spec get_cowboy_opts(cowboy_protocol:opts() | undefined) ->
    cowboy_protocol:opts() | no_return().
get_cowboy_opts(undefined) ->
    [];
get_cowboy_opts(Opts) ->
    case lists:keyfind(env, 1, Opts) of
        false ->
            Opts;
        _ ->
            erlang:error(env_not_allowed_in_net_opts)
    end.

-spec get_http_trace(woody:ev_handler(), server_opts()) ->
    [{onrequest | onresponse, fun((cowboy_req:req()) -> cowboy_req:req())}].
get_http_trace(EvHandler, ServerOpts) ->
    [
        {onrequest, fun(Req) ->
            trace_req(genlib_app:env(woody, trace_http_server), Req, EvHandler, ServerOpts) end},
        {onresponse, fun(Code, Headers, Body, Req) ->
            trace_resp(genlib_app:env(woody, trace_http_server), Req, Code, Headers, Body, EvHandler) end}
    ].

trace_req(true, Req, EvHandler, ServerOpts) ->
    {Url, Req1} = cowboy_req:url(Req),
    {Headers, Req2} = cowboy_req:headers(Req1),
    Meta = #{
         role    => server,
         event   => <<"http request received">>,
         url     => Url,
         headers => Headers
     },
    Meta1 = case get_body(Req2, ServerOpts) of
        {ok, Body, _} ->
             Meta#{body => Body, body_status => ok};
        {{error, Error}, Body, _} ->
             Meta#{body => Body, body_status => Error}
    end,
    _ = woody_event_handler:handle_event(EvHandler, ?EV_TRACE, undefined, Meta1),
    Req2;
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
-spec init({_, http}, cowboy_req:req(), state()) ->
    cowboy_init_result().
init({_Transport, http}, Req, Opts = #{ev_handler := EvHandler, handler_limits := Limits}) ->
    ok = set_handler_limits(Limits),
    {Url, Req1} = cowboy_req:url(Req),
    State = Opts#{url => Url},
    case get_rpc_id(Req1) of
        {ok, RpcId, Req2} ->
            WoodyState = make_woody_state(RpcId, EvHandler),
            init_handler(Req2, State#{woody_state => WoodyState});
        {error, BadRpcId, Req2} ->
            reply_bad_header(400, woody_util:to_binary(["bad ", ?HEADER_PREFIX, " id header"]),
                Req2, State#{woody_state => make_woody_state(BadRpcId, EvHandler)}
            )
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

-spec init_handler(cowboy_req:req(), state()) ->
    cowboy_init_result().
init_handler(Req, State = #{handler_limits := Limits, woody_state := WoodyState}) ->
    case have_resources_to_continue(Limits) of
        true ->
            check_headers(Req, State);
        false ->
            Details = <<"erlang vm exceeded total memory threshold">>,
            Req1 = handle_error({system, {internal, resource_unavailable, Details}}, Req, WoodyState),
            {shutdown, Req1, undefined}
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
terminate({normal, _}, _Req, _Status) ->
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
        {undefined, Req1} ->
            Acc#{Id => <<"undefined">>, req => Req1, status => error};
        {IdVal, Req1} ->
            Acc#{Id => IdVal, req => Req1}
    end.

check_ids(Map = #{status := error, req := Req}) ->
    {error, maps:without([req, status], Map), Req};
check_ids(Map = #{req := Req}) ->
    {ok, maps:without([req], Map), Req}.

-spec check_headers(cowboy_req:req(), state()) ->
    cowboy_init_result().
check_headers(Req, State) ->
    check_deadline_header(cowboy_req:header(?HEADER_DEADLINE, Req), State).

-spec check_deadline_header({woody:http_header_val() | undefined, cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_deadline_header({undefined, Req}, State) ->
    check_method(cowboy_req:method(Req), State);
check_deadline_header({DeadlineBin, Req}, State) ->
    try woody_deadline:from_binary(DeadlineBin) of
        Deadline -> check_deadline(Deadline, Req, State)
    catch
        error:{bad_deadline, Error} ->
            reply_bad_header(400, woody_util:to_binary(["bad ", ?HEADER_DEADLINE, " header: ", Error]), Req, State)
    end.

-spec check_deadline(woody:deadline(), cowboy_req:req(), state()) ->
    cowboy_init_result().
check_deadline(Deadline, Req, State = #{url := Url, woody_state := WoodyState}) ->
    case woody_deadline:reached(Deadline) of
        true ->
            woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState,
                                             #{url => Url, status => error, reason => <<"Deadline reached">>}),
            Req1 = handle_error({system, {internal, resource_unavailable, <<"deadline reached">>}}, Req, WoodyState),
            {shutdown, Req1, undefined};
        false ->
            check_method(cowboy_req:method(Req), State#{woody_state => set_deadline(Deadline, WoodyState)})
    end.

-spec set_deadline(woody:deadline(), woody_state:st()) ->
    woody_state:st().
set_deadline(Deadline, WoodyState) ->
    woody_state:add_context_deadline(Deadline, WoodyState).

-spec check_method({woody:http_header_val(), cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_method({<<"POST">>, Req}, State) ->
    check_content_type(cowboy_req:header(<<"content-type">>, Req), State);
check_method({Method, Req}, State) ->
    reply_bad_header(405, woody_util:to_binary(["wrong method: ", Method]),
        cowboy_req:set_resp_header(<<"allow">>, <<"POST">>, Req), State
    ).

-spec check_content_type({woody:http_header_val() | undefined, cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_content_type({?CONTENT_TYPE_THRIFT, Req}, State) ->
    check_accept(cowboy_req:header(<<"accept">>, Req), State);
check_content_type({BadCType, Req}, State) ->
    reply_bad_header(415, woody_util:to_binary(["wrong content type: ", BadCType]), Req, State).

-spec check_accept({woody:http_header_val() | undefined, cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_accept({Accept, Req}, State) when
    Accept =:= ?CONTENT_TYPE_THRIFT ;
    Accept =:= undefined
->
    check_metadata_headers(cowboy_req:headers(Req), State);
check_accept({BadAccept, Req1}, State) ->
    reply_bad_header(406, woody_util:to_binary(["wrong client accept: ", BadAccept]), Req1, State).

-spec check_metadata_headers({woody:http_headers(), cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_metadata_headers({Headers, Req}, State = #{woody_state := WoodyState, server_opts := ServerOpts}) ->
    {ok, Req, State#{woody_state => set_metadata(find_metadata(Headers, ServerOpts), WoodyState)}}.

-spec set_metadata(woody_context:meta(), woody_state:st()) ->
    woody_state:st().
set_metadata(Meta, WoodyState) ->
    woody_state:add_context_meta(Meta, WoodyState).

-spec find_metadata(woody:http_headers(), server_opts()) ->
    woody_context:meta().
find_metadata(Headers, #{regexp_meta := Re}) ->
    lists:foldl(
        fun({H, V}, Acc) when
            H =/= ?HEADER_RPC_ID andalso
            H =/= ?HEADER_RPC_ROOT_ID andalso
            H =/= ?HEADER_RPC_PARENT_ID
        ->
            case re:replace(H, Re, "", [{return, binary}, anchored]) of
                H -> Acc;
                MetaHeader -> Acc#{MetaHeader => V}
            end;
           (_, Acc) -> Acc
        end,
      #{}, Headers).

-spec make_woody_state(woody:rpc_id(), woody:ev_handler()) ->
    woody_state:st().
make_woody_state(RpcId, EvHandler) ->
    woody_state:new(server, woody_context:new(RpcId), EvHandler).

-spec reply_bad_header(woody:http_code(), woody:http_header_val(), cowboy_req:req(), state()) ->
    {shutdown, cowboy_req:req(), undefined}.
reply_bad_header(Code, Reason, Req, State) when is_integer(Code) ->
    Req1 = reply_client_error(Code, Reason, Req, State),
    {shutdown, Req1, undefined}.

-spec reply_client_error(woody:http_code(), woody:http_header_val(), cowboy_req:req(), state()) ->
    cowboy_req:req().
reply_client_error(Code, Reason, Req, #{url := Url, woody_state := WoodyState}) ->
    _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE, WoodyState,
            #{url => Url, status => error, reason => Reason}),
    reply(Code, set_error_headers(<<"Result Unexpected">>, Reason, Req), WoodyState).

%% handle functions
-spec get_body(cowboy_req:req(), server_opts()) ->
    {ok | {error, atom()}, woody:http_body(), cowboy_req:req()}.
get_body(Req, #{max_chunk_length := MaxChunk}) ->
    do_get_body(<<>>, Req, [{length, MaxChunk}]).

do_get_body(Body, Req, Opts) ->
    case cowboy_req:body(Req, Opts) of
        {ok, Body1, Req1} ->
            {ok, <<Body/binary, Body1/binary>>, Req1};
        {more, Body1, Req1} ->
            do_get_body(<<Body/binary, Body1/binary>>, Req1, Opts);
        {error, Reason} ->
            {{error, Reason}, <<>>, Req}
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
    lists:foldl(
        fun({H, V}, R) -> cowboy_req:set_resp_header(H, V, R) end,
        Req,
        [{?HEADER_E_CLASS, Class}, {?HEADER_E_REASON, Reason}]
    ).

-spec reply(woody:http_code(), cowboy_req:req(), woody_state:st()) ->
    cowboy_req:req().
reply(200, Req, WoodyState) ->
    do_reply(200, cowboy_req:set_resp_header(<<"content-type">>, ?CONTENT_TYPE_THRIFT, Req), WoodyState);
reply(Code, Req, WoodyState) ->
    do_reply(Code, Req, WoodyState).

do_reply(Code, Req, WoodyState) ->
    _ = log_event(?EV_SERVER_SEND, WoodyState, #{code => Code, status => reply_status(Code)}),
    {ok, Req2} = cowboy_req:reply(Code, Req),
    Req2.

reply_status(200) -> ok;
reply_status(_) -> error.

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
