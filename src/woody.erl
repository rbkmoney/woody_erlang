%%% @doc Client API
%%% @end

-module(woody).

-include("woody_defs.hrl").

%% API
-export([call/3]).
-export([call_safe/3]).
-export([call_async/5]).

-export([child_spec/2]).

%% Types
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

-type rpc_type() :: call | cast.
-export_type([rpc_type/0]).

-type options()  :: any().
-type handler()  :: {module(), options()}.
-export_type([handler/0, options/0]).

-type url() :: binary().
-type http_code() :: pos_integer().
-type http_headers() :: list({binary(), binary()}).
-type http_body() :: binary().
-export_type([url/0, http_code/0, http_headers/0, http_body/0]).

-type service_name() :: atom().
-type service()      :: {module(), service_name()}.
-type func()         :: atom().
-export_type([service/0, service_name/0, func/0]).

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
-spec call(woody_context:ctx(), woody_client:request(), woody_client:options()) ->
    woody_client:result_ok() | no_return().
call(Context, Request, Options) ->
    woody_client:call(Context, Request, Options).

-spec call_safe(woody_context:ctx(), woody_client:request(), woody_client:options()) ->
    woody_client:result().
call_safe(Context, Request, Options) ->
    woody_client:call_safe(Context, Request, Options).

-spec call_async(woody_context:ctx(), woody_client:request(), woody_client:options(),
    sup_ref(), woody_client:callback())
->
    {ok, pid()} | {error, _}.
call_async(Context, Request, Options, Sup, Callback) ->
    woody_client:call_async(Context, Request, Options, Sup, Callback).

-spec child_spec(_Id, woody_server:options()) -> supervisor:child_spec().
child_spec(Id, Options) ->
    woody_server:child_spec(Id, Options).
