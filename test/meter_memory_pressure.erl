-module(meter_memory_pressure).

-type microseconds() :: non_neg_integer().
-type words() :: non_neg_integer().
-type metrics() :: #{
    minor_gcs := non_neg_integer(),
    minor_gcs_duration := microseconds(),
    major_gcs := non_neg_integer(),
    minor_gcs_duration := microseconds(),
    heap_reclaimed := words(),
    offheap_bin_reclaimed := words(),
    stack_min := words(),
    stack_max := words()
}.

-export([measure/2]).
-export([export/3]).

-export_type([metrics/0]).

%%

-type runner() :: fun(() -> _).
-type opts() :: #{
    iterations => pos_integer(),
    spawn_opts => [{atom(), _}],
    dump_traces => file:filename()
}.

-export_type([runner/0]).
-export_type([opts/0]).

-spec measure(runner(), opts()) -> metrics().
measure(Runner, Opts0) ->
    Opts = maps:merge(get_default_opts(), Opts0),
    Token = make_ref(),
    Tracer = start_tracer(Token, Opts),
    ok = run(Runner, Tracer, Opts),
    Metrics = collect_metrics(Tracer, Token),
    Metrics.

get_default_opts() ->
    #{
        iterations => 100,
        spawn_opts => [{fullsweep_after, 0}]
    }.

run(Runner, Tracer, Opts) ->
    SpawnOpts = [monitor, {priority, high}] ++ maps:get(spawn_opts, Opts),
    {Staging, MRef} = erlang:spawn_opt(
        fun() -> run_staging(Runner, Tracer, Opts) end,
        SpawnOpts
    ),
    receive
        {'DOWN', MRef, process, Staging, normal} ->
            ok
    end.

run_staging(Runner, Tracer, Opts) ->
    N = maps:get(iterations, Opts),
    TraceOpts = [garbage_collection, timestamp, {tracer, Tracer}],
    _ = erlang:trace(self(), true, TraceOpts),
    iterate(Runner, N).

iterate(Runner, N) when N > 0 ->
    _ = Runner(),
    iterate(Runner, N - 1);
iterate(_Runner, 0) ->
    ok.

%%

start_tracer(Token, Opts) ->
    Self = self(),
    erlang:spawn_link(fun() -> run_tracer(Self, Token, Opts) end).

collect_metrics(Tracer, Token) ->
    _ = Tracer ! Token,
    receive
        {?MODULE, {metrics, Metrics}} ->
            Metrics
    end.

run_tracer(MeterPid, Token, Opts) ->
    _ =
        receive
            Token -> ok
        end,
    Traces = collect_traces(),
    Metrics = analyze_traces(Traces),
    ok = maybe_dump_traces(Traces, Opts),
    MeterPid ! {?MODULE, {metrics, Metrics}}.

collect_traces() ->
    collect_traces([]).

collect_traces(Acc) ->
    receive
        {trace_ts, _Pid, Trace, Info, Clock} ->
            collect_traces([{Trace, Info, Clock} | Acc]);
        Unexpected ->
            error({unexpected, Unexpected})
    after 0 -> lists:reverse(Acc)
    end.

