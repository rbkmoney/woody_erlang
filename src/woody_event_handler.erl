-module(woody_event_handler).

%% API
-export([handle_event/3, handle_event/4]).

-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-export_type([event/0, event_meta/0, meta_client_send/0, meta_client_receive/0,
    meta_server_receive/0, meta_server_send/0, meta_call_service/0,
    meta_service_result/0, meta_invoke_service_handler/0,
    meta_service_handler_result/0, meta_thrift_error/0, meta_internal_error/0,
    meta_trace/0
]).

-callback handle_event
    (?EV_CALL_SERVICE           , woody:rpc_id(), meta_call_service   (), woody:options()) -> _;
    (?EV_SERVICE_RESULT         , woody:rpc_id(), meta_service_result (), woody:options()) -> _;
    (?EV_CLIENT_SEND            , woody:rpc_id(), meta_client_send    (), woody:options()) -> _;
    (?EV_CLIENT_RECEIVE         , woody:rpc_id(), meta_client_receive (), woody:options()) -> _;
    (?EV_SERVER_RECEIVE         , woody:rpc_id(), meta_server_receive (), woody:options()) -> _;
    (?EV_SERVER_SEND            , woody:rpc_id(), meta_server_send    (), woody:options()) -> _;
    (?EV_INVOKE_SERVICE_HANDLER , woody:rpc_id(), meta_invoke_service_handler (), woody:options()) -> _;
    (?EV_SERVICE_HANDLER_RESULT , woody:rpc_id(), meta_service_handler_result (), woody:options()) -> _;
    (?EV_THRIFT_ERROR           , woody:rpc_id(), meta_thrift_error   (), woody:options()) -> _;
    (?EV_INTERNAL_ERROR         , woody:rpc_id(), meta_internal_error (), woody:options()) -> _;
    (?EV_TRACE                  , woody:rpc_id()|undefined, meta_trace(), woody:options()) -> _.

-type event() :: ?EV_CALL_SERVICE | ?EV_SERVICE_RESULT | ?EV_CLIENT_SEND | ?EV_CLIENT_RECEIVE |
    ?EV_SERVER_RECEIVE | ?EV_SERVER_SEND | ?EV_INVOKE_SERVICE_HANDLER  | ?EV_SERVICE_HANDLER_RESULT |
    ?EV_THRIFT_ERROR | ?EV_INTERNAL_ERROR | ?EV_TRACE.

-type event_meta() :: meta_client_send() | meta_client_receive() | meta_call_service() |
    meta_service_result() | meta_server_receive() | meta_server_send() |
    meta_invoke_service_handler() | meta_service_handler_result() | meta_thrift_error() |
    meta_internal_error() | meta_trace().

-type service()      :: woody:service_name().
-type status()       :: ok | error.
-type thrift_stage() :: protocol_read | protocol_write | undefined.


-type meta_call_service() :: #{
    service   => service(),
    function  => woody:func(),
    type      => woody:rpc_type(),
    args      => woody_client_thrift:args(),
    metadata  => woody_context:meta()
}.
-type meta_service_result() :: #{
    status    => status(),
    result    => woody_server_thrift_handler:result() | woody_error:error()
}.

-type meta_client_send() :: #{
    url       => woody:url()
}.

-type meta_client_receive() :: #{
    status    => status(),
    %% optional
    code      => woody:http_code(),
    reason    => woody_error:details()
}.

-type meta_server_receive() :: #{
    url       => woody:url(),
    status    => status(),
    %% optional
    reason    => woody_error:details()
}.

-type meta_server_send() :: #{
    status    => status(),
    code      => woody:http_code()
}.

-type meta_invoke_service_handler() :: #{
    service   => service(),
    function  => woody:func(),
    args      => woody_server_thrift_handler:args(),
    metadata  => woody_context:meta()
}.

-type meta_service_handler_result() :: #{
    status    => status(),
    %% optional
    result    => woody_server_thrift_handler:result() |
                 woody_error:business_error() |
                 woody_error:system_error() |
                 _Error,
    class     => business | system,
    stack     => woody_error:stack(),
    ignore    => boolean()
}.

-type meta_thrift_error() :: #{
    stage     => thrift_stage(),
    reason    => any(),
    %% optional
    stack     => woody_error:stack()
}.

-type meta_internal_error() :: #{
    error     => any(),
    reason    => any(),
    %% optional
    stack     => woody_error:stack()
}.

-type meta_trace() :: #{
    event => atom() | binary()
}.

%%
%% API
%%
-spec handle_event
    (?EV_CALL_SERVICE   , meta_call_service   (), woody_context:ctx()) -> ok;
    (?EV_SERVICE_RESULT , meta_service_result (), woody_context:ctx()) -> ok;
    (?EV_CLIENT_SEND    , meta_client_send    (), woody_context:ctx()) -> ok;
    (?EV_CLIENT_RECEIVE , meta_client_receive (), woody_context:ctx()) -> ok;
    (?EV_SERVER_RECEIVE , meta_server_receive (), woody_context:ctx()) -> ok;
    (?EV_SERVER_SEND    , meta_server_send    (), woody_context:ctx()) -> ok;
    (?EV_INVOKE_SERVICE_HANDLER , meta_invoke_service_handler(), woody_context:ctx()) -> ok;
    (?EV_SERVICE_HANDLER_RESULT , meta_service_handler_result(), woody_context:ctx()) -> ok;
    (?EV_THRIFT_ERROR   , meta_thrift_error   (), woody_context:ctx()) -> ok;
    (?EV_INTERNAL_ERROR , meta_internal_error (), woody_context:ctx()) -> ok;
    (?EV_TRACE          , meta_trace          (), woody_context:ctx()) -> ok.
handle_event(Event, Meta, Context) ->
    {Handler, Opts} = woody_context:get_ev_handler(Context),
    _ = Handler:handle_event(Event, woody_context:get_rpc_id(Context), add_request_meta(Event, Meta, Context), Opts),
    ok.

-spec handle_event(woody:ev_handler(), ?EV_TRACE, undefined, meta_trace()) -> ok.
handle_event({Handler, Opts}, Event, RpcId, Meta) ->
    _ = Handler:handle_event(Event, RpcId, Meta, Opts),
    ok.

%%
%% Internal functions
%%
-spec add_request_meta(event(), woody_context:meta(), woody_context:ctx()) ->
    woody_context:meta().
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
