-module(bench_woody_formatter).

%% API
-export([
    iolib_formatter/1,
    bench_iolib_formatter/2,
    thrift_formatter/1,
    bench_thrift_formatter/2
]).

-type input() :: term().

-spec input() -> input().
input() ->
    %% NOTE
    %% You will need some reasonably complex term following `domain_config.Snapshot` thrift schema
    %% stored in ETF in `test/snapshot.term` for this benchmark to run. It's NOT supplied by
    %% default.
    {ok, Bin} = file:read_file("test/snapshot.term"),
    erlang:binary_to_term(Bin).

-spec iolib_formatter({input, _State}) -> input().
iolib_formatter({input, _}) ->
    input().

-spec thrift_formatter({input, _State}) -> input().
thrift_formatter({input, _}) ->
    input().

-spec bench_iolib_formatter(input(), _State) -> term().
bench_iolib_formatter(Snapshot, _) ->
    format_msg({"~0tp", [Snapshot]}).

-spec bench_thrift_formatter(input(), _State) -> term().
bench_thrift_formatter(Snapshot, _) ->
    Service = dmsl_domain_config_thrift,
    format_msg(woody_event_formatter:format_reply(Service, 'Repository', 'Checkout', Snapshot, #{})).

format_msg({Format, Params}) ->
    io_lib:format(Format, Params).
