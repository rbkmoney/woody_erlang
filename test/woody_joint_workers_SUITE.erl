-module(woody_joint_workers_SUITE).
-include_lib("common_test/include/ct.hrl").

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([prop_test/1]).

%%
%% tests descriptions
%%
all() ->
    [
        prop_test
    ].

%%
%% starting/stopping
%%
init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({woody_joint_workers, do, 4}, x),

    {ok, Apps} = application:ensure_all_started(woody),
    [{apps, Apps}|C].

end_per_suite(C) ->
    [application:stop(App) || App <- ?config(apps, C)].

%%
%% tests
%%
prop_test(_C) ->
    R = proper:quickcheck(
            woody_joint_workers_pt:prop_test(),
            [noshrink] % default options
        ),
    case R of
        true  -> ok;
        Error -> exit(Error)
    end.
