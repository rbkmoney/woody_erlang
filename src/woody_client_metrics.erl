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
    ok.

-spec delete(any()) -> ok.
delete(_) ->
    ok.

-spec increment_counter(any()) -> ok | {error, term()}.
increment_counter(Key) ->
    increment_counter(Key, 1).

-spec increment_counter(any(), number()) -> ok | {error, term()}.
increment_counter([hackney, _Host, _], _) ->
    % we don't need per host metrics
    ok;
increment_counter(Key, Value) ->
    update_metric(counter, Key, Value).

-spec decrement_counter(any()) -> ok | {error, term()}.
decrement_counter(Key) ->
    decrement_counter(Key, 1).

-spec decrement_counter(any(), number()) -> ok | {error, term()}.
decrement_counter(Key, Value) ->
    increment_counter(Key, -Value).

-spec update_histogram(any(), number() | function()) -> ok | {error, term()}.
update_histogram(Key, Value) ->
    update_metric(histogram, Key, Value).

-spec update_gauge(any(), number()) -> ok | {error, term()}.
update_gauge(Key, Value) ->
    update_metric(gauge, Key, Value).

-spec update_meter(any(), number()) -> ok | {error, term()}.
update_meter(Key, Value) ->
    update_metric(meter, Key, Value).

%% internals
update_metric(meter, _, _) ->
    {error, not_allowed};
update_metric(histogram, _, Value) when is_function(Value) ->
    {error, not_allowed};
update_metric(histogram, Key, Value) ->
    update_metric(gauge, Key, Value);
update_metric(Type, Key0, Value) ->
    case is_allowed_metric(Key0) of
        true ->
            Key = map_key(Key0),
            hay_metrics:push(hay_metrics:construct(Type, tag_key(Key), Value));
        false ->
            {error, not_allowed}
    end.

tag_key(Key) when is_list(Key) ->
    [woody, client | Key].

is_allowed_metric([hackney_pool, _, Metric]) ->
    lists:member(Metric, get_allowed_pool_metrics());
is_allowed_metric(Key) ->
    lists:member(Key, get_allowed_request_metrics()).

map_key(Key) ->
    case maps:get(Key, get_key_mapping(), undefined) of
        undefined ->
            Key;
        MappedKey ->
            MappedKey
    end.

% gets

get_key_mapping() ->
    maps:get(metric_key_mapping, get_options(), #{}).

get_allowed_request_metrics() ->
    [
        [hackney, total_requests],
        [hackney, finished_requests],
        [hackney, nb_requests]
    ].

get_allowed_pool_metrics() ->
    [free_count, no_socket, in_use_count, queue_counter].

get_options() ->
    genlib_app:env(woody, woody_client_metrics_options, #{}).
