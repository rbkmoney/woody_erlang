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

%% See cowboy_protocol:opts() for details.
%% ToDo: update/remove, when woody is coupled with nginx.
-type net_opts() :: #{
    max_header_value_length => non_neg_integer(),
    max_headers             => non_neg_integer(),
    max_keepalive           => non_neg_integer(),
    timeout                 => timeout()
}.
-define(COWBOY_ALLOWED_OPTS,
    [max_header_value_length, max_headers, max_keepalive, timeout]
).

-type options() :: #{
    protocol   => thrift,
    transport  => http,
    handlers   => list(woody:http_handler(woody:th_handler())),
    event_handler => woody:ev_handler(),
    ip         => inet:ip_address(),
    port       => inet:port_address(),
    net_ops    => net_opts() %% optional
}.
-export_type([net_opts/0, options/0]).

-type re_mp() :: tuple(). %% fuck otp for hiding the types.
-type server_opts() :: #{
    max_body_length => pos_integer() | infinity,
    regexp_meta     => re_mp()
}.

-type state() :: #{
    th_handler  => woody:th_handler(),
    ev_handler  => woody:ev_handler(),
    server_opts => server_opts(),
    url         => woody:url(),
    context     => woody_context:ctx()
}.

-type cowboy_init_result() ::
    {ok       , cowboy_req:req(), state()} |
    {shutdown , cowboy_req:req(), undefined}.

-define(DEFAULT_ACCEPTORS_POOLSIZE, 100).

%% nginx should be configured to take care of various limits.
-define(MAX_BODY_LENGTH, infinity).


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
    ranch:child_spec({?MODULE, Id}, AcceptorsPool,
        Transport, TransportOpts, cowboy_protocol, CowboyOpts).

get_socket_transport(Ip, Port) ->
    {ranch_tcp, [{ip, Ip}, {port, Port}]}.

-spec get_cowboy_config(options()) -> cowboy_protocol:opts().
get_cowboy_config(Opts = #{handlers := Handlers, event_handler := EvHandler}) ->
    Paths      = get_paths(config(), EvHandler, Handlers, []),
    CowboyOpts = get_cowboy_opts(maps:get(net_opts, Opts, undefined)),
    HttpTrace  = get_http_trace(EvHandler, config()),
    [
        {env, [{dispatch, cowboy_router:compile([{'_', Paths}])}]},
        %% Limit woody_context:meta() key length to 53 bytes
        %% according to woody requirements.
        {max_header_name_length, 64}
    ] ++ CowboyOpts ++ HttpTrace.

-spec get_paths(server_opts(), woody:ev_handler(),
    list(woody:http_handler(woody:th_handler())), list({woody:path(), module(), state()}))
->
    list({woody:path(), module(), state()}).
get_paths(_, _, [], Paths) ->
    Paths;
get_paths(ServerOpts, EvHandler, [{PathMatch, {Service, Handler}} | T], Paths) ->
    get_paths(ServerOpts, EvHandler, T, [
        {PathMatch, ?MODULE, #{
            th_handler  => {Service, Handler},
            ev_handler  => EvHandler,
            server_opts => ServerOpts
        }} | Paths
    ]);
get_paths(_, _, [Handler | _], _) ->
    error({bad_handler_spec, Handler}).

-spec config() -> server_opts().
config() ->
    #{
       max_body_length => ?MAX_BODY_LENGTH,
       regexp_meta => compile_filter_meta()
    }.

-spec compile_filter_meta() -> re_mp().
compile_filter_meta() ->
    {ok, Re} = re:compile([?HEADER_META_PREFIX], [unicode, caseless]),
    Re.

-spec get_cowboy_opts(net_opts() | undefined) -> cowboy_protocol:opts().
get_cowboy_opts(undefined) ->
    [];
