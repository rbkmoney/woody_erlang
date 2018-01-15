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
-type deadline() :: {calendar:datetime(), millisec()} | undefined.
-export_type([deadline/0, millisec/0]).

%%
%% API
%%
-spec reached(deadline()) ->
    boolean().
reached(undefined) ->
    false;
reached(Deadline) ->
    unow() >= to_unixtime(Deadline).

-spec to_timeout(deadline()) ->
    timeout().
to_timeout(Deadline = undefined) ->
    erlang:error(bad_deadline, [Deadline]);
to_timeout(Deadline) ->
    case to_unixtime(Deadline) - unow() of
        Timeout when Timeout > 0 ->
            Timeout;
        _ ->
            erlang:error(deadline_reached, [Deadline])
    end.

-spec from_timeout(millisec()) ->
    deadline().
from_timeout(TimeoutMillisec) ->
    DeadlineSec = unow() + TimeoutMillisec,
    {genlib_time:unixtime_to_daytime(DeadlineSec div 1000), DeadlineSec rem 1000}.

-spec to_binary(deadline()) ->
    binary().
to_binary(Deadline = undefined) ->
    erlang:error(bad_deadline, [Deadline]);
to_binary(Deadline = {{Date, Time}, Millisec}) ->
    try rfc3339:format({Date, Time, Millisec * 1000, 0}) of
        {ok, DeadlineBin} when is_binary(DeadlineBin) ->
            DeadlineBin;
        Error ->
            %% rfc3339:format/1 has a broken spec and ugly (if not to say broken) code,
            %% so just throw any non succeess case here.
            erlang:error({bad_deadline, Error}, [Deadline])
    catch
        error:Error ->
            erlang:error({bad_deadline, {Error, erlang:get_stacktrace()}}, [Deadline])
    end.

-spec from_binary(binary()) ->
    deadline().
from_binary(Bin) ->
    case rfc3339:parse(Bin) of
        {ok, {Date, Time, Usec, TZ}} when TZ =:= 0 orelse TZ =:= undefined ->
            {to_calendar_datetime(Date, Time), Usec div 1000};
        {ok, _} ->
            erlang:error({bad_deadline, not_utc}, [Bin]);
        {error, Error} ->
            erlang:error({bad_deadline, Error}, [Bin])
    end.

%%
%% Internal functions
%%
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
