-module(woody_event_handler).

%% API
-export([handle_event/3, handle_event/4]).
-export([format_event/2, format_event/3]).
-export([format_event_and_meta/3, format_event_and_meta/4]).
-export([format_rpc_id/1]).

-include("woody_defs.hrl").

%%
%% behaviour definition
%%

-type event_client() ::
    ?EV_CALL_SERVICE   |
    ?EV_SERVICE_RESULT |
    ?EV_CLIENT_SEND    |
    ?EV_CLIENT_RECEIVE.

-type event_server() ::
    ?EV_INVOKE_SERVICE_HANDLER |
    ?EV_SERVICE_HANDLER_RESULT |
    ?EV_SERVER_RECEIVE         |
    ?EV_SERVER_SEND.

%% Layer             Client               Server
%% App invocation    EV_CALL_SERVICE      EV_INVOKE_SERVICE_HANDLER
%% App result        EV_SERVICE_RESULT    EV_SERVICE_HANDLER_RESULT
%% Transport req     EV_CLIENT_SEND       EV_SERVER_RECEIVE
%% Transport resp    EV_CLIENT_RECEIVE    EV_SERVER_SEND

-type event() :: event_client() | event_server() | ?EV_INTERNAL_ERROR | ?EV_TRACE.
-export_type([event/0]).

-type meta_client() :: #{
    role     := client,
    service  := woody:service_name(),
    function := woody:func(),
    type     := woody:rpc_type(),
    args     := woody:args(),
    metadata := woody_context:meta(),

    url      => woody:url(),                          %% EV_CLIENT_SEND
    code     => woody:http_code(),                    %% EV_CLIENT_RECEIVE
    reason   => woody_error:details(),                %% EV_CLIENT_RECEIVE
    status   => status(),                             %% EV_CLIENT_RECEIVE | EV_SERVICE_RESULT
    result   => woody:result() | woody_error:error()  %% EV_SERVICE_RESULT
}.
-export_type([meta_client/0]).

-type meta_server() :: #{
    role     := server,
    url      => woody:url(),           %% EV_SERVER_RECEIVE
    status   => status(),              %% EV_SERVER_RECEIVE | EV_SERVER_SEND | EV_SERVICE_HANDLER_RESULT
    reason   => woody_error:details(), %% EV_SERVER_RECEIVE
    code     => woody:http_code(),     %% EV_SERVER_SEND

    service  => woody:service_name(),  %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    function => woody:func(),          %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    type     => woody:rpc_type(),      %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    args     => woody:args(),          %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    metadata => woody_context:meta(),  %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND

    result   => woody:result()               |   %% EV_SERVICE_HANDLER_RESULT
                woody_error:business_error() |
                woody_error:system_error()   |
                _Error,
    ignore       => boolean(),                   %% EV_SERVICE_HANDLER_RESULT
    except_calss => woody_error:erlang_except(), %% EV_SERVICE_HANDLER_RESULT
    class        => business | system,           %% EV_SERVICE_HANDLER_RESULT
    stack        => woody_error:stack()          %% EV_SERVICE_HANDLER_RESULT
}.
-export_meta([meta_server/0]).

-type meta_internal_error() :: #{
    role   := woody:role(),
    error  := any(),
    reason := any(),
    class  := atom(),
    stack  => woody_error:stack() | undefined,

    service  => woody:service_name(),
    function => woody:func(),
    type     => woody:rpc_type(),
    args     => woody:args(),
    metadata => woody_context:meta()
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

-type event_meta() :: meta_client() | meta_server() | meta_internal_error() | meta_trace().
-export_type([event_meta/0]).

-callback handle_event
    (event_client(), woody:rpc_id(), meta_client(), woody:options()) -> _;
    (event_server(), woody:rpc_id(), meta_server(), woody:options()) -> _;

    (?EV_INTERNAL_ERROR, woody:rpc_id(), meta_internal_error(), woody:options()) -> _;
    (?EV_TRACE, woody:rpc_id() | undefined, meta_trace(), woody:options()) -> _.


