%%% @doc Woody context API
%%% @end

-module(woody_context).

-include("woody_defs.hrl").

%% API
-export([new/0, new/1, new/2, new/3]).

-export([get_rpc_id/1, get_rpc_id/2]).

-export([add_meta/2]).
-export([get_meta/1, get_meta/2]).

-export([set_deadline/2]).
-export([get_deadline/1]).

-export([set_cert/2]).
-export([get_cert/1]).
-export([get_common_name/1]).

-export([new_rpc_id/1, new_rpc_id/3]).
-export([new_req_id/0]).
-export([new_unique_int/0]).

%% Internal API
-export([new_child/1]).

%% Types
-export_type([ctx/0]).
-export_type([meta/0]).
-export_type([meta_key/0]).

-type ctx() :: #{
    rpc_id     := woody:rpc_id(),
    deadline   := woody:deadline(),
    meta       => meta(),
    cert       => woody:cert()
}.

-type meta_value() :: binary().
-type meta_key()   :: binary().
-type meta()       :: #{meta_key() => meta_value()}.

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).


%%
%% API
%%
-spec new() ->
    ctx().
new() ->
    new(new_req_id()).

-spec new(woody:req_id() | woody:rpc_id()) ->
    ctx().
new(Id) ->
    new(Id, undefined).

-spec new(woody:rpc_id() | woody:trace_id(),  meta() | undefined) ->
    ctx().
new(Id, Meta) ->
    new(Id, Meta, undefined).

-spec new(woody:rpc_id() | woody:trace_id(),  meta() | undefined, woody:deadline()) ->
    ctx().
new(Id, Meta, Deadline) ->
    make_ctx(expand_rpc_id(Id), Meta, Deadline).

-spec new_child(ctx()) ->
    ctx().
new_child(Context = #{rpc_id := #{trace_id := TraceId, span_id := SpanId}}) ->
    Context#{rpc_id => new_rpc_id(SpanId, TraceId, new_req_id())}.

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
    maps:get(MetaKey, maps:get(meta, Context, #{}), undefined).


-spec get_rpc_id(ctx()) ->
    woody:rpc_id() | no_return().
get_rpc_id(#{rpc_id := RpcId}) ->
    RpcId;
get_rpc_id( _) ->
    error(badarg).

-spec get_rpc_id(woody:dapper_id(), ctx()) ->
  woody:req_id() | undefined | no_return().
get_rpc_id(Key, Context) ->
    maps:get(Key, get_rpc_id(Context), undefined).

-spec new_rpc_id(woody:span_id()) ->
    woody:rpc_id().
new_rpc_id(SpanId) ->
    new_rpc_id(?ROOT_REQ_PARENT_ID, new_req_id(), SpanId).

-spec new_rpc_id(woody:parent_id(), woody:trace_id(), woody:span_id()) ->
    woody:rpc_id().
new_rpc_id(ParentId, TraceId, SpanId) ->
    #{
        parent_id => ParentId,
        trace_id  => TraceId,
        span_id   => SpanId
    }.

-spec new_req_id() ->
    woody:req_id().
new_req_id() ->
    genlib:to_binary(new_unique_int()).

-spec new_unique_int() ->
    pos_integer().
new_unique_int() ->
    <<Id:64>> = snowflake:new(?MODULE),
    Id.

-spec set_deadline(woody:deadline(), ctx()) ->
    ctx().
set_deadline(Deadline, Context) ->
    Context#{deadline => Deadline}.

-spec get_deadline(ctx()) ->
    woody:deadline().
get_deadline(#{deadline := Deadline}) ->
    Deadline.

-spec set_cert(woody:cert() | undefined, ctx()) ->
    ctx().
set_cert(Cert, Context) ->
    Context#{cert => Cert}.

-spec get_cert(ctx()) ->
    woody:cert() | undefined.
get_cert(#{cert := Cert}) ->
    Cert;
get_cert(_) ->
    undefined.

-spec get_common_name(ctx()) ->
    {ok, woody_cert:common_name()} | {error, not_found}.
get_common_name(#{cert := Cert}) ->
    woody_cert:get_common_name(Cert);
get_common_name(_) ->
    {error, not_found}.

%%
%% Internal functions
%%
-spec expand_rpc_id(woody:rpc_id() | woody:trace_id()) ->
    woody:rpc_id().
expand_rpc_id(RpcId = #{}) ->
    RpcId;
expand_rpc_id(TraceId) ->
    new_rpc_id(TraceId).

-spec make_ctx(woody:rpc_id(), meta() | undefined, woody:deadline()) ->
    ctx() | no_return().
make_ctx(RpcId = #{span_id := _, parent_id := _, trace_id := _}, Meta, Deadline) ->
    _ = genlib_map:foreach(fun check_req_id_limit/2, RpcId),
    init_meta(#{rpc_id => RpcId, deadline => Deadline}, Meta);
make_ctx(RpcId, Meta, Deadline) ->
    error(badarg, [RpcId, Meta, Deadline]).

check_req_id_limit(_Type, Id) when is_binary(Id) andalso byte_size(Id) =< 32 ->
    ok;
check_req_id_limit(Type, Id) ->
    error(badarg, [Type, Id]).

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
            error(badarg, [MetaBase, MetaNew])
    end.
