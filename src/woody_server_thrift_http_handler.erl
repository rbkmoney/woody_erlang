-module(woody_server_thrift_http_handler).

-behaviour(woody_server).
-behaviour(thrift_transport).
-behaviour(cowboy_http_handler).

-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% woody_server callback
-export([child_spec/2]).

%% thrift_transport callbacks
-export([write/2, read/2, flush/1, close/1]).

%% hack for providing thrift error in http header
-export([mark_thrift_error/2]).

%% cowboy_http_handler callbacks
-export([init/3]).
-export([handle/2]).
-export([terminate/3]).

-define(DEFAULT_ACCEPTORS_POOLSIZE, 100).

%% nginx should be configured to take care of various limits
-define(MAX_BODY_LENGTH, infinity).

-type server_handler() :: {
    '_' | iodata(), %% cowboy_router:route_match()
    woody_server_thrift_handler:thrift_handler()
}.

-export_type([server_handler/0]).

-type ssl_opts() :: list(ranch_ssl:ssl_opt()).

-type options() :: #{
    handlers      => list(server_handler()),
    event_handler => woody_t:handler(),
    ip            => inet:ip_address(),
    port          => inet:port_address(),
    net_opts      => list({ssl, ssl_opts()})
}.

-define(THRIFT_ERROR_KEY, {?MODULE, thrift_error}).

-define(log_event(EventHandler, Event, Status, RpcId, Meta),
    woody_event_handler:handle_event(EventHandler, Event, RpcId, Meta#{
        status => Status
    })
).

-define(HEADERS_RPC_ID, #{
    span_id   => ?HEADER_NAME_RPC_ID,
    trace_id  => ?HEADER_NAME_RPC_ROOT_ID,
    parent_id => ?HEADER_NAME_RPC_PARENT_ID
}).


%%
%% woody_server callback
%%
-spec child_spec(_Id, options()) ->
    supervisor:child_spec().
child_spec(Id, #{
    handlers      := Handlers,
    event_handler := EventHandler,
    ip            := Ip,
    port          := Port,
    net_opts := NetOpts
}) ->
    _ = check_callback(handle_event, 3, EventHandler),
    AcceptorsPool = genlib_app:env(woody, acceptors_pool_size,
        ?DEFAULT_ACCEPTORS_POOLSIZE
    ),
    {Transport, TransportOpts} = get_socket_transport(Ip, Port, NetOpts),
    CowboyOpts = get_cowboy_config(Handlers, EventHandler),
    ranch:child_spec({?MODULE, Id}, AcceptorsPool,
        Transport, TransportOpts, cowboy_protocol, CowboyOpts).

check_callback(Callback, Arity, Module) when is_integer(Arity), Arity >= 0 ->
    Arity = check_callback(Callback, Module).

check_callback(Callback, Module) ->
    proplists:get_value(Callback, Module:module_info(exports)).

validate_handler(Handler) when is_atom(Handler) ->
    [check_callback(F, 4, Handler) || F <- [handle_function]],
    Handler.

get_socket_transport(Ip, Port, Options) ->
    Opts = [
        {ip,   Ip},
        {port, Port}
    ],
    case genlib_opts:get(ssl, Options) of
        SslOpts = [_|_] ->
            {ranch_ssl, Opts ++ SslOpts};
        undefined ->
            {ranch_tcp, Opts}
    end.

get_cowboy_config(Handlers, EventHandler) ->
    Paths = get_paths(config(), EventHandler, Handlers, []),
    Debug = enable_debug(genlib_app:env(woody, enable_debug), EventHandler),
    [{env, [{dispatch, cowboy_router:compile([{'_', Paths}])}]}] ++ Debug.

get_paths(_, _, [], Paths) ->
    Paths;
get_paths(ServerOpts, EventHandler, [{PathMatch, {Service, Handler, Opts}} | T], Paths) ->
    get_paths(ServerOpts, EventHandler, T, [{PathMatch, ?MODULE,
        [EventHandler, ServerOpts, {Service, validate_handler(Handler), Opts}]
    } | Paths]);
get_paths(_, _, [Handler | _], _) ->
    error({bad_handler_spec, Handler}).

config() ->
    [{max_body_length, ?MAX_BODY_LENGTH}].

enable_debug(true, EventHandler) ->
    [
        {onrequest, fun(Req) ->
                {Url, Req1} = cowboy_req:url(Req),
                {Headers, Req2} = cowboy_req:headers(Req1),
            woody_event_handler:handle_event(EventHandler, ?EV_DEBUG, undefined, #{
                event => transport_onrequest,
                url => Url,
                headers => Headers
            }),
            Req2 end
        },
        {onresponse, fun(Code, Headers, _Body, Req) ->
            woody_event_handler:handle_event(EventHandler, ?EV_DEBUG, undefined, #{
                event => transport_onresponse,
                code => Code,
                headers => Headers
                }),
            Req end
        }
    ];
