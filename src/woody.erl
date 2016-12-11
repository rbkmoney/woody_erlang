%%% @doc Client API
%%% @end

-module(woody).

-include("woody_defs.hrl").

%% Client API
-export([call/3]).
-export([call_async/5]).

%% for root calls only
-export([call/4, call/5]).
-export([call_async/6, call_async/7]).

%% Server API
-export([child_spec/2]).


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

%% Thrift
-type service_name() :: atom().
-type service()      :: handler(service_name()).
-type func()         :: atom().
-type args()         :: list().
-type request()      :: {service(), func(), args()}.
-type result()       :: any().
-type th_handler()   :: {service(), handler(options())}.
-export_type([request/0, result/0, service/0, service_name/0, func/0, args/0, th_handler/0]).

-type rpc_type() :: call | cast.
-export_type([rpc_type/0]).

%% Generic
-type options()  :: any().
-type handler(Opts)  :: {module(), Opts}.
-type ev_handler()   :: handler(options()).
-export_type([handler/1, ev_handler/0, options/0]).

-type url()                 :: binary().
-type path()                :: '_' | iodata(). %% cowboy_router:route_match()
-type http_handler(Handler) :: {path(), Handler}.
-export_type([url/0, path/0, http_handler/1]).

-type http_code()    :: pos_integer().
-type http_headers() :: list({binary(), binary()}).
-type http_body()    :: binary().
-export_type([http_code/0, http_headers/0, http_body/0]).

%% copy-paste from OTP supervsor
-type sup_ref()  :: (Name :: atom())
                  | {Name :: atom(), Node :: node()}
                  | {'global', Name :: atom()}
                  | {'via', Module :: module(), Name :: any()}
                  | pid().
-export_type([sup_ref/0]).

%%
%% API
%%

%% client
-spec call(request(), woody_client:options(),
    woody_context:ctx())
->
    result() | no_return().
call(Request, Options, Context) ->
    woody_client:call(Request, Options, Context).

%% Use call/4, call/5 only for root calls.
-spec call(request(), woody_client:options(),
    woody_client:id(), ev_handler())
->
    result() | no_return().
call(Request, Options, Id, EvHandler) ->
    woody_client:call(Request, Options, Id, EvHandler).

-spec call(request(), woody_client:options(),
    woody_client:id(), ev_handler(), woody_context:meta() | undefined)
->
    result() | no_return().
call(Request, Options, Id, EvHandler, Meta) ->
    woody_client:call(Request, Options, Id, EvHandler, Meta).


-spec call_async(request(), woody_client:options(), sup_ref(), woody_client:async_cb(),
    woody_context:ctx())
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Context) ->
    woody_client:call_async(Request, Options, Sup, Callback, Context).

%% Use call_async/6, call_async/7 only for root calls.
-spec call_async(request(), woody_client:options(), sup_ref(), woody_client:async_cb(),
    woody_client:id(), ev_handler())
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler) ->
    woody_client:call_async(Request, Options, Sup, Callback, Id, EvHandler).

-spec call_async(request(), woody_client:options(), sup_ref(), woody_client:async_cb(),
    woody_client:id(), ev_handler(), woody_context:meta() | undefined)
->
    {ok, pid()} | {error, _}.
call_async(Request, Options, Sup, Callback, Id, EvHandler, Meta) ->
    woody_client:call_async(Request, Options, Sup, Callback, Id, EvHandler, Meta).

%% server
-spec child_spec(_Id, woody_server:options()) -> supervisor:child_spec().
child_spec(Id, Options) ->
    woody_server:child_spec(Id, Options).
