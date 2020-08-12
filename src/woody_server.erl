%%% @doc Server API
%%% @end

-module(woody_server).

%% API
-export([child_spec/2]).

%% Types
-type options() :: #{
    event_handler         := woody:ev_handlers(),
    protocol              => thrift,
    transport             => http
}.
-export_type([options/0]).

%% Behaviour definition
-callback child_spec(_Id, options()) -> supervisor:child_spec().

%%
%% API
%%
-spec child_spec(_Id, options()) ->
    supervisor:child_spec().
child_spec(Id, Options) ->
    ProtocolHandler = woody_util:get_protocol_handler(server, Options),
    ProtocolHandler:child_spec(Id, Options).
