-ifndef(_rpc_thrift_http_headers_included).
-define(_rpc_thrift_http_headers_included, yeah).

-define(CONTENT_TYPE_THRIFT, <<"application/x-thrift">>).
-define(HEADER_NAME_RPC_ID, <<"x-rbk-rpc-id">>).
-define(HEADER_NAME_RPC_PARENT_ID, <<"x-rbk-rpc-parent-id">>).
-define(HEADER_NAME_ERROR_TRANSPORT, <<"x-rbk-rpc-error-transport">>).
-define(HEADER_NAME_ERROR_LOGIC, <<"x-rbk-rpc-error-logic">>).
-endif.
