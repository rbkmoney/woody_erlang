%%%
%%% TODO:
%%%  - add tests
%%%
-module(woody_stale_cache).

%% API
-export_type([options/0]).
-export_type([ref    /0]).
-export_type([key    /0]).
-export_type([value  /0]).
-export([child_spec/2]).
-export([start_link/1]).
-export([get       /3]).
-export([store     /3]).

%% gen_server callbacks
-behavior(gen_server).
-export([init/1, handle_info/2, handle_cast/2, handle_call/3, code_change/3, terminate/2]).

%%
%% API
%%
-type options() :: #{
    lifetime         => non_neg_integer(),
    cleanup_interval => non_neg_integer(),
    local_name       => atom()
}.
-type ref() :: genlib_gen:ref().
-type key() :: _.
-type value() :: _.

-spec child_spec(atom(), options()) ->
    supervisor:child_spec().
child_spec(ChildID, Options) ->
    #{
        id       => ChildID,
        start    => {?MODULE, start_link, [Options]},
        restart  => permanent,
        type     => worker
    }.

-spec start_link(options()) ->
    genlib_gen:start_ret().
start_link(Options) ->
    gen_server:start_link(server_reg_name(Options), ?MODULE, Options, []).

-spec get(options(), key(), non_neg_integer()) ->
      {valid, value()}
    | {stale, value()}
    | not_found
.
get(Options, Key, ValidTime) ->
    case ets:lookup(ets_name(Options), Key) of
        [V] -> extract_value(Options, V, ValidTime);
        [ ] -> not_found
    end.

-spec store(options(), key(), value()) ->
    ok.
store(Options, Key, Value) ->
    gen_server:call(server_ref(Options), {store, Key, Value}).

%%
%% gen_server callbacks
%%
-type state() :: #{
    options => options  (),
    tref    => reference() | undefined
}.

-spec init(options()) ->
    {ok, state()}.
init(Options) ->
    _ = ets:new(ets_name(Options), [ordered_set, public, named_table]),
    S = schedule_clean(
            #{
                options => Options,
                tref    => undefined
            }
        ),
    {ok, S}.

-spec handle_call(_Call, genlib_gen:server_from(), state()) ->
    genlib_gen:server_handle_call_ret(ok, state()).
handle_call({store, Key, Value}, _From, S) ->
    ok = do_store(Key, Value, S),
    {reply, ok, S};
handle_call(Call, From, S) ->
    _ = error_logger:warning_msg("unexpected call ~p ~p", [Call, From]),
    {noreply, S}.

-spec handle_cast(_Cast, state()) ->
    genlib_gen:server_handle_cast_ret(state()).
handle_cast(Cast, State) ->
    ok = error_logger:error_msg("unexpected gen_server cast received: ~p", [Cast]),
    {noreply, State}.


-spec handle_info(_Info, state()) ->
    genlib_gen:server_handle_info_ret(state()).
handle_info({timeout, TRef, cleanup}, S = #{options := Options, tref := TRef}) ->
    ok = cleanup(Options),
    {noreply, schedule_clean(S)};
handle_info(Info, State) ->
    ok = error_logger:error_msg("unexpected gen_server info ~p", [Info]),
    {noreply, State}.


-spec code_change(_, state(), _) ->
    genlib_gen:server_code_change_ret(state()).
code_change(_, State, _) ->
    {ok, State}.

-spec terminate(_Reason, state()) ->
    ok.
terminate(_, _) ->
    ok.


%%
%% local
%%
-spec extract_value(options(), {key(), value(), non_neg_integer()}, non_neg_integer()) ->
    value().
extract_value(#{lifetime := Lifetime}, {_Key, Value, StoreTs}, ValidTime) ->
    CurrentTime = timestamp_ms(),
    AliveTill = StoreTs + Lifetime,
    ValidTill = StoreTs + ValidTime,
    if
        AliveTill < CurrentTime -> not_found;
        ValidTill < CurrentTime -> {stale, Value};
        true                    -> {valid, Value}
    end.

-spec do_store(key(), value(), state()) ->
    ok.
do_store(Key, Value, #{options := Options}) ->
    true = ets:insert(ets_name(Options), {Key, Value, timestamp_ms()}),
    ok.

-spec schedule_clean(state()) ->
    state().
schedule_clean(S = #{options := #{cleanup_interval := CleanupInterval}, tref := undefined}) ->
    TRef = erlang:start_timer(CleanupInterval, self(), cleanup),
    S#{tref := TRef};
schedule_clean(S = #{tref := TRef}) ->
    _ = erlang:cancel_timer(TRef),
    schedule_clean(S#{tref := undefined}).

-spec cleanup(options()) ->
    ok.
cleanup(Options = #{lifetime := Lifetime}) ->
    % Delete too old (ExpireTime older=less than bound) entries
    AliveTill = timestamp_ms() + Lifetime,
    _ = ets:select_delete(ets_name(Options), [{{'_', '_', '$1'}, [], [{'<', '$1', AliveTill}]}]),
    ok.

-spec timestamp_ms() ->
    non_neg_integer().
timestamp_ms() ->
    erlang:system_time(1000).

-spec server_reg_name(options()) ->
    genlib_gen:reg_name().
server_reg_name(#{local_name := Name}) ->
    {local, Name}.

-spec server_ref(options()) ->
    genlib_gen:ref().
server_ref(#{local_name := Name}) ->
    Name.

-spec ets_name(options()) ->
    atom().
ets_name(#{local_name := Name}) ->
    Name.
