-module(rpc_event_handler).

%%
%% Behaviour definition
%%
-type event_type() :: atom() | {atom(), any()}.
-type meta() :: [{atom(), term()}].

-export_type([event_type/0, meta/0]).

-callback handle_event(Type, Meta) -> _ when
    Type :: event_type(),
    Meta :: meta().

%%
%% API
%%
-export([handle_event/3]).

-spec handle_event(Handler, Type, Meta) -> _ when
    Handler :: module(),
    Type :: event_type(),
    Meta :: meta().
handle_event(Handler, Type, Meta) when
    is_atom(Handler),
    is_list(Meta)
->
    Handler:handle_event(Type, Meta).
