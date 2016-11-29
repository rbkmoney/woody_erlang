%%% @doc Client API
%%% @end

-module(woody_error).

%% API

%% Types
-export_type([error/0, business_error/0, system_error/0]).
-export_type([source/0, class/0, details/0]).

-type error() ::
    {business, business_error()} |
    {system,   system_error()}.

-type business_error() :: _Error.
-type system_error  () :: {source(), class(), details()}.

-type source () :: internal | external.
-type class  () :: resource_unavailable | result_unexpected | result_unknown.
-type details() :: binary().
