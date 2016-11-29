%%% @doc Client API
%%% @end

-module(woody_error).

%% API
-export([make_error/3]).
-export([is_error/1]).

%% Types
-export_type([error/0, source/0, class/0, data/0]).

-type error () :: {source(), class(), data()}.
-type source() :: internal | external.
-type class () :: resource_unavailable | result_unexpected | result_unknown.
-type data  () :: _.

%%
%% API
%%
-spec make_error(source(), class(), data()) -> error().
make_error(Source, Class, Data) ->
    {Source, Class, Data}.

-spec is_error(error()) -> boolean().
is_error({Source, Class, _Data}) ->
    is_class(Class, is_source(Source));
is_error(_) ->
    false.

%%
%% Internal functions
%%
is_source(internal) ->
    true;
is_source(external) ->
    true;
is_source(_) ->
    false.

is_class(resource_unavailable, true) ->
    true;
is_class(result_unexpected, true) ->
    true;
is_class(result_unknown, true) ->
    true;
is_class(_, _) ->
    false.
