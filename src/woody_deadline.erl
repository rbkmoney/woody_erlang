%%% @doc Woody context API
%%% @end

-module(woody_deadline).

%% API
-export([is_reached/1]).
-export([to_timeout/1]).
-export([from_timeout/1]).
-export([to_binary/1]).
-export([from_binary/1]).
-export([to_unixtime_ms/1]).
-export([from_unixtime_ms/1]).
-export([unow/0]).

%% Types
-type millisec() :: 0..1000.
%% deadline may be not set for a request,
-type deadline() :: {calendar:datetime(), millisec()} | undefined.

%% that's why  'undefined' is here as well.
-export_type([deadline/0, millisec/0]).

%%
%% API
%%
-spec is_reached(deadline()) -> boolean().
is_reached(undefined) ->
    false;
is_reached(Deadline) ->
    unow() >= to_unixtime_ms(Deadline).

-spec to_timeout(deadline()) -> timeout().
to_timeout(undefined) ->
    infinity;
to_timeout(Deadline) ->
    case to_unixtime_ms(Deadline) - unow() of
        Timeout when Timeout > 0 ->
            Timeout;
        _ ->
            erlang:error(deadline_reached, [Deadline])
    end.

-spec from_timeout(timeout()) -> deadline().
from_timeout(infinity) ->
    undefined;
from_timeout(TimeoutMillisec) ->
    DeadlineMillisec = unow() + TimeoutMillisec,
    from_unixtime_ms(DeadlineMillisec).

-spec to_binary(deadline()) -> binary().
to_binary(Deadline = undefined) ->
    erlang:error(bad_deadline, [Deadline]);
to_binary(Deadline) ->
    try
        Millis = to_unixtime_ms(Deadline),
        Str = calendar:system_time_to_rfc3339(Millis, [{unit, millisecond}, {offset, "Z"}]),
        erlang:list_to_binary(Str)
    catch
        error:Error:Stacktrace ->
            erlang:error({bad_deadline, {Error, Stacktrace}}, [Deadline])
    end.

-spec from_binary(binary()) -> deadline().
from_binary(Bin) ->
    ok = assert_is_utc(Bin),
    Str = erlang:binary_to_list(Bin),
    try
        Millis = calendar:rfc3339_to_system_time(Str, [{unit, millisecond}]),
        Datetime = calendar:system_time_to_universal_time(Millis, millisecond),
        {Datetime, Millis rem 1000}
    catch
        error:Error ->
            erlang:error({bad_deadline, Error}, [Bin])
    end.

-spec to_unixtime_ms(deadline()) -> non_neg_integer().
to_unixtime_ms({DateTime, Millisec}) ->
    genlib_time:daytime_to_unixtime(DateTime) * 1000 + Millisec.

-spec from_unixtime_ms(non_neg_integer()) -> deadline().
from_unixtime_ms(DeadlineMillisec) ->
    {genlib_time:unixtime_to_daytime(DeadlineMillisec div 1000), DeadlineMillisec rem 1000}.

%%
%% Internal functions
%%

-spec assert_is_utc(binary()) -> ok | no_return().
assert_is_utc(Bin) ->
    Size0 = erlang:byte_size(Bin),
    Size1 = Size0 - 1,
    Size6 = Size0 - 6,
    case Bin of
        <<_:Size1/bytes, "Z">> ->
            ok;
        <<_:Size6/bytes, "+00:00">> ->
            ok;
        <<_:Size6/bytes, "-00:00">> ->
            ok;
        _ ->
            erlang:error({bad_deadline, not_utc}, [Bin])
    end.

-spec unow() -> millisec().
unow() ->
    % We must use OS time for communications with external systems
    % erlang:system_time/1 may have a various difference with global time to prevent time warp.
    % see http://erlang.org/doc/apps/erts/time_correction.html#time-warp-modes for details
    os:system_time(millisecond).
