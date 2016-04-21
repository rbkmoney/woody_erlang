-module(woody_event_handler).

%% API
-export([handle_event/3]).

-include("woody_defs.hrl").

%%
%% behaviour definition
%%
-export_type([event_type/0, meta_client_send/0, meta_client_receive/0,
    meta_server_receive/0, meta_server_send/0, meta_invoke_service_handler/0,
    meta_service_handler_result/0, meta_thrift_error/0, meta_internal_error/0
]).

-callback handle_event
    %% mandatory
    (?EV_CALL_SERVICE           , meta_call_service   ()) -> _;
    (?EV_SERVICE_RESULT         , meta_service_result ()) -> _;
    (?EV_CLIENT_SEND            , meta_client_send    ()) -> _;
    (?EV_CLIENT_RECEIVE         , meta_client_receive ()) -> _;
    (?EV_SERVER_RECEIVE         , meta_server_receive ()) -> _;
    (?EV_SERVER_SEND            , meta_server_send    ()) -> _;
    (?EV_INVOKE_SERVICE_HANDLER , meta_invoke_service_handler ()) -> _;
    (?EV_SERVICE_HANDLER_RESULT , meta_service_handler_result ()) -> _;
    %% optional
    (?EV_THRIFT_ERROR           , meta_thrift_error   ()) -> _;
    (?EV_INTERNAL_ERROR         , meta_internal_error ()) -> _.


-type event_type() :: ?EV_CALL_SERVICE | ?EV_SERVICE_RESULT | ?EV_CLIENT_SEND | ?EV_CLIENT_RECEIVE |
    ?EV_SERVER_RECEIVE | ?EV_SERVER_SEND | ?EV_INVOKE_SERVICE_HANDLER  | ?EV_SERVICE_HANDLER_RESULT |
    ?EV_THRIFT_ERROR | ?EV_INTERNAL_ERROR.

-type service()      :: woody_t:service().
-type rpc_type()     :: call | cast.
-type status()       :: ok | error.
-type thrift_stage() :: protocol_read | protocol_write.


-type meta_call_service() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    service   => service(),
    function  => woody_t:func(),
    type      => rpc_type(),
    %% optional
    args      => rpc_client:args()
}.
-type meta_service_result() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    status    => status(),
    %% optional
    result    => any()
}.

-type meta_client_send() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    url       => woody_t:url()
}.

-type meta_client_receive() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    status    => status(),
    %% optional
    code      => any(),
    reason    => any()
}.

-type meta_server_receive() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    url       => woody_t:url(),
    status    => status(),
    %% optional
    reason    => any()
}.

-type meta_server_send() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    status    => status(),
    %% optional
    code      => pos_integer()
}.

-type meta_invoke_service_handler() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    service   => service(),
    function  => woody_t:func(),
    %% optional
    args      => woody_server_thrift_handler:args(),
    options   => woody_server_thrift_handler:handler_opts()
}.

-type meta_service_handler_result() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
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
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    stage     => thrift_stage(),
    reason    => any()
}.

-type meta_internal_error() :: #{
    %% mandatory
    span_id   => woody_t:req_id(),
    parent_id => woody_t:req_id(),
    trace_id  => woody_t:req_id(),
    error     => any(),
    reason    => any(),
    %% optional
    stack     => any()
}.


%%
%% API
%%
-spec handle_event
    %% mandatory
    (woody_t:handler() , ?EV_CALL_SERVICE   , meta_call_service   ()) -> _;
    (woody_t:handler() , ?EV_SERVICE_RESULT , meta_service_result ()) -> _;
    (woody_t:handler() , ?EV_CLIENT_SEND    , meta_client_send    ()) -> _;
    (woody_t:handler() , ?EV_CLIENT_RECEIVE , meta_client_receive ()) -> _;
    (woody_t:handler() , ?EV_SERVER_RECEIVE , meta_server_receive ()) -> _;
    (woody_t:handler() , ?EV_SERVER_SEND    , meta_server_send    ()) -> _;
    (woody_t:handler() , ?EV_INVOKE_SERVICE_HANDLER , meta_invoke_service_handler()) -> _;
    (woody_t:handler() , ?EV_SERVICE_HANDLER_RESULT , meta_service_handler_result()) -> _;
    %% optional
    (woody_t:handler() , ?EV_THRIFT_ERROR   , meta_thrift_error   ()) -> _;
    (woody_t:handler() , ?EV_INTERNAL_ERROR , meta_internal_error ()) -> _.
handle_event(Handler, Type, Meta) ->
    Handler:handle_event(Type, Meta).
