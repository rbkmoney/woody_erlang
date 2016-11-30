%%% @doc Client API
%%% @end

-module(woody_error).

-export([raise/3]).

%% API

%% Types
-export_type([error/0, business_error/0, system_error/0]).
-export_type([source/0, class/0, details/0]).

-type error() ::
    {business , business_error()} |
    {system   , system_error  ()}.

-type business_error() :: _Error.
-type system_error  () :: {source(), class(), details()}.

-type source () :: internal | external.
-type class  () :: resource_unavailable | result_unexpected | result_unknown.
-type details() :: binary().

-spec raise(source(), class(), details()) -> no_return().
raise(Source, Class, Details) ->
    erlang:error({woody_error, {Source, Class, Details}}).
