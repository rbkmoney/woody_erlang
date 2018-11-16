%%% @doc Type definitions
%%% @end

-module(woody).

%% Types

%% Dapper RPC
-type req_id()    :: binary().
-type span_id()   :: req_id().
-type trace_id()  :: req_id().
-type parent_id() :: req_id().

-type rpc_id() :: #{
    span_id   => span_id(),
    trace_id  => trace_id(),
    parent_id => parent_id()
}.

-type dapper_id() :: span_id | trace_id | parent_id.

-export_type([dapper_id/0, span_id/0, parent_id/0, trace_id/0]).
-export_type([req_id/0, rpc_id/0]).

-type millisec() :: woody_deadline:millisec().
-type deadline() :: woody_deadline:deadline().
-export_type([deadline/0, millisec/0]).

%% Thrift
-type service_name() :: atom().
-type service()      :: {module(), service_name()}.
-type func()         :: atom().
-type args()         :: list().
-type request()      :: {service(), func(), args()}.
-type result()       ::  _.
-type th_handler()   :: {service(), handler(options())}.
-export_type([request/0, result/0, service/0, service_name/0, func/0, args/0, th_handler/0]).

-type rpc_type() :: call | cast.
-export_type([rpc_type/0]).

%% Generic
-type options()     :: any().
-type handler(Opts) :: {module(), Opts} | module().
-type ev_handler()  :: handler(options()).
-export_type([handler/1, ev_handler/0, options/0]).

-type role()                :: client | server.
-type url()                 :: binary().
-type path()                :: '_' | iodata(). %% cowboy_router:route_match()
-type http_handler(Handler) :: {path(), Handler}.
-export_type([role/0, url/0, path/0, http_handler/1]).

-type http_code()        :: pos_integer().
-type http_header_name() :: binary().
-type http_header_val()  :: binary().
-type http_headers()     :: #{http_header_name() => http_header_val()}.
-type http_body()        :: binary().
-export_type([http_code/0, http_header_name/0, http_header_val/0, http_headers/0, http_body/0]).

%% copy-paste from OTP supervisor
-type sup_ref()  :: (Name :: atom())
                  | {Name :: atom(), Node :: node()}
                  | {'global', Name :: atom()}
                  | {'via', Module :: module(), Name :: any()}
                  | pid().
-export_type([sup_ref/0]).
