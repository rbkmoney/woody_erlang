-module(woody_joint_workers).

%% API
-export([child_spec/2]).
-export([start_link/1]).
-export([do/4]).

%% Internal API
-export([worker_start_link/3]).
-export([worker/4]).

-type deadline() :: woody_deadline:deadline().
-type task(Result) :: fun((deadline()) -> Result).
-type id() :: _.

%%
%% API
%%
-spec child_spec(atom(), genlib_gen:reg_name()) ->
    supervisor:child_spec().
child_spec(ChildID, RegName) ->
    #{
        id       => ChildID,
        start    => {?MODULE, start_link, [RegName]},
        restart  => permanent,
        type     => supervisor
    }.

-spec start_link(genlib_gen:reg_name()) ->
    genlib_gen:start_ret().
start_link(RegName) ->
    genlib_adhoc_supervisor:start_link(
        RegName,
        #{strategy => simple_one_for_one},
        [worker_child_spec(worker)]
    ).

-spec do(genlib_gen:ref(), id(), task(Result), deadline()) ->
    Result.
do(Ref, ID, Task, Deadline) ->
    do(Ref, ID, Task, Deadline, 10).

%%
%% Internal API
%%
-spec worker_child_spec(atom()) ->
    supervisor:child_spec().
worker_child_spec(ChildID) ->
    #{
        id       => ChildID,
        start    => {?MODULE, worker_start_link, []},
        restart  => temporary,
        type     => worker
    }.

-spec worker_start_link(id(), task(_), deadline()) ->
    genlib_gen:start_ret().
worker_start_link(ID, Task, Deadline) ->
    proc_lib:start_link(?MODULE, worker, [ID, self(), Task, Deadline], deadline_to_timeout(Deadline)).

-spec worker(id(), pid(), task(_), deadline()) ->
    ok.
worker(ID, Parent, Task, Deadline) ->
    Self = self(),
    case gproc:reg_or_locate({n, l, ID}) of
        {Self, undefined} ->
            ok = proc_lib:init_ack(Parent, {ok, Self}),
            _ = genlib:unwrap(timer:exit_after(deadline_to_timeout(Deadline), self(), deadline_reached)),
            Result = Task(Deadline),
            ok = broadcast_result(Result);
        {Pid, undefined} ->
            ok = proc_lib:init_ack(Parent, {ok, Pid})
    end.

%%
%% local
%%
-spec do(genlib_gen:ref(), id(), task(Result), deadline(), non_neg_integer()) ->
    Result.
do(Ref, ID, Task, Deadline, 0) ->
    erlang:error(retrying_error, [Ref, ID, Task, Deadline]);
do(Ref, ID, Task, Deadline, Attmpts) ->
    Pid = genlib:unwrap(supervisor:start_child(Ref, [ID, Task, Deadline])),
    case wait_for_result(Pid, Deadline) of
        {ok, R} ->
            R;
        {error, race_detected} ->
            timer:sleep(1),
            do(Ref, ID, Task, Deadline, Attmpts - 1);
        {error, deadline_reached} ->
            % тут довольно спорный момент, как себя правильно вести в случае,
            % когда соединяются запросы с разными дедлайнами
            case woody_deadline:is_reached(Deadline) of
                false -> do(Ref, ID, Task, Deadline);
                true  -> erlang:error(deadline_reached, [Ref, ID, Task, Deadline])
            end;
        {error, Error} ->
            erlang:error(Error, [Ref, ID, Task, Deadline])
    end.

-spec wait_for_result(pid(), deadline()) ->
    {ok, _Result} | {error, deadline_reached | race_detected | {worker_error, _Reason}}.
wait_for_result(Pid, Deadline) ->
    Timeout = deadline_to_timeout(Deadline),
    MRef = erlang:monitor(process, Pid),
    Pid ! {?MODULE, wait_for_result, MRef, self()},
    receive
        {?MODULE, broadcast_result, MRef, Result} ->
            erlang:demonitor(MRef, [flush]),
            {ok, Result};
        %% произошла гонка
        {'DOWN', MRef, process, Pid, Reason}
            when Reason =:= normal; Reason =:= noproc ->
            {error, race_detected};
        %% упал воркер по таймауту
        {'DOWN', MRef, process, Pid, deadline_reached} ->
            {error, deadline_reached};
        %% упал воркер
        {'DOWN', MRef, process, Pid, Reason} ->
            {error, {worker_error, Reason}}
    after Timeout ->
        _ = erlang:demonitor(MRef, [flush]),
        {error, deadline_reached}
    end.

-spec broadcast_result(_Result) ->
    ok.
broadcast_result(Result) ->
    receive
        {?MODULE, wait_for_result, MRef, Pid} ->
            Pid ! {?MODULE, broadcast_result, MRef, Result},
            broadcast_result(Result)
    after 0 ->
        ok
    end.

-spec deadline_to_timeout(deadline()) ->
    timeout().
deadline_to_timeout(Deadline) ->
    try
        woody_deadline:to_timeout(Deadline)
    catch
        error:deadline_reached ->
            0
    end.
