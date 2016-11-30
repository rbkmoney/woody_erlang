%%% @doc Server API
%%% @end

-module(woody_server).

%% API
-export([child_spec/2]).

%%
%% behaviour definition
%%
-callback child_spec(_Id, options()) -> supervisor:child_spec().

%%
%% API
%%
-type options() :: #{
    protocol  => thrift, %% optional
    transport => http %% optional
}.

-spec child_spec(_Id, options()) -> supervisor:child_spec().
child_spec(Id, Options) ->
    ProtocolHandler = woody:get_protocol_handler(server, Options),
    ProtocolHandler:child_spec(Id, Options).
