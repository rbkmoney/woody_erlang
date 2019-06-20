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
new(histogram, Key) ->
    new(gauge, Key); % so far we don't want histograms
new(meter, _) ->
    {error, not_allowed};
new(Type, Key) ->
    case validate_metric(Key) of
        true ->
            hay_metrics:register(hay_metrics:construct(Type, Key, 0));
        false ->
            {error, not_allowed}
    end.

-spec delete(any()) -> ok.
delete(_) ->
    ok. % Can't we delete metrics in HAY?

-spec increment_counter(any()) -> ok | {error, term()}.
increment_counter(Key) ->
    increment_counter(Key, 1).

-spec increment_counter(any(), number()) -> ok | {error, term()}.
increment_counter(Key, Value) ->
    case validate_metric(Key) of
        true ->
            hay_metrics:push(hay_metrics:construct(counter, Key, Value));
        false ->
            {error, not_allowed}
    end.

-spec decrement_counter(any()) -> ok | {error, term()}.
decrement_counter(Key) ->
    decrement_counter(Key, 1).

-spec decrement_counter(any(), number()) -> ok | {error, term()}.
decrement_counter(Key, Value) ->
    increment_counter(Key, -Value). % Should work tho

-spec update_histogram(any(), number() | function()) -> ok | {error, term()}.
update_histogram(_, Func)  when is_function(Func) ->
    {error, not_allowed};
update_histogram(Key, Value) ->
    update_gauge(Key, Value).

-spec update_gauge(any(), number()) -> ok | {error, term()}.
update_gauge(Key, Value) ->
    case validate_metric(Key) of
        true ->
            hay_metrics:push(hay_metrics:construct(gauge, Key, Value));
        false ->
            {error, not_allowed}
    end.

-spec update_meter(any(), number()) -> ok | {error, term()}.
update_meter(_, _) ->
    {error, not_allowed}.


%% internals

validate_metric([hackney, Host, Metric]) ->
    is_allowed_host(Host) andalso validate_metric([hackney, Metric]);
validate_metric([hackney_pool, Pool, Metric]) ->
    is_allowed_pool(Pool) andalso is_allowed_metric(Metric);
validate_metric([_, Metric]) ->
    is_allowed_metric(Metric).

% is_allowed_*

is_allowed_pool(Host) ->
    case get_allowed_pools() of
        '*' -> true;
        Allowed -> lists:member(Host, Allowed)
    end.

is_allowed_host(Host) ->
    case get_allowed_hosts() of
        '*' -> true;
        Allowed -> lists:member(Host, Allowed)
    end.

is_allowed_metric(Key) ->
    lists:member(Key, get_allowed_metrics()).

% gets

% maybe we shouldn't access env so frequently?
get_allowed_pools() ->
    maps:get(allowed_pools, get_options(), []).

get_allowed_hosts() ->
    maps:get(allowed_hosts, get_options(), []).

get_allowed_metrics() ->
    maps:get(allowed_metrics, get_options(), []).

get_options() ->
    genlib_app:env(woody, woody_client_metrics_options, #{}).
