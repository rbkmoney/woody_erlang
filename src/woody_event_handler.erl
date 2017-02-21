-module(woody_event_handler).

%% API
-export([handle_event/3, handle_event/4]).
-export([format_event/2, format_event/3, format_rpc_id/1]).
-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-type event() ::
    ?EV_CALL_SERVICE   | ?EV_INVOKE_SERVICE_HANDLER |
    ?EV_SERVICE_RESULT | ?EV_SERVICE_HANDLER_RESULT |
    ?EV_CLIENT_SEND    | ?EV_SERVER_RECEIVE         |
    ?EV_CLIENT_RECEIVE | ?EV_SERVER_SEND            |

    ?EV_INTERNAL_ERROR | ?EV_TRACE.

-type event_meta() ::
    meta_call_service()   | meta_invoke_service_handler() |
    meta_service_result() | meta_service_handler_result() |
    meta_client_send()    | meta_server_receive()         |
    meta_client_receive() | meta_server_send()            |
    meta_internal_error() | meta_trace().

-export_type([event/0, event_meta/0]).

-callback handle_event
    (?EV_CALL_SERVICE           , woody:rpc_id(), meta_call_service   (), woody:options()) -> _;
    (?EV_SERVICE_RESULT         , woody:rpc_id(), meta_service_result (), woody:options()) -> _;
    (?EV_CLIENT_SEND            , woody:rpc_id(), meta_client_send    (), woody:options()) -> _;
    (?EV_CLIENT_RECEIVE         , woody:rpc_id(), meta_client_receive (), woody:options()) -> _;
    (?EV_SERVER_RECEIVE         , woody:rpc_id(), meta_server_receive (), woody:options()) -> _;
    (?EV_SERVER_SEND            , woody:rpc_id(), meta_server_send    (), woody:options()) -> _;
    (?EV_INTERNAL_ERROR         , woody:rpc_id(), meta_internal_error (), woody:options()) -> _;
    (?EV_TRACE                  , woody:rpc_id()|undefined, meta_trace(), woody:options()) -> _;
    (?EV_INVOKE_SERVICE_HANDLER , woody:rpc_id(), meta_invoke_service_handler (), woody:options()) -> _;
    (?EV_SERVICE_HANDLER_RESULT , woody:rpc_id(), meta_service_handler_result (), woody:options()) -> _.


%% Types

%% client events
-type meta_call_service() :: #{
    service  := woody:service_name(),
    function := woody:func(),
    type     := woody:rpc_type(),
    args     => woody:args(),
    metadata => woody_context:meta()
}.
-type meta_service_result() :: #{
    status := status(),
    result => woody:result() | woody_error:error()
}.
-type meta_client_send() :: #{
    url := woody:url()
}.
-type meta_client_receive() :: #{
    status := status(),
    code   => woody:http_code(),
    reason => woody_error:details()
}.
-export_type([meta_call_service/0, meta_service_result/0, meta_client_send/0, meta_client_receive/0]).

%% server events
-type meta_server_receive() :: #{
    url    := woody:url(),
    status := status(),
    reason => woody_error:details()
}.
-type meta_server_send() :: #{
    status := status(),
    code   := woody:http_code()
}.
-type meta_invoke_service_handler() :: #{
    service  := woody:service_name(),
    function := woody:func(),
    args     => woody:args(),
    metadata => woody_context:meta()
}.
-type meta_service_handler_result() :: #{
    status       := status(),
    result       := woody:result() | woody_error:business_error() | woody_error:system_error() | _Error,
    ignore       := boolean(),
    except_calss := woody_error:erlang_except(),
    class        := business | system,
    stack        := woody_error:stack()
}.
-export_meta([meta_server_receive/0, meta_server_send/0, meta_invoke_service_handler/0, meta_service_handler_result/0]).

%% internal events
-type meta_internal_error() :: #{
    role   := woody:role(),
    error  := any(),
    reason := any(),
    class  := atom(),
    stack  => woody_error:stack() | undefined
}.
-type meta_trace() :: #{
    event       := binary(),
    role        := woody:role(),
    url         => woody:url(),
    code        => woody:http_code(),
    headers     => woody:http_headers(),
    body        => woody:http_body(),
    body_status => atom()
}.
-export_type([meta_internal_error/0, meta_trace/0]).

-type status()       :: ok | error.
-export_type([status/0]).

-type severity() :: debug | info | warning | error.
-type msg     () :: {list(), list()  }.
-type log_msg () :: {severity(), msg()}.
-export_type([severity/0, msg/0, log_msg/0]).


