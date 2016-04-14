%%% @doc Server API
%%% @end

-module(rpc_server).

-behaviour(supervisor).

%% API
-export([child_spec/2]).

%% supervisor callbacks
-export([init/1]).

%%
%% behaviour definition
%%
-callback child_spec(_Id, options()) -> supervisor:child_spec().

%%
%% API
%%
-type options() :: #{
    protocol => thrift, %% optional
    transport => http %% optional
}.

-spec child_spec(_Id, options()) -> supervisor:child_spec().
child_spec(Id, Options) ->
    ProtocolHandler = rpc_t:get_protocol_handler(server, Options),
    ServerSpec = ProtocolHandler:child_spec(Id, Options),
    #{
        id => Id,
        start => {supervisor, start_link, [?MODULE, {rpc_server, ServerSpec}]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [?MODULE]
    }.

%%
%% Supervisor callbacks
%%
-spec init({rpc_server, supervisor:child_spec()}) -> {ok, {#{}, [#{}, ...]}}.
init({rpc_server, ChildSpec}) ->
    {ok, {#{
        strategy => one_for_one,
        intensity => 10,
        period => 10},
    [ChildSpec]}
}.
