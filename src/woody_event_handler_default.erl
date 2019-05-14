-module(woody_event_handler_default).

-behaviour(woody_event_handler).

%% woody_event_handler behaviour callback
-export([handle_event/4]).

%%
%% woody_event_handler behaviour callback
%%
-spec handle_event(Event, RpcId, Meta, Opts) -> ok when
    Event :: woody_event_handler:event(),
    RpcId :: woody:rpc_id() | undefined,
    Meta  :: woody_event_handler:event_meta(),
    Opts  :: woody:options().
handle_event(Event, RpcId, Meta, _Opts) ->
    {Level, {Format, Msg}} = woody_event_handler:format_event(Event, Meta, RpcId),
    Function = get_logger_function(Level),
    _ = error_logger:Function(Format, Msg),
    ok.

get_logger_function(Level) when Level =:= debug ; Level =:= info ->
    info_msg;
get_logger_function(warning) ->
    warning_msg;
get_logger_function(error)   ->
    error_msg.

