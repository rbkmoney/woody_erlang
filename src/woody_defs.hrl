-ifndef(_woody_defs_included).
-define(_woody_defs_included, yeah).

%% HTTP headers
-define(CONTENT_TYPE_THRIFT    , <<"application/x-thrift">>).

%% Woody-specific HTTP headers
-define(NORMAL_HEADER_PREFIX          , <<"woody.">>).
-define(NORMAL_HEADER_RPC_ID          , << ?NORMAL_HEADER_PREFIX/binary, "span-id">>).
-define(NORMAL_HEADER_RPC_PARENT_ID   , << ?NORMAL_HEADER_PREFIX/binary, "parent-id">>).
-define(NORMAL_HEADER_RPC_ROOT_ID     , << ?NORMAL_HEADER_PREFIX/binary, "trace-id">>).
-define(NORMAL_HEADER_E_CLASS         , << ?NORMAL_HEADER_PREFIX/binary, "error-class">>).
-define(NORMAL_HEADER_E_REASON        , << ?NORMAL_HEADER_PREFIX/binary, "error-reason">>).
-define(NORMAL_HEADER_DEADLINE        , << ?NORMAL_HEADER_PREFIX/binary, "deadline">>).
-define(NORMAL_HEADER_META_PREFIX     , << ?NORMAL_HEADER_PREFIX/binary, "meta.">>).
-define(NORMAL_HEADER_META_RE         , <<"woody\\.meta\\.">>).

%% Legacy woody headers
-define(LEGACY_HEADER_PREFIX          , <<"x-rbk-">>).
-define(LEGACY_HEADER_RPC_ID          , << ?LEGACY_HEADER_PREFIX/binary, "span-id">>).
-define(LEGACY_HEADER_RPC_PARENT_ID   , << ?LEGACY_HEADER_PREFIX/binary, "parent-id">>).
-define(LEGACY_HEADER_RPC_ROOT_ID     , << ?LEGACY_HEADER_PREFIX/binary, "trace-id">>).
-define(LEGACY_HEADER_E_CLASS         , << ?LEGACY_HEADER_PREFIX/binary, "error-class">>).
-define(LEGACY_HEADER_E_REASON        , << ?LEGACY_HEADER_PREFIX/binary, "error-reason">>).
-define(LEGACY_HEADER_DEADLINE        , << ?LEGACY_HEADER_PREFIX/binary, "deadline">>).
-define(LEGACY_HEADER_META_PREFIX     , << ?LEGACY_HEADER_PREFIX/binary, "meta-">>).
-define(LEGACY_HEADER_META_RE         , <<"x-rbk-meta-">>).

%% transition period helpers
-define(HEADER(MODE, NORMAL, LEGACY), case MODE of normal -> NORMAL; legacy -> LEGACY end).
-define(HEADER_PREFIX(MODE), ?HEADER(MODE, ?NORMAL_HEADER_PREFIX, ?LEGACY_HEADER_PREFIX)).
-define(HEADER_RPC_ID(MODE), ?HEADER(MODE, ?NORMAL_HEADER_RPC_ID, ?LEGACY_HEADER_RPC_ID)).
-define(HEADER_RPC_PARENT_ID(MODE), ?HEADER(MODE, ?NORMAL_HEADER_RPC_PARENT_ID, ?LEGACY_HEADER_RPC_PARENT_ID)).
-define(HEADER_RPC_ROOT_ID(MODE), ?HEADER(MODE, ?NORMAL_HEADER_RPC_ROOT_ID, ?LEGACY_HEADER_RPC_ROOT_ID)).
-define(HEADER_E_CLASS(MODE), ?HEADER(MODE, ?NORMAL_HEADER_E_CLASS, ?LEGACY_HEADER_E_CLASS)).
-define(HEADER_E_REASON(MODE), ?HEADER(MODE, ?NORMAL_HEADER_E_REASON, ?LEGACY_HEADER_E_REASON)).
-define(HEADER_DEADLINE(MODE), ?HEADER(MODE, ?NORMAL_HEADER_DEADLINE, ?LEGACY_HEADER_DEADLINE)).
-define(HEADER_META_PREFIX(MODE), ?HEADER(MODE, ?NORMAL_HEADER_META_PREFIX, ?LEGACY_HEADER_META_PREFIX)).
-define(HEADER_META_RE(MODE), ?HEADER(MODE, ?NORMAL_HEADER_META_RE, ?LEGACY_HEADER_META_RE)).

%% Events
-define(EV_CALL_SERVICE           , 'call service').
-define(EV_SERVICE_RESULT         , 'service result').

-define(EV_CLIENT_BEGIN           , 'client begin').
-define(EV_CLIENT_SEND            , 'client send').
-define(EV_CLIENT_RESOLVE_BEGIN   , 'client resolve begin').
-define(EV_CLIENT_RESOLVE_RESULT  , 'client resolve result').
-define(EV_CLIENT_RECEIVE         , 'client receive').
-define(EV_CLIENT_END             , 'client end').

-define(EV_CLIENT_CACHE_BEGIN     , 'client cache begin').
-define(EV_CLIENT_CACHE_HIT       , 'client cache hit').
-define(EV_CLIENT_CACHE_MISS      , 'client cache miss').
-define(EV_CLIENT_CACHE_UPDATE    , 'client cache update').
-define(EV_CLIENT_CACHE_RESULT    , 'client cache result').
-define(EV_CLIENT_CACHE_END       , 'client cache end').

-define(EV_SERVER_RECEIVE         , 'server receive').
-define(EV_SERVER_SEND            , 'server send').

-define(EV_INVOKE_SERVICE_HANDLER , 'invoke service handler').
-define(EV_SERVICE_HANDLER_RESULT , 'service handler result').

-define(EV_INTERNAL_ERROR         , 'internal error').
-define(EV_TRACE                  , 'trace event').

-endif.
