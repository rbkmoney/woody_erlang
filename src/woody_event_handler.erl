-module(woody_event_handler).

%% API
-export([handle_event/4]).

-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-export_type([event_type/0, event_meta_type/0, meta_client_send/0, meta_client_receive/0,
    meta_server_receive/0, meta_server_send/0, meta_invoke_service_handler/0,
    meta_service_handler_result/0, meta_thrift_error/0, meta_internal_error/0,
    meta_debug/0
]).

-callback handle_event
    %% mandatory
    (?EV_CALL_SERVICE           , woody:rpc_id(), meta_call_service   ()) -> _;
    (?EV_SERVICE_RESULT         , woody:rpc_id(), meta_service_result ()) -> _;
    (?EV_CLIENT_SEND            , woody:rpc_id(), meta_client_send    ()) -> _;
    (?EV_CLIENT_RECEIVE         , woody:rpc_id(), meta_client_receive ()) -> _;
    (?EV_SERVER_RECEIVE         , woody:rpc_id(), meta_server_receive ()) -> _;
    (?EV_SERVER_SEND            , woody:rpc_id(), meta_server_send    ()) -> _;
    (?EV_INVOKE_SERVICE_HANDLER , woody:rpc_id(), meta_invoke_service_handler ()) -> _;
    (?EV_SERVICE_HANDLER_RESULT , woody:rpc_id(), meta_service_handler_result ()) -> _;
    %% optional
    (?EV_THRIFT_ERROR           , woody:rpc_id(), meta_thrift_error   ()) -> _;
    (?EV_INTERNAL_ERROR         , woody:rpc_id(), meta_internal_error ()) -> _;
    (?EV_DEBUG                  , woody:rpc_id()|undefined, meta_debug()) -> _.

-type event_type() :: ?EV_CALL_SERVICE | ?EV_SERVICE_RESULT | ?EV_CLIENT_SEND | ?EV_CLIENT_RECEIVE |
    ?EV_SERVER_RECEIVE | ?EV_SERVER_SEND | ?EV_INVOKE_SERVICE_HANDLER  | ?EV_SERVICE_HANDLER_RESULT |
    ?EV_THRIFT_ERROR | ?EV_INTERNAL_ERROR | ?EV_DEBUG.

-type event_meta_type() :: meta_client_send() | meta_client_receive() |
    meta_server_receive() | meta_server_send() | meta_invoke_service_handler() |
    meta_service_handler_result() | meta_thrift_error() | meta_internal_error().

-type service()      :: woody:service_name().
-type rpc_type()     :: call | cast.
-type status()       :: ok | error.
-type thrift_stage() :: protocol_read | protocol_write.


-type meta_call_service() :: #{
    %% mandatory
    service   => service(),
    function  => woody:func(),
    type      => rpc_type(),
    %% optional
    args      => rpc_client:args()
}.
-type meta_service_result() :: #{
    %% mandatory
    status    => status(),
    %% optional
    result    => any()
}.

-type meta_client_send() :: #{
    %% mandatory
    url       => woody:url()
}.

-type meta_client_receive() :: #{
    %% mandatory
    status    => status(),
    %% optional
    code      => any(),
    reason    => any()
}.

-type meta_server_receive() :: #{
    %% mandatory
    url       => woody:url(),
    status    => status(),
    %% optional
    reason    => any()
}.

-type meta_server_send() :: #{
    %% mandatory
    status    => status(),
    %% optional
    code      => pos_integer()
}.

-type meta_invoke_service_handler() :: #{
    %% mandatory
    service   => service(),
    function  => woody:func(),
    %% optional
    args      => woody_server_thrift_handler:args(),
    options   => woody_server_thrift_handler:handler_opts()
}.

-type meta_service_handler_result() :: #{
    %% mandatory
    status    => status(),
    %% optional
    result    => any(),
    class     => throw | error | exit,
    reason    => any(),
    stack     => any(),
    ignore    => boolean()
}.

-type meta_thrift_error() :: #{
    %% mandatory
    stage     => thrift_stage(),
    reason    => any()
}.

-type meta_internal_error() :: #{
    %% mandatory
    error     => any(),
    reason    => any(),
    %% optional
    stack     => any()
}.

-type meta_debug() :: #{
    %% mandatory
    event => atom() | binary()
}.

%%
%% API
%%
-spec handle_event
    %% mandatory
    (woody:handler() , ?EV_CALL_SERVICE   , woody:rpc_id(), meta_call_service   ()) -> ok;
    (woody:handler() , ?EV_SERVICE_RESULT , woody:rpc_id(), meta_service_result ()) -> ok;
    (woody:handler() , ?EV_CLIENT_SEND    , woody:rpc_id(), meta_client_send    ()) -> ok;
    (woody:handler() , ?EV_CLIENT_RECEIVE , woody:rpc_id(), meta_client_receive ()) -> ok;
    (woody:handler() , ?EV_SERVER_RECEIVE , woody:rpc_id(), meta_server_receive ()) -> ok;
    (woody:handler() , ?EV_SERVER_SEND    , woody:rpc_id(), meta_server_send    ()) -> ok;
    (woody:handler() , ?EV_INVOKE_SERVICE_HANDLER , woody:rpc_id(), meta_invoke_service_handler()) -> ok;
    (woody:handler() , ?EV_SERVICE_HANDLER_RESULT , woody:rpc_id(), meta_service_handler_result()) -> ok;
    %% optional
    (woody:handler() , ?EV_THRIFT_ERROR   , woody:rpc_id(), meta_thrift_error   ()) -> ok;
    (woody:handler() , ?EV_INTERNAL_ERROR , woody:rpc_id(), meta_internal_error ()) -> ok;
    (woody:handler() , ?EV_DEBUG          , woody:rpc_id()|undefined, meta_debug()) -> ok.
handle_event(Handler, Type, RpcId, Meta) ->
    _ = Handler:handle_event(Type, RpcId, Meta),
    ok.
