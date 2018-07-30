-ifndef(_woody_defs_included).
-define(_woody_defs_included, yeah).

%% Http headers
-define(CONTENT_TYPE_THRIFT    , <<"application/x-thrift">>).
-define(HEADER_PREFIX          , <<"x-rbk-">>).
-define(HEADER_RPC_ID          , << ?HEADER_PREFIX/binary, "span-id">>).
-define(HEADER_RPC_PARENT_ID   , << ?HEADER_PREFIX/binary, "parent-id">>).
-define(HEADER_RPC_ROOT_ID     , << ?HEADER_PREFIX/binary, "trace-id">>).
-define(HEADER_E_CLASS         , << ?HEADER_PREFIX/binary, "error-class">>).
-define(HEADER_E_REASON        , << ?HEADER_PREFIX/binary, "error-reason">>).
-define(HEADER_META_PREFIX     , << ?HEADER_PREFIX/binary, "meta-">>).
-define(HEADER_DEADLINE        , << ?HEADER_PREFIX/binary, "deadline">>).

%% Events
-define(EV_CALL_SERVICE           , 'call service').
-define(EV_SERVICE_RESULT         , 'service result').

-define(EV_CLIENT_SEND            , 'client send').
-define(EV_CLIENT_RECEIVE         , 'client receive').

-define(EV_CLIENT_CACHE_HIT       , 'client cache hit').
-define(EV_CLIENT_CACHE_MISS      , 'client cache miss').
-define(EV_CLIENT_CACHE_UPDATE    , 'client cache update').

-define(EV_SERVER_RECEIVE         , 'server receive').
-define(EV_SERVER_SEND            , 'server send').

-define(EV_INVOKE_SERVICE_HANDLER , 'invoke service handler').
-define(EV_SERVICE_HANDLER_RESULT , 'service handler result').

-define(EV_INTERNAL_ERROR         , 'internal error').
-define(EV_TRACE                  , 'trace event').

-endif.
