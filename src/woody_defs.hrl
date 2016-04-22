-ifndef(_woody_defs_included).
-define(_woody_defs_included, yeah).

%% Http headers
-define(CONTENT_TYPE_THRIFT         , <<"application/x-thrift">>).
-define(HEADER_NAME_RPC_ID          , <<"x-rbk-span-id">>).
-define(HEADER_NAME_RPC_PARENT_ID   , <<"x-rbk-parent-id">>).
-define(HEADER_NAME_RPC_ROOT_ID     , <<"x-rbk-trace-id">>).
-define(HEADER_NAME_ERROR_TRANSPORT , <<"x-rbk-rpc-error-thrift">>).
-define(HEADER_NAME_ERROR_LOGIC     , <<"x-rbk-rpc-error-logic">>).

%% Errors & exceptions
-define(except_thrift(Exception) , {exception, Exception}).
-define(error_protocol(Reason)   , {protocol_error, Reason}).
-define(error_transport(Reason)  , {transport_error, Reason}).

%% Events
-define(EV_CALL_SERVICE           , 'call service').
-define(EV_SERVICE_RESULT         , 'service result').

-define(EV_CLIENT_SEND            , 'client send').
-define(EV_CLIENT_RECEIVE         , 'client receive').

-define(EV_SERVER_RECEIVE         , 'server receive').
-define(EV_SERVER_SEND            , 'server send').

-define(EV_INVOKE_SERVICE_HANDLER , 'invoke service handler').
-define(EV_SERVICE_HANDLER_RESULT , 'service handler result').

-define(EV_THRIFT_ERROR           , 'thrift error').
-define(EV_INTERNAL_ERROR         , 'internal error').

-endif.