%% Util Types
-type status() :: ok | error.
-export_type([status/0]).

-type severity() :: debug | info | warning | error.
-type msg     () :: {list(), list()}.
-type log_msg () :: {severity(), msg()}.
-type log_role() :: 'woody.client' | 'woody.server'.
-type meta_key() :: event | role | service | function | type | args | metadata | status | url | code | result.
-export_type([severity/0, msg/0, log_msg/0, log_role/0, meta_key/0]).

-type meta() :: #{atom() => _}.
-export_type([meta/0]).


%%
%% API
%%
-spec handle_event(event(), woody_state:st(), meta()) ->
    ok.
handle_event(Event, WoodyState, ExtraMeta) ->
    handle_event(
        woody_state:get_ev_handler(WoodyState),
        Event,
        woody_context:get_rpc_id(woody_state:get_context(WoodyState)),
        maps:merge(woody_state:get_ev_meta(WoodyState), ExtraMeta)
    ).

-spec handle_event(woody:ev_handler(), event(), woody:rpc_id() | undefined, event_meta()) ->
    ok.
handle_event(Handler, Event, RpcId, Meta) ->
    {Module, Opts} = woody_util:get_mod_opts(Handler),
    _ = Module:handle_event(Event, RpcId, Meta, Opts),
    ok.

-spec format_rpc_id(woody:rpc_id() | undefined) ->
    msg().
format_rpc_id(#{span_id:=Span, trace_id:=Trace, parent_id:=Parent}) ->
    {"[~s ~s ~s]", [Trace, Parent, Span]};
format_rpc_id(undefined) ->
    {"~p", [undefined]}.

-spec format_event(event(), event_meta(), woody:rpc_id() | undefined) ->
    log_msg().
format_event(Event, Meta, RpcId) ->
    {Severity, Msg} = format_event(Event, Meta),
    {Severity, append_msg(format_rpc_id(RpcId), Msg)}.

-spec format_event_and_meta(event(), event_meta(), woody:rpc_id() | undefined) ->
    {severity(), msg(), {log_role() , map()}}.
format_event_and_meta(Event, Meta, RpcID) ->
    format_event_and_meta(Event, Meta, RpcID, [service, function, type]).

-spec format_event_and_meta(event(), event_meta(), woody:rpc_id() | undefined, list(meta_key())) ->
    {severity(), msg(), {log_role() , map()}}.
format_event_and_meta(Event, Meta, RpcID, EssentialMetaKeys) ->
    {Severity, Msg} = format_event(Event, Meta, RpcID),
    RpcRole = get_woody_role(Meta),
    Meta1 = get_essential_meta(Meta, Event, EssentialMetaKeys),
    {Severity, Msg, {RpcRole, Meta1}}.

get_essential_meta(Meta, Event, Keys) ->
    Meta1 = maps:with(Keys, Meta),
    case lists:member(event, Keys) of
        true ->
            Meta1#{event => Event};
        false ->
            Meta1
    end.

get_woody_role(#{role := client}) ->
    'woody.client';
get_woody_role(#{role := server}) ->
    'woody.server'.

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
    {debug, {"[client] received response with code ~p and info details: ~ts", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=ok, code:=Code}) ->
    {debug, {"[client] received response with code ~p", [Code]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, code:=Code, reason:=Reason}) ->
    {warning, {"[client] received response with code ~p and details: ~ts", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, reason:=Reason}) ->
    {warning, {"[client] sending request error ~ts", [Reason]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=ok}) ->
    {debug, {"[server] request to ~s received", [URL]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=error, reason:=Reason}) ->
    {debug, {"[server] request to ~s unpacking error ~ts", [URL, Reason]}};
format_event(?EV_SERVER_SEND, #{status:=ok, code:=Code}) ->
    {debug, {"[server] response sent with code ~p", [Code]}};
format_event(?EV_SERVER_SEND, #{status:=error, code:=Code}) ->
    {warning, {"[server] response sent with code ~p", [Code]}};
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
