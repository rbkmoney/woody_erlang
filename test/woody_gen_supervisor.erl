-module(woody_gen_supervisor).

%% API
-export([start_link/1]).
-export([start_link/2]).

%% supervisor
-behaviour(supervisor).
-export([init/1]).

%% API
-spec start_link([supervisor:child_spec()]) ->
    {ok, pid()}.
start_link(ChildsSpecs) ->
    start_link(#{}, ChildsSpecs).

-spec start_link(supervisor:sup_flags(), [supervisor:child_spec()]) ->
    {ok, pid()}.
start_link(Flags, ChildsSpecs) ->
    supervisor:start_link(?MODULE, {Flags, ChildsSpecs}).

%%
%% supervisor callbacks
%%
-spec init({supervisor:sup_flags(), [supervisor:child_spec()]}) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init({Flags, ChildsSpecs}) ->
    {ok, {Flags, ChildsSpecs}}.
