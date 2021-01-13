%%% @doc Error handling API
%%% @end

-module(woody_error).

-export([raise/2]).
-export([format_details/1]).

%% API

%% Types
-export_type([error/0, business_error/0, system_error/0]).
-export_type([type/0, source/0, class/0, details/0]).

-type type() :: business | system.
-type error() ::
    {business, business_error()}
    | {system, system_error()}.

-type business_error() :: _Error.
-type system_error() :: {source(), class(), details()}.

-type source() :: internal | external.
-type class() :: resource_unavailable | result_unexpected | result_unknown.
-type details() :: binary().

-type erlang_except() :: throw | error | exit.
-type stack() :: list().

-export_type([erlang_except/0, stack/0]).

%%
%% API
%%
-spec raise(type(), business_error() | system_error()) -> no_return().
raise(business, Except) ->
    erlang:throw(Except);
raise(system, {Source, Class, Details}) ->
    erlang:error({woody_error, {Source, Class, Details}}).

-spec format_details(term()) -> details().
format_details(Error) ->
    genlib:to_binary(io_lib:format("~9999p", [Error])).