get_cowboy_opts(NetOps) ->
    maps:to_list(maps:with(?COWBOY_ALLOWED_OPTS, NetOps)).

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
init({_Transport, http}, Req, Opts = #{ev_handler := EvHandler}) ->
    {Url, Req1} = cowboy_req:url(Req),
    case get_rpc_id(Req1) of
        {ok, RpcId, Req2} ->
            Context = woody_context:new(RpcId, EvHandler),
            check_headers(Req2, Opts#{context => Context, url => Url});
        {error, BadRpcId, Req2} ->
            reply_bad_header(400, <<"bad ", ?HEADER_PREFIX/binary, " id header">>,
                Url, Req2, woody_context:new(BadRpcId, EvHandler))
    end.

-spec handle(cowboy_req:req(), state()) ->
    {ok, cowboy_req:req(), _}.
handle(Req, #{
    url         := Url,
    context     := Context,
    server_opts := ServerOpts,
    th_handler  := ThriftHandler
}) ->
    Req2 = case get_body(Req, ServerOpts) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE,
            #{url => Url, status => ok}, Context),
            handle_request(Body, ThriftHandler, Context, Req1);
        {ok, <<>>, Req1} ->
            reply_client_error(400, <<"body empty">>, Url, Req1, Context);
        {{error, body_too_large}, _, Req1} ->
            reply_client_error(413, <<"body too large">>, Url, Req1, Context);
        {{error, Reason}, _, Req1} ->
            BinReason = genlib:to_binary(Reason),
            reply_client_error(400, <<"body read error: ", BinReason/binary>>,
                Url, Req1, Context)
    end,
    {ok, Req2, undefined}.

-spec terminate(_Reason, _Req, state() | _) ->
    ok.
terminate({normal, _}, _Req, _Status) ->
    ok;
terminate(Reason, _Req, #{context := Context}) ->
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR,
            #{
                role     => server,
                error    => <<"http handler terminated abnormally">>,
                reason   => woody_error:format_details(Reason),
                stack    => erlang:get_stacktrace(),
                severity => error
            },
            Context
        ),
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
check_headers(Req, Opts) ->
    check_method(cowboy_req:method(Req), Opts).

