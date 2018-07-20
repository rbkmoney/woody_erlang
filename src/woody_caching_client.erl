-module(woody_caching_client).

%% API
-export_type([cache_control/0]).
-export([child_spec/2]).
-export([start_link/1]).
-export([call      /3]).
-export([call      /4]).

%% Internal API
-export([do_call/4]).

%%
%% API
%%
-type cache_control() :: lru | {stale, timeout()} | no_cache.

-spec child_spec(atom(), options()) ->
    supervisor:child_spec().
child_spec(ChildID, Options) ->
    #{
        id       => ChildID,
        start    => {?MODULE, start_link, [Options]},
        restart  => permanent,
        type     => supervisor
    }.

-spec start_link(options()) ->
    genlib_gen:start_ret().
start_link(Options) ->
    genlib_adhoc_supervisor:start_link(
        #{strategy => one_for_one},
        [
            woody_joint_workers:child_spec(joint_workers, workers_reg_name(Options)),
            woody_stale_cache:child_spec(stale_cache, stale_cache_options(Options)),
            lru_cache_child_spec(lru_cache, Options),
            woody_client:child_spec(woody_client_options(Options))
        ]
    ).

-spec call(woody:request(), cache_control(), options()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, CacheControl, Options) ->
    call(Request, CacheControl, Options, woody_context:new()).

-spec call(woody:request(), cache_control(), options(), woody_context:ctx()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, CacheControl, Options, Context) ->
    Task =
        fun(_) ->
            do_call(Request, CacheControl, Options, Context)
        end,
    woody_joint_workers:do(workers_ref(Options), Request, Task, woody_context:get_deadline(Context)).

%%
%% Internal API
%%
-spec do_call(woody:request(), cache_control(), options(), woody_context:ctx()) ->
      {ok, woody:result()}
    | {exception, woody_error:business_error()}.
    %% TODO handle woody exceptions errors
do_call(Request, CacheControl, Options, Context) ->
    case get_from_cache(Request, CacheControl, Options) of
        OK={ok, _} ->
            OK;
        not_found ->
            case woody_client:call(Request, woody_client_options(Options), Context) of
                {ok, Result} ->
                    ok = update_cache(Request, Result, CacheControl, Options),
                    {ok, Result};
                Exception = {exception, _} ->
                    Exception
            end
    end.

%%
%% local
%%
-spec get_from_cache(_Key, cache_control(), options()) ->
    not_found | {ok, _Value}.
get_from_cache(_, no_cache, _) ->
    not_found;
get_from_cache(Key, lru, Options) ->
    case cache:get(lru_cache_name(Options), Key) of
        OK={ok, _} -> OK;
        undefined  -> not_found
    end;
get_from_cache(Key, {stale, Timeout}, Options) ->
    case woody_stale_cache:get(stale_cache_options(Options), Key, Timeout) of
        {valid, Value} -> {ok, Value};
        {stale, _}     -> not_found;
        not_found      -> not_found
    end.

-spec update_cache(_Key, _Value, cache_control(), options()) ->
    ok.
update_cache(_, _, no_cache, _) ->
    ok;
update_cache(Key, Value, lru, Options) ->
    ok = cache:get(lru_cache_name(Options), Key, Value);
update_cache(Key, Value, {stale, _}, Options) ->
    ok = woody_stale_cache:store(stale_cache_options(Options), Key, Value).

%%

-type lru_cache_options() :: #{
    local_name => atom(),
    type       => set | ordered_set,
    policy     => lru | mru,
    memory     => integer(),
    size       => integer(),
    n          => integer(),
    ttl        => integer(),
    check      => integer(),
    stats      => function() | {module(), atom()},
    heir       => atom() | pid()
}.
-type options() :: #{
    workers_name := atom(),
    stale_cache  := woody_stale_cache:options(),
    lru_cache    := lru_cache_options(),
    woody_client := woody_client:options()
}.

-spec workers_reg_name(options()) ->
    genlib_gen:reg_name().
workers_reg_name(#{workers_name := Name}) ->
    {local, Name}.

-spec workers_ref(options()) ->
    genlib_gen:ref().
workers_ref(#{workers_name := Name}) ->
    Name.

-spec lru_cache_child_spec(atom(), options()) ->
    supervisor:child_spec().
lru_cache_child_spec(ChildID, Options) ->
    #{
        id       => ChildID,
        start    => {cache, start_link, [lru_cache_name(Options), lru_cache_options(Options)]},
        restart  => permanent,
        type     => supervisor
    }.

-spec stale_cache_options(options()) ->
    woody_stale_cache:options().
stale_cache_options(#{stale_cache := Options}) ->
    Options.

-spec lru_cache_name(options()) ->
    atom().
lru_cache_name(#{lru_cache := #{local_name := Name}}) ->
    Name.

-spec lru_cache_options(options()) ->
    list().
lru_cache_options(#{lru_cache := Options}) ->
    maps:to_list(Options).

-spec woody_client_options(options()) ->
    woody_client:options().
woody_client_options(#{woody_client := Options}) ->
    Options.