enable_debug(_, _) ->
    [].


%%
%% thrift_transport callbacks
%%
-record(http_req, {
    req              :: cowboy_req:req(),
    rpc_id           :: woody_t:rpc_id(),
    body = <<>>      :: binary(),
    resp_body = <<>> :: binary(),
    event_handler    :: woody_t:handler(),
    replied = false  :: boolean()
}).
-type state() :: #http_req{}.

make_transport(Req, RpcId, Body, EventHandler) ->
    {ok, Transport} = thrift_transport:new(?MODULE, #http_req{
        req           = Req,
        rpc_id        = RpcId,
        body          = Body,
        event_handler = EventHandler
    }),
    Transport.

-spec read(state(), pos_integer()) -> {state(), {ok, binary()}}.
read(State = #http_req{body = Body}, Len) when is_integer(Len) ->
    Give = min(byte_size(Body), Len),
    {Result, Remaining} = split_binary(Body, Give),
    {State#http_req{body = Remaining}, {ok, Result}}.

-spec write(state(), binary()) -> {state(), ok}.
write(State = #http_req{resp_body = Resp}, Data) ->
    {State#http_req{resp_body = <<Resp/binary, Data/binary>>}, ok}.

-spec flush(state()) -> {state(), ok} | {error, already_replied}.
flush(State = #http_req{replied = true}) ->
    {State, {error, already_replied}};
flush(State = #http_req{
    req           = Req,
    rpc_id        = RpcId,
    resp_body     = Body,
    event_handler = EventHandler
}) ->
    {Code, Req1} = add_x_error_header(Req),
    ?log_event(EventHandler, ?EV_SERVER_SEND, reply_status(Code),
        RpcId, #{code => Code}),
    {ok, Req2} = cowboy_req:reply(Code, [{<<"content-type">>, ?CONTENT_TYPE_THRIFT}],
        Body, Req1),
    {State#http_req{req = Req2, resp_body = <<>>, replied = true}, ok}.

reply_status(200) -> ok;
reply_status(_) -> error.

-spec close(state()) -> {state(), cowboy_req:req()}.
close(#http_req{req = Req}) ->
    {#http_req{}, Req}.

-spec mark_thrift_error(logic | transport, _Error) -> _.
mark_thrift_error(Type, Error) ->
    erlang:put(?THRIFT_ERROR_KEY, {Type, Error}).


%%
%% cowboy_http_handler callbacks
%%
-spec init({_, http}, cowboy_req:req(), list()) ->
    {ok       , cowboy_req:req(), list()} |
    {shutdown , cowboy_req:req(), _}.
init({_Transport, http}, Req, Opts = [EventHandler | _]) ->
    {Url, Req1} = cowboy_req:url(Req),
    case get_rpc_id(Req1) of
        {ok, RpcId, Req2} ->
            check_headers(set_resp_headers(RpcId, Req2), [Url, RpcId | Opts]);
        {error, ErrorMeta, Req2} ->
            ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
                ErrorMeta, #{url => Url, reason => bad_rpc_id}),
            reply_error_early(400, Req2)
    end.

-spec handle(cowboy_req:req(), list()) ->
    {ok, cowboy_req:req(), _}.
handle(Req, [Url, RpcId, EventHandler, ServerOpts, ThriftHandler]) ->
    case get_body(Req, ServerOpts) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            ?log_event(EventHandler, ?EV_SERVER_RECEIVE, ok, RpcId, #{url => Url}),
            do_handle(RpcId, Body, ThriftHandler, EventHandler, Req1);
        {ok, <<>>, Req1} ->
            ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
                RpcId, #{url => Url, reason => body_empty}),
            reply_error(400, Req1);
        {error, body_too_large, Req1} ->
            ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
                RpcId, #{url => Url, reason => body_too_large}),
            reply_error(413, Req1);
        {error, Reason, Req1} ->
            ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
                RpcId, #{url => Url, reason => {body_read_error, Reason}}),
            reply_error(400, Req1)
    end.

-spec terminate(_Reason, _Req, list() | _) ->
    ok.
terminate({normal, _}, _Req, _Status) ->
    ok;
terminate(Reason, _Req, [_, RpcId, EventHandler | _]) ->
    erlang:erase(?THRIFT_ERROR_KEY),
    woody_event_handler:handle_event(EventHandler, ?EV_INTERNAL_ERROR, RpcId, #{
        error => <<"http handler terminated abnormally">>, reason => Reason
    }),
    ok.

get_rpc_id(Req) ->
    check_ids(maps:fold(
        fun(K, V, A) -> get_rpc_id(K, V, A) end,
        #{req => Req}, ?HEADERS_RPC_ID
    )).

get_rpc_id(Key, Header, Acc = #{req := Req}) ->
    case cowboy_req:header(Header, Req) of
        {undefined, Req1} ->
            Acc#{Key => undefined, req => Req1, status => error};
        {Id, Req1} ->
            Acc#{Key => Id, req => Req1}
    end.

check_ids(Map = #{status := error, req := Req}) ->
    {error, maps:without([req, status], Map), Req};
check_ids(Map = #{req := Req}) ->
    {ok, maps:without([req], Map), Req}.

check_headers(Req, Opts) ->
    check_method(cowboy_req:method(Req), Opts).

check_method({<<"POST">>, Req}, Opts) ->
    check_content_type(cowboy_req:header(<<"content-type">>, Req), Opts);
check_method({Method, Req}, [Url, RpcId, EventHandler | _]) ->
    ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
        RpcId, #{url => Url, reason => {wrong_method, Method}}),
    reply_error_early(405, cowboy_req:set_resp_header(<<"allow">>, <<"POST">>, Req)).

check_content_type({?CONTENT_TYPE_THRIFT, Req}, Opts) ->
    check_accept(cowboy_req:header(<<"accept">>, Req), Opts);
check_content_type({BadType, Req}, [Url, RpcId, EventHandler | _]) ->
    ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
        RpcId, #{url => Url, reason => {wrong_content_type, BadType}}),
    reply_error_early(415, Req).

check_accept({Accept, Req}, Opts) when
    Accept =:= ?CONTENT_TYPE_THRIFT ;
    Accept =:= undefined
->
    {ok, Req, Opts};
check_accept({BadType, Req1}, [Url, RpcId, EventHandler | _]) ->
    ?log_event(EventHandler, ?EV_SERVER_RECEIVE, error,
        RpcId, #{url => Url, reason => {wrong_client_accept, BadType}}),
    reply_error_early(406, Req1).

get_body(Req, ServerOpts) ->
    MaxBody = genlib_opts:get(max_body_length, ServerOpts),
    case cowboy_req:body(Req, [{length, MaxBody}]) of
        {ok, Body, Req1} when byte_size(Body) < MaxBody ->
            {ok, Body, Req1};
        {Res, _, Req1} when Res =:= ok orelse Res =:= more->
            {error, body_too_large, Req1};
        {error, Reason} ->
            {error, Reason, Req}
    end.

do_handle(RpcId, Body, ThriftHander, EventHandler, Req) ->
    Context = woody_client:make_child_context(RpcId, EventHandler),
    Transport   = make_transport(Req, RpcId, Body, EventHandler),
    case woody_server_thrift_handler:start(Transport, Context, ThriftHander,
        EventHandler, ?MODULE)
    of
        {ok, Req1} ->
            {ok, Req1, undefined};
        {{error, Reason}, Req1} ->
            handle_error(Reason, RpcId, EventHandler, Req1);
        {noreply, Req1} ->
            {ok, Req1, undefined}
    end.

handle_error(bad_request, RpcId, EventHandler, Req) ->
    reply_error(400, RpcId, EventHandler, Req);
handle_error(_Error, RpcId, EventHandler, Req) ->
    reply_error(500, RpcId, EventHandler, Req).

reply_error(Code, RpcId, EventHandler, Req) ->
    ?log_event(EventHandler, ?EV_SERVER_SEND, error, RpcId, #{code => Code}),
    {_,  Req1} = add_x_error_header(Req),
    reply_error(Code, Req1).

reply_error(Code, Req) when is_integer(Code), Code >= 400 ->
    {ok, Req1} = cowboy_req:reply(Code, Req),
    {ok, Req1, undefined}.

reply_error_early(Code, Req) when is_integer(Code) ->
    {ok, Req1} = cowboy_req:reply(Code, Req),
    {shutdown, Req1, undefined}.

set_resp_headers(RpcId, Req) ->
    maps:fold(
        fun(K, H, R) ->
            cowboy_req:set_resp_header(H, genlib_map:get(K, RpcId), R)
        end, Req, ?HEADERS_RPC_ID
    ).

add_x_error_header(Req) ->
    case erlang:erase(?THRIFT_ERROR_KEY) of
        undefined ->
            {200, Req};
        {logic, Error} ->
            {200, cowboy_req:set_resp_header(
                ?HEADER_NAME_ERROR_LOGIC, genlib:to_binary(Error), Req
            )};
        {transport, Error} ->
            {500, cowboy_req:set_resp_header(
                ?HEADER_NAME_ERROR_TRANSPORT, genlib:to_binary(Error), Req
            )}
    end.

