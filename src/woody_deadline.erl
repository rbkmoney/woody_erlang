%%% @doc Woody context API
%%% @end

-module(woody_deadline).

%% API
-export([reached/1]).
-export([to_timeout/1]).
-export([from_timeout/1]).
-export([to_binary/1]).
-export([from_binary/1]).

%% Types
-type millisec() :: 0..1000.
-type deadline() :: {calendar:datetime(), millisec()}.
-export_type([deadline/0, millisec/0]).

%%
%% API
%%
-spec reached(deadline()) ->
    boolean().
reached(Deadline) ->
    unow() >= to_unixtime(Deadline).

-spec to_timeout(deadline()) ->
    timeout().
to_timeout(Deadline) ->
    case to_unixtime(Deadline) - unow() of
        Timeout when Timeout > 0 ->
            Timeout;
        _ ->
            erlang:error(deadline_reached)
    end.

-spec from_timeout(millisec()) ->
    deadline().
from_timeout(TimeoutMillisec) ->
    DeadlineSec = unow() + TimeoutMillisec,
    {genlib_time:unixtime_to_daytime(DeadlineSec div 1000), DeadlineSec rem 1000}.

-spec to_binary(deadline()) ->
    {ok, binary()} | {error, rfc3339:error()}.
to_binary({{Date, Time}, Millisec}) ->
    rfc3339:format({Date, Time, Millisec * 1000, 0}).

-spec from_binary(binary()) ->
    {ok, deadline()} | {error, not_utc | rfc3339:error()}.
from_binary(Bin) ->
    case rfc3339:parse(Bin) of
        {ok, {Date, Time, Usec, TZ}} when TZ =:= 0 orelse TZ =:= undefined ->
            {ok, {to_calendar_datetime(Date, Time), Usec div 1000}};
        {ok, _} ->
            {error, not_utc};
        Error = {error, _} ->
            Error
    end.

%%
%% Internal functions
%%
-spec to_unixtime(deadline()) ->
    millisec().
to_unixtime({DateTime, Millisec}) ->
    genlib_time:daytime_to_unixtime(DateTime)*1000 + Millisec.

-spec unow() ->
    millisec().
unow() ->
    erlang:system_time(millisecond).

to_calendar_datetime(Date, Time = {H, _, S}) when H =:= 24 orelse S =:= 60 ->
    %% Type specifications for hours and seconds differ in calendar and rfc3339,
    %% so make a proper calendar:datetime() here.
    Sec = calendar:datetime_to_gregorian_seconds({Date, Time}),
    calendar:gregorian_seconds_to_datetime(Sec);
to_calendar_datetime(Date, Time) ->
    {Date, Time}.
