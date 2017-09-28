%%% @doc Internal state
%%% @end

-module(woody_state).

%%
%% API
%%

-export([new/3]).
-export([get_context/1, get_ev_handler/1, get_ev_meta/1]).
-export([add_ev_meta/2]).
-export([update_context/2]).
-export([add_context_meta/2]).

%% Types
-type st() :: #{
    context    := woody_context:ctx(),
    ev_handler := woody:ev_handler(),
    ev_meta    := woody_event_handler:meta()
}.
-export_type([st/0]).

%%
%% API
%%
-spec new(woody:role(), woody_context:ctx(), woody:ev_handler()) ->
    st().
new(Role, Context, EvHandler) ->
    add_metadata_to_ev_meta(
        woody_context:get_meta(Context),
        #{
            context    => Context,
            ev_handler => EvHandler,
            ev_meta    => #{role => Role}
        }
    ).

-spec get_context(st()) ->
    woody_context:ctx().
get_context(#{context := Context}) ->
    Context.

-spec get_ev_handler(st()) ->
    woody:ev_handler().
get_ev_handler(#{ev_handler := Handler}) ->
    Handler.

-spec get_ev_meta(st()) ->
    woody_event_handler:meta().
get_ev_meta(#{ev_meta := Meta}) ->
    Meta.

-spec add_ev_meta(woody_event_handler:meta(), st()) ->
    st().
add_ev_meta(ExtraMeta, State = #{ev_meta := Meta}) ->
    State#{ev_meta => maps:merge(Meta, ExtraMeta)}.

-spec update_context(woody_context:ctx(), st()) ->
    st().
update_context(NewContext, State) ->
    State#{context => NewContext}.

-spec add_context_meta(woody_context:meta(), st()) ->
    st().
add_context_meta(ContextMeta, State) ->
    add_metadata_to_ev_meta(ContextMeta, add_metadata_to_context(ContextMeta, State)).

%%
%% Internal functions
%%
-spec add_metadata_to_context(woody_context:meta(), st()) ->
    st().
add_metadata_to_context(ContextMeta, State) ->
    update_context(
        woody_context:add_meta(get_context(State), ContextMeta),
        State
    ).

-spec add_metadata_to_ev_meta(woody_context:meta(), st()) ->
    st().
add_metadata_to_ev_meta(ContextMeta, State) ->
    add_ev_meta(#{metadata => ContextMeta}, State).
