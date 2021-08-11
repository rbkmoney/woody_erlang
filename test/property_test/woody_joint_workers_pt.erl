-module(woody_joint_workers_pt).

-include_lib("proper/include/proper.hrl").

-export([
    prop_test/0,
    start_workers/0,
    stop_workers/1,
    do/2,
    task_timeouts/1,
    id/0,
    command/1,
    initial_state/0,
    precondition/2,
    postcondition/3,
    next_state/3
]).

-type state() :: #{}.
-type successfulness() :: success | fail.
-type id_t() :: non_neg_integer().

-spec prop_test() -> any().
-spec start_workers() -> pid().
-spec stop_workers(pid()) -> ok.
-spec do(id_t(), successfulness()) -> any().
-spec task_timeouts(successfulness()) -> {timeout(), timeout()}.
-spec id() -> proper_types:type().
-spec command(any()) -> any().
-spec initial_state() -> state().
-spec precondition(any(), any()) -> boolean().
-spec postcondition(any(), any(), any()) -> boolean().
-spec next_state(state(), any(), any()) -> state().

%% проверяет работоспособность в условиях параллельных запросов,
%% но по факту не может проверить, что запросы действительно соединяются

%% Suppress proper's internal type mismatch for setup generator
-dialyzer([no_return, no_opaque]).
prop_test() ->
    ?FORALL(
        Commands,
        parallel_commands(?MODULE, initial_state()),
        begin
            Pid = start_workers(),
            {History, State, Result} = run_parallel_commands(?MODULE, Commands),
            ok = stop_workers(Pid),

            ?WHENFAIL(
                ct:pal("History: ~p~nState: ~p~nResult: ~p~n", [History, State, Result]),
                aggregate(command_names(Commands), Result =:= ok)
            )
        end
    ).

start_workers() ->
    genlib:unwrap(woody_joint_workers:start_link({local, workers})).

stop_workers(Pid) ->
    true = unlink(Pid),
    true = exit(Pid, kill),
    ok.

%%

do(ID, Successfulness) ->
    % тестовый таск спит небольшое время
    % дедлайн ставится либо до, либо после него
    {TaskSleepTimeout, WorkerTimeout} = task_timeouts(Successfulness),
    Task = fun(_) ->
        ok = timer:sleep(TaskSleepTimeout),
        {ok, ID}
    end,
    catch woody_joint_workers:do(workers, {ID, Successfulness}, Task, woody_deadline:from_timeout(WorkerTimeout)).

% если уменьшать, то могут быть ложные срабатывания
-define(timeout_k, 20).

task_timeouts(success) ->
    {?timeout_k * 1, ?timeout_k * 3};
task_timeouts(fail) ->
    {?timeout_k * 3, ?timeout_k * 1}.

id() ->
    oneof(lists:seq(1, 3)).

command(_) ->
    frequency([
        {10, {call, ?MODULE, do, [id(), success]}},
        {1, {call, ?MODULE, do, [id(), fail]}}
    ]).

initial_state() ->
    #{}.

precondition(_, _) ->
    true.

postcondition(_, {call, ?MODULE, do, [ID, success]}, {ok, ID}) ->
    true;
postcondition(_, {call, ?MODULE, do, [_, fail]}, {'EXIT', {deadline_reached, _}}) ->
    true;
postcondition(_, Call, Result) ->
    _ = ct:pal("~p ~p", [Call, Result]),
    false.

next_state(State, _, _) ->
    State.
