-module(rpc_event_handler).

%% API
-export([handle_event/3]).

%%
%% behaviour definition
%%
-type event_type() :: atom() | {atom(), any()}.
-type meta() :: [{atom(), term()}].
-export_type([event_type/0, meta/0]).

-callback handle_event(event_type(), meta()) -> _.


%%
%% API
%%
-spec handle_event(rpc_t:handler(), event_type(), meta()) -> _.
handle_event(Handler, Type, Meta) ->
    Handler:handle_event(Type, Meta).
