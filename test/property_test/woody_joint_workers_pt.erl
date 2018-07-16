-module(woody_joint_workers_pt).
-include_lib("proper/include/proper.hrl").
-compile(export_all).

prop_test() ->
    ?FORALL(
        Commands,
        % commands(?MODULE, initial_state()),
        parallel_commands(?MODULE, initial_state()),
        begin
            Pid = start_workers(),

            {History, State, Result} = run_parallel_commands(?MODULE, Commands),
            % {History, State, Result} = run_commands(?MODULE, Commands),

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
    Task =
        fun(_) ->
            timer:sleep(TaskSleepTimeout)
        end,
    catch woody_joint_workers:do(workers, {ID, Successfulness}, Task, woody_deadline:from_timeout(WorkerTimeout)).

% если уменьшать, то будут ложные срабатывания
-define(timeout_k, 5).
task_timeouts(success) ->
    {?timeout_k * 1, ?timeout_k * 3};
task_timeouts(fail) ->
    {?timeout_k * 3, ?timeout_k * 1}.

id() ->
    oneof(lists:seq(1, 3)).

command(_) ->
    frequency([
        {10, {call, ?MODULE, do, [id(), success]}},
        {1 , {call, ?MODULE, do, [id(), fail   ]}}
    ]).

initial_state() ->
    #{}.

precondition(_, _) ->
    true.

postcondition(_, {call, ?MODULE, do, [_, success]}, ok) ->
    true;
postcondition(_, {call, ?MODULE, do, [_, fail]}, {'EXIT', {deadline_reached, _}}) ->
    true;
postcondition(_, Call, Result) ->
    _ = ct:pal("~p ~p", [Call, Result]),
    false.

next_state(State, _, _) ->
    State.
