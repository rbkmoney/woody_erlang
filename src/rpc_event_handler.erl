-module(rpc_event_handler).

%% API
-export([handle_event/3]).

-define(create_rpc     , 'create rpc').
-define(rpc_result     , 'get rpc result').

-define(client_send    , 'client send request').
-define(client_receive , 'client receive response').

-define(server_receive , 'server receive request').
-define(server_send    , 'server send response').

-define(call_service   , 'call service').
-define(service_result , 'get service result').

-define(thrift_error   , 'thrift error').
-define(internal_error , 'internal error').


%%
%% behaviour definition
%%
-export_type([event_type/0, meta_client_send/0, meta_client_receive/0,
    meta_server_receive/0, meta_server_send/0, meta_call_service/0,
    meta_service_result/0, meta_thrift_error/0, meta_internal_error/0
]).

-callback handle_event
    %% mandatory
    (?create_rpc     , meta_create_rpc     ()) -> _;
    (?rpc_result     , meta_rpc_result     ()) -> _;
    (?client_send    , meta_client_send    ()) -> _;
    (?client_receive , meta_client_receive ()) -> _;
    (?server_receive , meta_server_receive ()) -> _;
    (?server_send    , meta_server_send    ()) -> _;
    (?call_service   , meta_call_service   ()) -> _;
    (?service_result , meta_service_result ()) -> _;
    %% optional
    (?thrift_error   , meta_thrift_error   ()) -> _;
    (?internal_error , meta_internal_error ()) -> _.


-type event_type() :: ?client_send | ?client_receive | ?server_receive |
    ?server_send | ?call_service  | ?service_result | ?thrift_error |
    ?internal_error.

-type service() :: binary().
-type rpc_type() :: call | cast.
-type status() :: ok | error.
-type thrift_stage() :: protocol_read | protocol_write.


-type meta_create_rpc() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    service   => service(),
    function  => rpc_t:func(),
    type      => rpc_type(),
    %% optional
    args      => rpc_client:args()
}.
-type meta_rpc_result() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    status    => status(),
    %% optional
    result    => any()
}.

-type meta_client_send() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    url       => rpc_t:url()
}.

-type meta_client_receive() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    status    => status(),
    %% optional
    code      => any(),
    reason    => any()
}.

-type meta_server_receive() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    url       => rpc_t:url(),
    status    => status(),
    %% optional
    reason    => any()
}.

-type meta_server_send() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    status    => status(),
    %% optional
    code      => pos_integer()
}.

-type meta_call_service() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    service   => service(),
    function  => rpc_t:func(),
    %% optional
    args      => rpc_thrift_handler:args(),
    options   => rpc_thrift_handler:handler_opts()
}.

-type meta_service_result() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
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
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
    stage     => thrift_stage(),
    reason    => any()
}.

-type meta_internal_error() :: #{
    %% mandatory
    span_id   => rpc_t:rpc_id(),
    parent_id => rpc_t:rpc_id(),
    trace_id  => rpc_t:rpc_id(),
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
    (rpc_t:handler() , ?create_rpc     , meta_create_rpc     ()) -> _;
    (rpc_t:handler() , ?rpc_result     , meta_rpc_result     ()) -> _;
    (rpc_t:handler() , ?client_send    , meta_client_send    ()) -> _;
    (rpc_t:handler() , ?client_receive , meta_client_receive ()) -> _;
    (rpc_t:handler() , ?server_receive , meta_server_receive ()) -> _;
    (rpc_t:handler() , ?server_send    , meta_server_send    ()) -> _;
    (rpc_t:handler() , ?call_service   , meta_call_service   ()) -> _;
    (rpc_t:handler() , ?service_result     , meta_service_result ()) -> _;
    %% optional
    (rpc_t:handler() , ?thrift_error   , meta_thrift_error   ()) -> _;
    (rpc_t:handler() , ?internal_error , meta_internal_error ()) -> _.
handle_event(Handler, Type, Meta) ->
    Handler:handle_event(Type, Meta).
