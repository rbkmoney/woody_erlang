-module(woody_ct_event_h).

-behaviour(woody_event_handler).
-export([handle_event/4]).

-define(ESSENTIAL_META, [
    event,
    role,
    service,
    service_schema,
    function,
    type,
    args,
    metadata,
    deadline,
    status,
    url,
    code,
    result
]).

-spec handle_event(
    woody_event_handler:event(),
    woody:rpc_id(),
    woody_event_handler:event_meta(),
    _Prelude
) -> _.
handle_event(Event, RpcId, Meta, Prelude) ->
    {Format, Msg} = woody_event_handler:format_event(Event, Meta, RpcId, #{}),
    EvMeta = woody_event_handler:format_meta(Event, Meta, ?ESSENTIAL_META),
    ct:pal("~p " ++ Format ++ "~nmeta: ~p", [Prelude] ++ Msg ++ [EvMeta]).