maybe_dump_traces(Traces, #{dump_traces := Filename}) ->
    file:write_file(Filename, erlang:term_to_binary(Traces));
maybe_dump_traces(_, #{}) ->
    ok.

analyze_traces(Traces) ->
    analyze_traces(Traces, #{
        minor_gcs => 0,
        minor_gcs_duration => 0,
        major_gcs => 0,
        major_gcs_duration => 0,
        heap_reclaimed => 0,
        offheap_bin_reclaimed => 0
    }).

analyze_traces([{gc_minor_start, InfoStart, C1}, {gc_minor_end, InfoEnd, C2} | Rest], M0) ->
    M1 = increment(minor_gcs, M0),
    M2 = increment(minor_gcs_duration, timer:now_diff(C2, C1), M1),
    analyze_traces(Rest, analyze_gc(InfoStart, InfoEnd, M2));
analyze_traces([{gc_major_start, InfoStart, C1}, {gc_major_end, InfoEnd, C2} | Rest], M0) ->
    M1 = increment(major_gcs, M0),
    M2 = increment(major_gcs_duration, timer:now_diff(C2, C1), M1),
    analyze_traces(Rest, analyze_gc(InfoStart, InfoEnd, M2));
analyze_traces([], M) ->
    M.

analyze_gc(InfoStart, InfoEnd, M0) ->
    M1 = increment(heap_reclaimed, difference(heap_size, InfoEnd, InfoStart), M0),
    M2 = increment(offheap_bin_reclaimed, difference(bin_vheap_size, InfoEnd, InfoStart), M1),
    M3 = update(stack_min, fun erlang:min/2, min(stack_size, InfoStart, InfoEnd), M2),
    M4 = update(stack_max, fun erlang:max/2, max(stack_size, InfoStart, InfoEnd), M3),
    M4.

difference(Name, Info1, Info2) ->
    combine(Name, fun(V1, V2) -> erlang:max(0, V2 - V1) end, Info1, Info2).

min(Name, Info1, Info2) ->
    combine(Name, fun erlang:min/2, Info1, Info2).

max(Name, Info1, Info2) ->
    combine(Name, fun erlang:max/2, Info1, Info2).

combine(Name, Fun, Info1, Info2) ->
    {_, V1} = lists:keyfind(Name, 1, Info1),
    {_, V2} = lists:keyfind(Name, 1, Info2),
    Fun(V1, V2).

increment(Name, Metrics) ->
    increment(Name, 1, Metrics).

increment(Name, Delta, Metrics) ->
    maps:update_with(Name, fun(V) -> V + Delta end, Metrics).

update(Name, Fun, I, Metrics) ->
    maps:update_with(Name, fun(V) -> Fun(V, I) end, I, Metrics).

%%

-spec export(file:filename(), file:filename(), csv) -> ok.
export(FilenameIn, FilenameOut, Format) ->
    {ok, Content} = file:read_file(FilenameIn),
    Traces = erlang:binary_to_term(Content),
    {ok, FileOut} = file:open(FilenameOut, [write, binary]),
    ok = format_traces(Traces, Format, FileOut),
    ok = file:close(FileOut).

format_traces(Traces, csv, FileOut) ->
    _ = format_csv_header(FileOut),
    _ = lists:foreach(fun(T) -> format_csv_trace(T, FileOut) end, Traces),
    ok.

format_csv_header(Out) ->
    Line = " ~s , ~s , ~s , ~s , ~s , ~s , ~s , ~s , ~s , ~s , ~s , ~s ~n",
    io:fwrite(Out, Line, [
        "Time",
        "End?",
        "Major?",
        "Stack",
        "Heap",
        "HeapBlock",
        "BinHeap",
        "BinHeapBlock",
        "OldHeap",
        "OldHeapBlock",
        "OldBinHeap",
        "OldBinHeapBlock"
    ]).

format_csv_trace({Event, Info, Clock}, Out) ->
    Line = " ~B , ~B , ~B , ~B , ~B , ~B , ~B , ~B , ~B , ~B , ~B , ~B ~n",
    io:fwrite(Out, Line, [
        clock_to_mcs(Clock),
        bool_to_integer(lists:member(Event, [gc_minor_end, gc_major_end])),
        bool_to_integer(lists:member(Event, [gc_major_start, gc_major_end])),
        get_info(stack_size, Info),
        get_info(heap_size, Info),
        get_info(heap_block_size, Info),
        get_info(bin_vheap_size, Info),
        get_info(bin_vheap_block_size, Info),
        get_info(old_heap_size, Info),
        get_info(old_heap_block_size, Info),
        get_info(bin_old_vheap_size, Info),
        get_info(bin_old_vheap_block_size, Info)
    ]).

get_info(Name, Info) ->
    {_Name, V} = lists:keyfind(Name, 1, Info),
    V.

clock_to_mcs({MSec, Sec, USec}) ->
    (MSec * 1000000 + Sec) * 1000000 + USec.

bool_to_integer(false) ->
    0;
bool_to_integer(true) ->
    1.
