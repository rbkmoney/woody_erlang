-ifndef(_woody_defs_included).
-define(_woody_defs_included, yeah).

%% Http headers
-define(CONTENT_TYPE_THRIFT         , <<"application/x-thrift">>).
-define(HEADER_NAME_PREFIX          , <<"x-rbk-">>).
-define(HEADER_NAME_RPC_ID          , << ?HEADER_NAME_PREFIX/binary, "span-id">>).
-define(HEADER_NAME_RPC_PARENT_ID   , << ?HEADER_NAME_PREFIX/binary, "parent-id">>).
-define(HEADER_NAME_RPC_ROOT_ID     , << ?HEADER_NAME_PREFIX/binary, "trace-id">>).
-define(HEADER_NAME_ERROR_TRANSPORT , << ?HEADER_NAME_PREFIX/binary, "rpc-error-thrift">>).
-define(HEADER_NAME_ERROR_LOGIC     , << ?HEADER_NAME_PREFIX/binary, "rpc-error-logic">>).

%% Errors & exceptions
-define(EXCEPT_THRIFT(Exception) , {exception, Exception}).
-define(ERROR_PROTOCOL(Reason)   , {protocol_error, Reason}).
-define(ERROR_TRANSPORT(Reason)  , {transport_error, Reason}).

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

-define(EV_DEBUG                  , 'trace_event').
-endif.