%%
%% API
%%
-spec handle_event(event(), event_meta(), woody_context:ctx()) -> ok.
handle_event(Event, Meta, Context = #{ev_handler := Handler}) ->
    handle_event(Handler, Event, woody_context:get_rpc_id(Context), add_request_meta(Event, Meta, Context)).

-spec handle_event(woody:ev_handler(), event(), woody:rpc_id() | undefined, event_meta()) ->
    ok.
handle_event(Handler, Event, RpcId, Meta) ->
    {Module, Opts} = woody_util:get_mod_opts(Handler),
    _ = Module:handle_event(Event, RpcId, Meta, Opts),
    ok.

-spec format_rpc_id(woody:rpc_id()) ->
    msg().
format_rpc_id(#{span_id:=Span, trace_id:=Trace, parent_id:=Parent}) ->
    {"[~s ~s ~s]", [Trace, Parent, Span]}.

-spec format_event(event(), event_meta(), woody:rpc_id()) ->
    log_msg().
format_event(Event, Meta, RpcId) ->
    {Severity, Msg} = format_event(Event, Meta),
    {Severity, append_msg(format_rpc_id(RpcId), Msg)}.

-spec format_event(event(), event_meta()) ->
    log_msg().
format_event(?EV_CALL_SERVICE, Meta) ->
    {info, append_msg({"[client] calling ", []}, format_service_request(Meta))};
format_event(?EV_SERVICE_RESULT, #{status:=error, result:=Error, stack:= Stack}) ->
    {error, format_exception({"[client] error while handling request: ~p", [Error]}, Stack)};
format_event(?EV_SERVICE_RESULT, #{status:=error, result:=Result}) ->
    {warning, {"[client] error while handling request ~p", [Result]}};
format_event(?EV_SERVICE_RESULT, #{status:=ok, result:=Result}) ->
    {info, {"[client] request handled successfully ~p", [Result]}};
format_event(?EV_CLIENT_SEND, #{url:=URL}) ->
    {debug, {"[client] sending request to ~s", [URL]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=ok, code:=Code, reason:=Reason}) ->
    {debug, {"[client] received response with code ~p and info details: ~p", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=ok, code:=Code}) ->
    {debug, {"[client] received response with code ~p", [Code]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, code:=Code, reason:=Reason}) ->
    {warning, {"[client] received response with code ~p and details: ~p", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, reason:=Reason}) ->
    {warning, {"[client] sending request error ~p", [Reason]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=ok}) ->
    {debug, {"[server] request to ~s received", [URL]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=error, reason:=Reason}) ->
    {debug, {"[server] request to ~s unpacking error ~p", [URL, Reason]}};
format_event(?EV_SERVER_SEND, #{status:=ok, code:=Code}) ->
    {debug, {"[server] response send with code ~p", [Code]}};
format_event(?EV_SERVER_SEND, #{status:=error, code:=Code}) ->
    {warning, {"[server] response send with code ~p", [Code]}};
format_event(?EV_INVOKE_SERVICE_HANDLER, Meta) ->
    {info, append_msg({"[server] handling ", []}, format_service_request(Meta))};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=ok, result:=Result}) ->
    {info, {"[server] handling result: ~p", [Result]}};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=business, result:=Error}) ->
    {info, {"[server] handling result business error: ~p", [Error]}};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=system, result:=Error, stack:=Stack,
    except_class:=Class})
->
    {error, format_exception({"[server] handling system internal error: ~s:~p", [Class, Error]}, Stack)};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=system, result:=Error}) ->
    {warning, {"[server] handling system woody error: ~p", [Error]}};
format_event(?EV_INTERNAL_ERROR, #{role:=Role, error:=Error, class := Class, reason:=Reason, stack:=Stack}) ->
    {error, format_exception({"[~p] internal error ~ts ~s:~ts", [Role, Error, Class, Reason]}, Stack)};
format_event(?EV_INTERNAL_ERROR, #{role:=Role, error:=Error, reason:=Reason}) ->
    {warning, {"[~p] internal error ~p, ~ts", [Role, Error, Reason]}};
format_event(?EV_TRACE, Meta = #{event:=Event, role:=Role, headers:=Headers, body:=Body}) ->
    {debug, {"[~p] trace ~s, with ~p~nheaders:~n~p~nbody:~n~ts", [Role, Event, get_url_or_code(Meta), Headers, Body]}};
format_event(?EV_TRACE, #{event:=Event, role:=Role}) ->
    {debug, {"[~p] trace ~ts", [Role, Event]}};
format_event(UnknownEventType, Meta) ->
    {warning, {"unknown woody event type '~s' with meta ~p", [UnknownEventType, Meta]}}.

%%
%% Internal functions
%%
-spec add_request_meta(event(), event_meta(), woody_context:ctx()) ->
    event_meta().
add_request_meta(Event, Meta, Context) when
    Event =:= ?EV_CALL_SERVICE orelse
    Event =:= ?EV_INVOKE_SERVICE_HANDLER
->
    case woody_context:get_meta(Context) of
        ReqMeta when map_size(ReqMeta) =:= 0 ->
            Meta#{metadata => undefined};
        ReqMeta ->
            Meta#{metadata => ReqMeta}
    end;
add_request_meta(_Event, Meta, _Context) ->
    Meta.

-spec format_service_request(map()) ->
    msg().
format_service_request(#{service:=Service, function:=Function, args:=Args}) ->
    {ArgsFormat, ArgsArgs} = format_args(Args),
    {"~s:~s(" ++ ArgsFormat ++ ")", [Service, Function] ++ ArgsArgs}.

-spec format_exception(msg(), woody_error:stack()) ->
    msg().
format_exception(BaseMsg, Stack) ->
    append_msg(BaseMsg, {"~n~s", [genlib_format:format_stacktrace(Stack, [newlines])]}).

-spec format_args(list()) ->
    msg().
format_args([]) ->
    {"", []};
format_args([FirstArg | Args]) ->
    lists:foldl(
        fun(Arg, AccMsg) ->
            append_msg(append_msg(AccMsg, {",", []}), format_arg(Arg))
        end,
        format_arg(FirstArg),
        Args
    ).

-spec format_arg(term()) ->
    msg().
format_arg(Arg) ->
    {"~p", [Arg]}.

-spec append_msg(msg(), msg()) ->
    msg().
append_msg({F1, A1}, {F2, A2}) ->
    {F1 ++ F2, A1 ++ A2}.

get_url_or_code(#{url := Url}) ->
    Url;
get_url_or_code(#{code := Code}) ->
    Code.