-spec check_method({binary(), cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_method({<<"POST">>, Req}, Opts) ->
    check_content_type(cowboy_req:header(<<"content-type">>, Req), Opts);
check_method({Method, Req}, #{url := Url, context := Context}) ->
    reply_bad_header(405, <<"wrong method: ", Method/binary>>, Url,
        cowboy_req:set_resp_header(<<"allow">>, <<"POST">>, Req), Context).

-spec check_content_type({binary() | undefined, cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_content_type({?CONTENT_TYPE_THRIFT, Req}, Opts) ->
    check_accept(cowboy_req:header(<<"accept">>, Req), Opts);
check_content_type({BadCType, Req}, #{url := Url, context := Context}) ->
    BinBadCType = genlib:to_binary(BadCType),
    reply_bad_header(415, <<"wrong content type: ", BinBadCType/binary>>,
        Url, Req, Context).

-spec check_accept({binary() | undefined, cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_accept({Accept, Req}, Opts) when
    Accept =:= ?CONTENT_TYPE_THRIFT ;
    Accept =:= undefined
->
    check_metadata_headers(cowboy_req:headers(Req), Opts);
check_accept({BadAccept, Req1}, #{url := Url, context := Context}) ->
    BinBadAccept = genlib:to_binary(BadAccept),
    reply_bad_header(406, <<"wrong client accept: ", BinBadAccept/binary>>,
        Url, Req1, Context).

-spec check_metadata_headers({woody:http_headers(), cowboy_req:req()}, state()) ->
    cowboy_init_result().
check_metadata_headers({Headers, Req}, Opts = #{context := Context, server_opts := ServerOpts}) ->
    {ok, Req, Opts#{context => add_context_meta(Context, find_metadata(Headers, ServerOpts))}}.

-spec add_context_meta(woody_context:ctx(), woody_context:meta()) ->
    woody_context:ctx().
add_context_meta(Context, Meta) when map_size(Meta) > 0 ->
    woody_context:add_meta(Context, Meta);
add_context_meta(Context, _) ->
    Context.

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

-spec reply_bad_header(woody:http_code(), binary(), woody:url(),
    cowboy_req:req(), woody_context:ctx())
->
    {shutdown, cowboy_req:req(), undefined}.
reply_bad_header(Code, Reason, Url, Req, Context) when is_integer(Code) ->
    Req1 = reply_client_error(Code, Reason, Url, Req, Context),
    {shutdown, Req1, undefined}.

-spec reply_client_error(woody:http_code(), binary(), woody:url(),
    cowboy_req:req(), woody_context:ctx())
->
    cowboy_req:req().
reply_client_error(Code, Reason, Url, Req, Context) ->
    _ = woody_event_handler:handle_event(?EV_SERVER_RECEIVE,
            #{url => Url, status => error, reason => Reason}, Context),
    reply(Code, set_error_headers(<<"Result Unexpected">>, Reason, Req), Context).

%% handle functions
-spec get_body(cowboy_req:req(), server_opts()) ->
    {ok | {error, atom()}, woody:http_body(), cowboy_req:req()}.
get_body(Req, #{max_body_length := MaxBody}) ->
    case cowboy_req:body(Req, [{length, MaxBody}]) of
        {ok, Body, Req1} when byte_size(Body) < MaxBody ->
            {ok, Body, Req1};
        {Res, Body, Req1} when Res =:= ok orelse Res =:= more->
            {{error, body_too_large}, Body, Req1};
        {error, Reason} ->
            {{error, Reason}, <<>>, Req}
    end.

-spec handle_request(woody:http_body(), woody:th_handler(),
    woody_context:ctx(), cowboy_req:req())
->
    cowboy_req:req().
handle_request(Body, ThriftHander, Context, Req) ->
    case woody_server_thrift_handler:init_handler(Body, ThriftHander, Context) of
        {ok, oneway_void, HandlerState} ->
            Req1 = reply(200, Req, Context),
            _ = woody_server_thrift_handler:invoke_handler(HandlerState),
            Req1;
        {ok, call, HandlerState} ->
            handle_result(woody_server_thrift_handler:invoke_handler(HandlerState), Req, Context);
        {error, Error} ->
            handle_error(Error, Req, Context)
    end.

-spec handle_result({ok, binary()} | {error, woody_error:error()},
    cowboy_req:req(), woody_context:ctx())
->
    cowboy_req:req().
handle_result({ok, Body}, Req, Context) ->
    reply(200, cowboy_req:set_resp_body(Body, Req), Context);
handle_result({error, Error}, Req, Context) ->
    handle_error(Error, Req, Context).

-spec handle_error(woody_error:error() | woody_server_thrift_handler:client_error(),
    cowboy_req:req(), woody_context:ctx())
->
    cowboy_req:req().
handle_error({business, {ExceptName, Except}}, Req, Context) ->
    reply(200, set_error_headers(
        <<"Business Error">>, ExceptName, cowboy_req:set_resp_body(Except, Req)),
        Context
    );
handle_error({client, Error}, Req, Context) ->
    reply(400, set_error_headers(<<"Result Unexpected">>, Error, Req), Context);
handle_error({system, {internal, result_unexpected, Details}}, Req, Context) ->
    reply(500, set_error_headers(<<"Result Unexpected">>, Details, Req), Context);
handle_error({system, {internal, resource_unavailable, Details}}, Req, Context) ->
    reply(503, set_error_headers(<<"Resource Unavailable">>, Details, Req), Context);
handle_error({system, {internal, result_unknown, Details}}, Req, Context) ->
    reply(504, set_error_headers(<<"Result Unknown">>, Details, Req), Context);
handle_error({system, {external, result_unexpected, Details}}, Req, Context) ->
    reply(502, set_error_headers(<<"Result Unexpected">>, Details, Req), Context);
handle_error({system, {external, resource_unavailable, Details}}, Req, Context) ->
    reply(502, set_error_headers(<<"Resource Unavailable">>, Details, Req), Context);
handle_error({system, {external, result_unknown, Details}}, Req, Context) ->
    reply(502, set_error_headers(<<"Result Unknown">>, Details, Req), Context).

-spec set_error_headers(binary(), binary(), cowboy_req:req()) ->
    cowboy_req:req().
set_error_headers(Class, Reason, Req) ->
    lists:foldl(
        fun({H, V}, R) -> cowboy_req:set_resp_header(H, V, R) end,
        Req,
        [{?HEADER_E_CLASS, Class}, {?HEADER_E_REASON, Reason}]
    ).

-spec reply(woody:http_code(), cowboy_req:req(), woody_context:ctx()) ->
    cowboy_req:req().
reply(200, Req, Context) ->
    do_reply(200, cowboy_req:set_resp_header(
        <<"content-type">>, ?CONTENT_TYPE_THRIFT, Req),
        Context
    );
reply(Code, Req, Context) ->
    do_reply(Code, Req, Context).

do_reply(Code, Req, Context) ->
    _ = log_event(?EV_SERVER_SEND, Context, #{code => Code, status => reply_status(Code)}),
    {ok, Req2} = cowboy_req:reply(Code, Req),
    Req2.

reply_status(200) -> ok;
reply_status(_) -> error.

log_event(Event, Context, Meta) ->
    woody_event_handler:handle_event(Event, Meta, Context).
