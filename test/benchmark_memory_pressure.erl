-module(benchmark_memory_pressure).

-export([run/0]).

-spec run() ->
    ok.
run() ->
    Input = input(),
    Opts = #{iterations => 10},
    _ = run(iolib, mk_iolib_runner(Input), Opts),
    _ = run(thrift, mk_thrift_runner(Input), Opts),
    ok.

-spec run(atom(), meter_memory_pressure:runner(), meter_memory_pressure:opts()) ->
    ok.
run(Name, Runner, Opts) ->
    _ = io:format("Benchmarking '~s' memory pressure...~n", [Name]),
    _ = io:format("====================================~n", []),
    Metrics = meter_memory_pressure:measure(Runner, Opts),
    lists:foreach(
        fun (Metric) ->
            io:format("~24s = ~-16b~n", [Metric, maps:get(Metric, Metrics)])
        end,
        [
            minor_gcs,
            minor_gcs_duration,
            major_gcs,
            major_gcs_duration,
            heap_reclaimed,
            offheap_bin_reclaimed,
            stack_min,
            stack_max
        ]
    ),
    _ = io:format("====================================~n~n", []),
    ok.

-spec input() ->
    term().
input() ->
    {ok, Binary} = file:read_file("test/snapshot.term"),
    erlang:binary_to_term(Binary).

-spec mk_iolib_runner(term()) ->
    meter_memory_pressure:runner().
mk_iolib_runner(Snapshot) ->
    fun () ->
        bench_woody_formatter:bench_iolib_formatter(Snapshot, [])
    end.

-spec mk_thrift_runner(term()) ->
    meter_memory_pressure:runner().
mk_thrift_runner(Snapshot) ->
    fun () ->
        bench_woody_formatter:bench_thrift_formatter(Snapshot, [])
    end.
