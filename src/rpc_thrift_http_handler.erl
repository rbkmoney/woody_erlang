-module(rpc_thrift_http_handler).

-behaviour(rpc_server).
-behaviour(thrift_transport).
-behaviour(cowboy_http_handler).

-dialyzer(no_undefined_callbacks).

-include("rpc_thrift_http_headers.hrl").

%% rpc_server callback
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
    rpc_thrift_handler:thrift_handler()
}.

-type options() :: #{
    handlers => list(server_handler()),
    event_handler => rpc_t:handler(),
    ip => inet:ip_address(),
    port => inet:port_address(),
    net_opts => list()
}.

-define(THRIFT_ERROR_KEY, {?MODULE, thrift_error}).

-define(log_event(EventHandler, Event, ReqId, Status, Meta),
    rpc_event_handler:handle_event(EventHandler, Event, Meta#{
        rpc_role => server,
        req_id => ReqId,
        status => Status
    })
).

-define(event_send_reply, send_reply).
-define(event_rpc_receive, rpc_receive).

%%
%% rpc_server callback
%%
-spec child_spec(_Id, options()) ->
    supervisor:child_spec().
child_spec(Id, #{
    handlers := Handlers,
    event_handler := EventHandler,
    ip := Ip,
    port := Port,
    net_opts := NetOpts
}) ->
    _ = check_callback(handle_event, 2, EventHandler),
    AcceptorsPool = genlib_app:env(thrift_rpc, acceptors_pool,
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
    [check_callback(F, 4, Handler) || F <- [handle_function, handle_error]],
    Handler.

get_socket_transport(Ip, Port, Options) ->
    Opts = [
        {ip, Ip},
        {port, Port}
    ],
    case genlib_opts:get(ssl, Options) of
        SslOpts = [_|_] ->
            {ranch_ssl, Opts ++ SslOpts};
        undefined ->
            {ranch_tcp, Opts}
    end.

get_cowboy_config(Handlers, EventHandler) ->
    ServerOpts = config(),
    Paths = [
        {PathMatch, ?MODULE,
            [ServerOpts, EventHandler, {Service, validate_handler(Handler), Opts}]
        } || {PathMatch, {Service, Handler, Opts}} <- Handlers
    ],
    {ok, _} = application:ensure_all_started(cowboy),
    [{env, [{dispatch, cowboy_router:compile([{'_', Paths}])}]}].

config() ->
    [{max_body_length, ?MAX_BODY_LENGTH}].


%%
%% thrift_transport callbacks
%%
-record(http_req, {
    req :: cowboy_req:req(),
    req_id :: rpc_t:req_id(),
    body = <<>> :: binary(),
    resp_body = <<>> :: binary(),
    event_handler :: rpc_t:handler()
}).
-type state() :: #http_req{}.

make_transport(Req, ReqId, Body, EventHandler) ->
    {ok, Transport} = thrift_transport:new(?MODULE, #http_req{
        req = Req,
        req_id = ReqId,
        body = Body,
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

-spec flush(state()) -> {state(), ok}.
flush(State = #http_req{
    req = Req,
    req_id = ReqId,
    resp_body = Body,
    event_handler = EventHandler
}) ->
    {Code, Req1} = add_x_error_header(Req),
    ?log_event(EventHandler, ?event_send_reply, ReqId, reply_status(Code), #{code => Code}),
    {ok, Req2} = cowboy_req:reply(
        Code,
        [],
        Body,
        Req1
    ),
    {State#http_req{req = Req2, resp_body = <<>>}, ok}.

reply_status(200) -> ok;
reply_status(_) -> error.

-spec close(state()) -> {state(), ok}.
close(_State) ->
    {#http_req{}, ok}.

-spec mark_thrift_error(logic | transport, _Error) -> _.
mark_thrift_error(Type, Error) ->
    erlang:put(?THRIFT_ERROR_KEY, {Type, Error}).

%%
%% cowboy_http_handler callbacks
%%
-spec init({_, http}, cowboy_req:req(), list()) ->
    {ok, cowboy_req:req(), list()} |
    {shutdown, cowboy_req:req(), _}.
init({_Transport, http}, Req, Opts = [EventHandler|_]) ->
    {Url, Req1} = cowboy_req:url(Req),
    case get_rpc_id(Req1) of
        {ok, ReqId, Req2} ->
            check_headers(set_resp_headers(ReqId, Req2),
                EventHandler, ReqId, Url, Opts);
        {error, Req2} ->
            ?log_event(EventHandler, ?event_rpc_receive, undefined, error,
                #{url => Url, reason => no_rpc_id}),
            reply_error_early(403, Req2)
    end.

-spec handle(cowboy_req:req(), list()) ->
    {ok, cowboy_req:req(), _}.
handle(Req, [Url, ReqId, ServerOpts, EventHandler, ThriftHandler]) ->
    case get_body(Req, ServerOpts) of
        {ok, Body, Req1} when byte_size(Body) > 0 ->
            ?log_event(EventHandler, ?event_rpc_receive, ReqId, ok, #{url => Url}),
            do_handle(ReqId, Body, ThriftHandler, EventHandler, Req1);
        {ok, <<>>, Req1} ->
            reply_error(411, ReqId, EventHandler, Req1);
        {error, body_too_large, Req1} ->
            ?log_event(EventHandler, ?event_rpc_receive, ReqId, error,
                #{url => Url, reason => body_too_large}),
            reply_error(413, ReqId, EventHandler, Req1);
        {error, Reason, Req1} ->
            ?log_event(EventHandler, ?event_rpc_receive, ReqId, error,
                #{url => Url, reason => {body_read_error, Reason}}),
            reply_error(400, ReqId, EventHandler, Req1)
    end.

-spec terminate(_Reason, _Req, list() | _) ->
    ok.
terminate({normal, _}, _Req, _Status) ->
    ok;
terminate(Reason, _Req, [_, ReqId, _, EventHandler | _]) ->
    ?log_event(EventHandler, http_handler_terminate, ReqId, error,
        #{reason => Reason}),
    ok.

check_headers(Req, EventHandler, ReqId, Url, Opts) ->
    case check_content_type(check_method(Req)) of
        {ok, Req3} ->
            {ok, Req3, [Url, ReqId | Opts]};
        {error, {wrong_method, Method}, Req3} ->
            ?log_event(EventHandler, ?event_rpc_receive, ReqId, error,
                #{url => Url, reason => {wrong_method, Method}}),
            reply_error_early(405, Req3);
        {error, {wrong_content_type, BadType}, Req3} ->
            ?log_event(EventHandler, ?event_rpc_receive, ReqId, error,
                #{url => Url, reason => {wrong_content_type, BadType}}),
            reply_error_early(403, Req3)
    end.

check_method(Req) ->
    case cowboy_req:method(Req) of
        {<<"POST">>, Req1} ->
            {ok, Req1};
        {Method, Req1} ->
            {error, {wrong_method, Method}, Req1}
    end.

check_content_type({ok, Req}) ->
    case cowboy_req:header(<<"content-type">>, Req) of
        {?CONTENT_TYPE_THRIFT, Req1} ->
            {ok, Req1};
        {BadType, Req1} ->
            {error, {wrong_content_type, BadType}, Req1}
    end;
check_content_type(Error) ->
    Error.

get_rpc_id(Req) ->
    case cowboy_req:header(?HEADER_NAME_RPC_ID, Req) of
        {undefined, Req1} ->
            {error, Req1};
        {ReqId, Req1} ->
            {ok, ReqId, Req1}
    end.

get_body(Req, ServerOpts) ->
    MaxBody = genlib_opts:get(max_body_length, ServerOpts),
    case cowboy_req:body(Req, [{length, MaxBody}]) of
        {ok, Body, Req1} when byte_size(Body) =< ?MAX_BODY_LENGTH ->
            {ok, Body, Req1};
        {Res, _, Req1} when Res =:= ok orelse Res =:= more->
            {error, body_too_large, Req1};
        {error, Reason} ->
            {error, Reason, Req}
    end.

do_handle(ReqId, Body, ThriftHander, EventHandler, Req) ->
    RpcClient = rpc_client:make_child_client(ReqId, EventHandler),
    Transport = make_transport(Req, ReqId, Body, EventHandler),
    case rpc_thrift_handler:start(Transport, ReqId, RpcClient, ThriftHander, EventHandler, ?MODULE) of
        ok ->
            {ok, Req, undefined};
        {error, Reason} ->
            handle_error(Reason, ReqId, EventHandler, Req);
        noreply ->
            {ok, Req, undefined}
    end.

handle_error(badrequest, ReqId, EventHandler, Req) ->
    reply_error(400, ReqId, EventHandler, Req);
handle_error(_Error, ReqId, EventHandler, Req) ->
    reply_error(500, ReqId, EventHandler, Req).

reply_error(Code, ReqId, EventHandler, Req) when is_integer(Code), Code >= 400 ->
    ?log_event(EventHandler, ?event_send_reply, ReqId, error, #{code => Code}),
    {_, Req1} = add_x_error_header(Req),
    {ok, Req2} = cowboy_req:reply(Code, Req1),
    {ok, Req2, undefined}.

reply_error_early(Code, Req) when is_integer(Code) ->
    {ok, Req1} = cowboy_req:reply(Code, Req),
    {shutdown, Req1, undefined}.

set_resp_headers(ReqId, Req) ->
    lists:foldl(fun({H,V}, R) -> cowboy_req:set_resp_header(H, V, R) end, Req,
        [{?HEADER_NAME_RPC_ID, ReqId}, {<<"content-type">>, ?CONTENT_TYPE_THRIFT}]
    ).

add_x_error_header(Req) ->
    case erlang:erase(?THRIFT_ERROR_KEY) of
        undefined ->
            {200, Req};
        {transport, Error} ->
            {500, cowboy_req:set_resp_header(?HEADER_NAME_ERROR_TRANSPORT, genlib:to_binary(Error), Req)};
        {logic, Error} ->
            {200, cowboy_req:set_resp_header(?HEADER_NAME_ERROR_LOGIC, genlib:to_binary(Error), Req)}
    end.
