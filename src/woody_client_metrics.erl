-module(woody_client_metrics).

% api
-export([new/2]).
-export([delete/1]).
-export([increment_counter/1]).
-export([increment_counter/2]).
-export([decrement_counter/1]).
-export([decrement_counter/2]).
-export([update_histogram/2]).
-export([update_gauge/2]).
-export([update_meter/2]).

% -type metric() :: metrics:metric().
-type metric() :: counter | histogram | gauge | meter.

-spec new(metric(), any()) -> ok | {error, term()}.
new(_, _) ->
    ok. % we can omit it

-spec delete(any()) -> ok.
delete(_) ->
    ok.

-spec increment_counter(any()) -> ok | {error, term()}.
increment_counter(Key) ->
    increment_counter(Key, 1).

-spec increment_counter(any(), number()) -> ok | {error, term()}.
increment_counter([hackney, _Host, _], _) ->
    ok; % we don't need per host metrics
increment_counter([hackney, nb_requests], Value) ->
    increment_counter([hackney, requests_in_process], Value);
increment_counter(Key, Value) ->
    case validate_metric(Key) of
        true ->
            hay_metrics:push(hay_metrics:construct(counter, tag_key(Key), Value));
        false ->
            {error, not_allowed}
    end.

-spec decrement_counter(any()) -> ok | {error, term()}.
decrement_counter(Key) ->
    decrement_counter(Key, 1).

-spec decrement_counter(any(), number()) -> ok | {error, term()}.
decrement_counter(Key, Value) ->
    increment_counter(Key, -Value).

-spec update_histogram(any(), number() | function()) -> ok | {error, term()}.
update_histogram(_, Func)  when is_function(Func) ->
    {error, not_allowed};
update_histogram(Key, Value) ->
    update_gauge(Key, Value).

-spec update_gauge(any(), number()) -> ok | {error, term()}.
update_gauge(Key, Value) ->
    case validate_metric(Key) of
        true ->
            hay_metrics:push(hay_metrics:construct(gauge, tag_key(Key), Value));
        false ->
            {error, not_allowed}
    end.

-spec update_meter(any(), number()) -> ok | {error, term()}.
update_meter(_, _) ->
    {error, not_allowed}.

%% internals

tag_key(Key) when is_list(Key) ->
    [woody, client | Key];
tag_key(Key) ->
    [woody, client, Key].

validate_metric(Key) ->
    is_allowed_metric(lists:last(Key)).

is_allowed_metric(Key) ->
    lists:member(Key, get_allowed_metrics()).

% gets

get_allowed_metrics() ->
    maps:get(allowed_metrics, get_options(), []).

get_options() ->
    genlib_app:env(woody, woody_client_metrics_options, #{}).
