%%% @doc Server API
%%% @end

-module(woody_server).

%% API
-export([child_spec/2]).
-export([get_addr/2]).

%% Types
-type options() :: #{
    event_handler := woody:ev_handlers(),
    protocol => thrift,
    transport => http,
    %% Set to override protocol handler module selection, useful for test purposes, rarely
    %% if ever needed otherwise.
    protocol_handler_override => module(),
    %% Implementation-specific options
    _ => _
}.

-export_type([options/0]).

%% Behaviour definition
-callback child_spec(_Id, options()) -> supervisor:child_spec().
-callback get_addr(_Id) -> {inet:ip_address(), inet:port_number()}.

%%
%% API
%%
-spec child_spec(_Id, options()) -> supervisor:child_spec().
child_spec(Id, Options) ->
    ProtocolHandler = woody_util:get_protocol_handler(server, Options),
    ProtocolHandler:child_spec(Id, Options).

-spec get_addr(_Id, options()) -> {inet:ip_address(), inet:port_number()}.
get_addr(Id, Options) ->
    ProtocolHandler = woody_util:get_protocol_handler(server, Options),
    ProtocolHandler:get_addr(Id).
