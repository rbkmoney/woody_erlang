%%% @doc Client API
%%% @end

-module(woody_context).

-include("woody_defs.hrl").

%% API
-export([new/2, new/3]).

-export([get_rpc_id/1, get_rpc_id/2]).

-export([set_ev_handler/2]).
-export([get_ev_handler/1]).

-export([add_meta/2]).
-export([get_meta/1, get_meta/2]).

-export([make_rpc_id/1, make_rpc_id/3]).
-export([new_req_id/0]).
-export([unique_int/0]).

%% For intenal use in woody_erlang
-export([new_child/1]).

%% Types
-export_type([ctx/0]).
-export_type([meta/0]).
-export_type([meta_key/0]).

-type ctx() :: #{  %% The elements are madatory if not specified otherwise
    rpc_id        => woody_t:rpc_id(),
    event_handler => woody_t:handler(),
    meta          => meta()  %% optional
}.
-type meta()     :: #{binary() => binary()}.
-type meta_key() :: binary().

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).


%%
%% API
%%
-spec new(woody_t:req_id() | woody_t:rpc_id() | undefined, woody_t:handler()) ->
    ctx().
new(Id, EvHandler) ->
    new(Id, EvHandler, undefined).

-spec new(woody_t:rpc_id() | woody_t:trace_id() | undefined, woody_t:handler(), meta() | undefined) ->
    ctx().
new(undefined, EvHandler, Meta) ->
    %% This is going to be a root RPC with autogenerated RpcId
    new(new_req_id(), EvHandler, Meta);
new(RpcId = #{}, EvHandler, Meta) ->
    make_ctx(RpcId, EvHandler, Meta);
new(TraceId, EvHandler, Meta) ->
    new(
        make_rpc_id(?ROOT_REQ_PARENT_ID, TraceId, new_req_id()),
        EvHandler,
        Meta
    ).

-spec new_child(ctx()) -> ctx().
new_child(Context = #{rpc_id := #{trace_id := TraceId, span_id := SpanId}}) ->
    Context#{rpc_id => make_rpc_id(SpanId, TraceId, new_req_id())}.

-spec add_meta(ctx(), meta()) ->
    ctx().
add_meta(Context, Meta) ->
    Context#{meta => append_meta(get_meta(Context), Meta)}.

-spec get_meta(ctx()) ->
    meta().
get_meta(Context) ->
    case maps:get(meta, Context, undefined) of
        undefined ->
            #{};
        Meta ->
            Meta
    end.

-spec get_meta(meta_key(), ctx()) ->
    binary() | undefined.
get_meta(MetaKey, Context) ->
    maps:get(MetaKey, maps:get(meta, Context), undefined).


-spec get_rpc_id(ctx()) ->
    woody_t:rpc_id() | no_return().
get_rpc_id(#{rpc_id := RpcId}) ->
    RpcId;
get_rpc_id( _) ->
    error(badarg).

-spec get_rpc_id(woody_t:dapper_id(), ctx()) ->
  woody_t:req_id() | undefined | no_return().
get_rpc_id(Key, Context) ->
    maps:get(Key, get_rpc_id(Context), undefined).

-spec set_ev_handler(woody_t:handler(), woody_context:ctx()) ->
    woody_context:ctx().
set_ev_handler(EvHandler, Context) ->
    Context#{event_handler := EvHandler}.

-spec get_ev_handler(woody_context:ctx()) ->
    woody_t:handler().
get_ev_handler(#{event_handler := EvHandler}) ->
    EvHandler.

-spec make_rpc_id(woody_t:trace_id()) ->
    woody_t:trace_id().
make_rpc_id(TraceId) ->
    make_rpc_id(?ROOT_REQ_PARENT_ID, TraceId, new_req_id()).

-spec make_rpc_id(woody_t:parent_id(), woody_t:trace_id(), woody_t:span_id()) ->
    woody_t:rpc_id().
make_rpc_id(ParentId, TraceId, SpanId) ->
    #{
        parent_id => ParentId,
        trace_id  => TraceId,
        span_id   => SpanId
    }.

-spec new_req_id() ->
    woody_t:req_id().
new_req_id() ->
    genlib:to_binary(unique_int()).

-spec unique_int() ->
    pos_integer().
unique_int() ->
    <<Id:64>> = snowflake:new(?MODULE),
    Id.

%%
%% Internal functions
%%
-spec make_ctx(woody_t:rpc_id(), woody_t:handler(), meta() | undefined) ->
    ctx() | no_return().
make_ctx(RpcId, EvHandler, Meta) ->
    init_meta(#{
        rpc_id        => RpcId,
        event_handler => EvHandler
    }, Meta).

-spec init_meta(ctx(), meta() | undefined) -> ctx().
init_meta(Context, undefined) ->
    Context;
init_meta(Context, Meta) ->
    Context#{meta => Meta}.

-spec append_meta(meta(), map()) ->
    meta() | no_return().
append_meta(MetaBase, MetaNew) ->
    Meta = maps:merge(MetaNew, MetaBase),
    SizeSum = maps:size(MetaBase) + maps:size(MetaNew),
    case maps:size(Meta) of
        SizeSum ->
            Meta;
        _ ->
            error({badarg, meta_duplicates})
    end.
