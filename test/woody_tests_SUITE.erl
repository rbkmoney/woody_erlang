-module(woody_tests_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-include("woody_test_thrift.hrl").
-include("woody_defs.hrl").

-behaviour(supervisor).
-behaviour(woody_server_thrift_handler).
-behaviour(woody_event_handler).

%% supervisor callbacks
-export([init/1]).

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%% woody_event_handler callbacks
-export([handle_event/4]).

%% cowboy_http_handler callbacks
-export([init/2, terminate/3]).

%% common test API
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2,
    init_per_testcase/2,
    end_per_testcase/2
]).

-export([
    context_add_put_get_meta_ok_test/1,
    context_get_meta_by_key_ok_test/1,
    context_get_empty_meta_ok_test/1,
    context_get_empty_meta_by_key_ok_test/1,
    context_given_rpc_id_test/1,
    context_given_id_test/1,
    context_generated_rpc_id_test/1,
    ids_monotonic_incr_test/1,
    deadline_reached_test/1,
    deadline_to_from_timeout_test/1,
    deadline_to_from_binary_test/1,
    call_ok_test/1,
    call_resolver_nxdomain/1,
    call3_ok_test/1,
    call_oneway_void_test/1,
    call_sequence_with_context_meta_test/1,
    call_business_error_test/1,
    call_throw_unexpected_test/1,
    call_system_external_error_test/1,
    call_client_error_test/1,
    call_server_internal_error_test/1,
    call_pass_thru_ok_test/1,
    call_pass_thru_except_test/1,
    call_pass_thru_bad_result_test/1,
    call_pass_thru_bad_except_test/1,
    call_pass_thru_result_unexpected_test/1,
    call_pass_thru_resource_unavail_test/1,
    call_pass_thru_result_unknown_test/1,
    call_no_headers_404_test/1,
    call_no_headers_500_test/1,
    call_no_headers_502_test/1,
    call_no_headers_503_test/1,
    call_no_headers_504_test/1,
    call3_ok_default_ev_handler_test/1,
    call_thrift_multiplexed_test/1,
    call_deadline_ok_test/1,
    call_deadline_reached_on_client_test/1,
    server_handled_client_timeout_test/1,
    call_deadline_timeout_test/1,
    server_http_req_validation_test/1,
    try_bad_handler_spec_test/1,
    find_multiple_pools_test/1,
    calls_with_cache/1,
    woody_resolver_inet/1,
    woody_resolver_inet6/1,
    woody_resolver_errors/1
]).

-define(THRIFT_DEFS, woody_test_thrift).

-define(WEAPON_FAILURE(Reason), #'WeaponFailure'{
    code = <<"weapon_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(POWERUP_FAILURE(Reason), #'PowerupFailure'{
    code = <<"powerup_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(SERVER_IP, {0, 0, 0, 0}).
-define(SERVER_PORT, 8085).
-define(URL_BASE, "http://0.0.0.0:8085").
-define(PATH_WEAPONS, "/v1/woody/test/weapons").
-define(PATH_POWERUPS, "/v1/woody/test/powerups").

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).

-define(ERR_S_THRIFT_MULTIPLEX, <<"thrift: multiplexing (not supported)">>).
-define(ERR_POWERUP_UNAVAILABLE, <<"expired">>).
-define(ERR_POWERUP_STATE_UNKNOWN, <<"invisible">>).

-define(WEAPON_STACK_OVERFLOW, pos_out_of_boundaries).
-define(BAD_POWERUP_REPLY, powerup_unknown).

-type config() :: [{atom(), any()}].
-type case_name() :: atom().
-type group_name() :: atom().

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) -> {ok, woody:result()}.

-spec handle_event(
    woody_event_handler:event(),
    woody:rpc_id(),
    woody_event_handler:event_meta(),
    woody:options()
) -> _.

-spec init(any()) -> genlib_gen:supervisor_ret().

-spec init(cowboy_req:req(), cowboy:http_status()) -> {ok, cowboy_req:req(), cowboy:http_status()}.
-spec terminate(any(), any(), any()) -> ok.

-spec all() -> [{group, group_name()}].
-spec groups() -> [{group_name(), list(), [case_name()]}].
-spec init_per_suite(config()) -> config().
-spec end_per_suite(config()) -> any().
-spec init_per_group(group_name(), config()) -> config().
-spec end_per_group(group_name(), config()) -> any().
-spec init_per_testcase(case_name(), config()) -> config().
-spec end_per_testcase(case_name(), config()) -> any().

-spec context_add_put_get_meta_ok_test(config()) -> any().
-spec context_get_meta_by_key_ok_test(config()) -> any().
-spec context_get_empty_meta_ok_test(config()) -> any().
-spec context_get_empty_meta_by_key_ok_test(config()) -> any().
-spec context_given_rpc_id_test(config()) -> any().
-spec context_given_id_test(config()) -> any().
-spec context_generated_rpc_id_test(config()) -> any().
-spec ids_monotonic_incr_test(config()) -> any().
-spec deadline_reached_test(config()) -> any().
-spec deadline_to_from_timeout_test(config()) -> any().
-spec deadline_to_from_binary_test(config()) -> any().
-spec call_ok_test(config()) -> any().
-spec call_resolver_nxdomain(config()) -> any().
-spec call3_ok_test(config()) -> any().
-spec call_oneway_void_test(config()) -> any().
-spec call_sequence_with_context_meta_test(config()) -> any().
-spec call_business_error_test(config()) -> any().
-spec call_throw_unexpected_test(config()) -> any().
-spec call_system_external_error_test(config()) -> any().
-spec call_client_error_test(config()) -> any().
-spec call_server_internal_error_test(config()) -> any().
-spec call_pass_thru_ok_test(config()) -> any().
-spec call_pass_thru_except_test(config()) -> any().
-spec call_pass_thru_bad_result_test(config()) -> any().
-spec call_pass_thru_bad_except_test(config()) -> any().
-spec call_pass_thru_result_unexpected_test(config()) -> any().
-spec call_pass_thru_resource_unavail_test(config()) -> any().
-spec call_pass_thru_result_unknown_test(config()) -> any().
-spec call_no_headers_404_test(config()) -> any().
-spec call_no_headers_500_test(config()) -> any().
-spec call_no_headers_502_test(config()) -> any().
-spec call_no_headers_503_test(config()) -> any().
-spec call_no_headers_504_test(config()) -> any().
-spec call3_ok_default_ev_handler_test(config()) -> any().
-spec call_thrift_multiplexed_test(config()) -> any().
-spec call_deadline_ok_test(config()) -> any().
-spec call_deadline_reached_on_client_test(config()) -> any().
-spec server_handled_client_timeout_test(config()) -> any().
-spec call_deadline_timeout_test(config()) -> any().
-spec server_http_req_validation_test(config()) -> any().
-spec try_bad_handler_spec_test(config()) -> any().
-spec find_multiple_pools_test(config()) -> any().
-spec calls_with_cache(config()) -> any().
-spec woody_resolver_inet(config()) -> any().
-spec woody_resolver_inet6(config()) -> any().
-spec woody_resolver_errors(config()) -> any().

%%
%% tests descriptions
%%
all() ->
    [{group, G} || G <- maps:keys(cross_test_groups())] ++
        [
            {group, client_server},
            ids_monotonic_incr_test,
            {group, contexts},
            {group, deadlines},
            {group, woody_resolver}
        ].

groups() ->
    SpecTests = [
        call_ok_test,
        call_resolver_nxdomain,
        call3_ok_test,
        call_oneway_void_test,
        call_sequence_with_context_meta_test,
        call_business_error_test,
        call_throw_unexpected_test,
        call_system_external_error_test,
        call_client_error_test,
        call_server_internal_error_test,
        call_pass_thru_ok_test,
        call_pass_thru_except_test,
        call_pass_thru_bad_result_test,
        call_pass_thru_bad_except_test,
        call_pass_thru_result_unexpected_test,
        call_pass_thru_resource_unavail_test,
        call_pass_thru_result_unknown_test,
        call_no_headers_404_test,
        call_no_headers_500_test,
        call_no_headers_502_test,
        call_no_headers_503_test,
        call_no_headers_504_test,
        call3_ok_default_ev_handler_test,
        call_thrift_multiplexed_test,
        call_deadline_ok_test,
        call_deadline_reached_on_client_test,
        server_handled_client_timeout_test,
        call_deadline_timeout_test,
        server_http_req_validation_test,
        try_bad_handler_spec_test,
        find_multiple_pools_test,
        calls_with_cache
    ],
    [{G, [], SpecTests} || G <- maps:keys(cross_test_groups())] ++
        [
            {client_server, [], SpecTests},
            {contexts, [], [
                context_add_put_get_meta_ok_test,
                context_get_meta_by_key_ok_test,
                context_get_empty_meta_ok_test,
                context_get_empty_meta_by_key_ok_test,
                context_given_rpc_id_test,
                context_given_id_test,
                context_generated_rpc_id_test
            ]},
            {deadlines, [], [
                deadline_reached_test,
                deadline_to_from_timeout_test,
                deadline_to_from_binary_test
            ]},
            {woody_resolver, [], [
                woody_resolver_inet,
                woody_resolver_inet6,
                woody_resolver_errors
            ]}
        ].

cross_test_groups() ->
    #{
        'client_v1.server_v1' => {
            #{protocol_handler_override => woody_client_thrift},
            #{protocol_handler_override => woody_server_thrift_http_handler}
        },
        'client_v1.server_v2' => {
            #{protocol_handler_override => woody_client_thrift},
            #{}
        },
        'client_v2.server_v1' => {
            #{},
            #{protocol_handler_override => woody_server_thrift_http_handler}
        }
    }.

%%
%% starting/stopping
%%
init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({woody_joint_workers, '_', '_'}, x),
    %%Apps = genlib_app:start_application_with(woody, [{trace_http_server, true}]),
    application:set_env(hackney, mod_metrics, woody_client_metrics),
    application:set_env(woody, woody_client_metrics_options, #{
        metric_key_mapping => #{
            [hackney, nb_requests] => [hackney, requests_in_process]
        }
    }),
    application:set_env(how_are_you, metrics_handlers, [
        {woody_api_hay, #{
            interval => 1000
        }}
    ]),
    {ok, Apps} = application:ensure_all_started(woody),
    {ok, HayApps} = application:ensure_all_started(how_are_you),
    [{apps, HayApps ++ Apps} | C].

end_per_suite(C) ->
    % unset so it won't report metrics next suite
    application:unset_env(hackney, mod_metrics),
    [application:stop(App) || App <- proplists:get_value(apps, C)].

init_per_testcase(TC, C) when
    TC =:= try_bad_handler_spec_test;
    TC =:= context_given_rpc_id_test;
    TC =:= context_given_id_test;
    TC =:= context_generated_rpc_id_test;
    TC =:= ids_monotonic_incr_test;
    TC =:= deadline_reached_test;
    TC =:= deadline_to_from_timeout_test;
    TC =:= deadline_to_from_binary_test;
    TC =:= call_client_error_test
->
    C;
init_per_testcase(TC, C) when
    TC =:= call_no_headers_404_test;
    TC =:= call_no_headers_500_test;
    TC =:= call_no_headers_502_test;
    TC =:= call_no_headers_503_test;
    TC =:= call_no_headers_504_test
->
    {ok, Sup} = start_tc_sup(),
    {ok, _} = start_error_server(TC, Sup),
    [{sup, Sup} | C];
init_per_testcase(find_multiple_pools_test, C) ->
    {ok, Sup} = start_tc_sup(),
    Pool1 = {swords, 15000, 100},
    Pool2 = {shields, undefined, 50},
    ok = start_woody_server_with_pools(woody_ct, Sup, ['Weapons', 'Powerups'], [Pool1, Pool2], C),
    [{sup, Sup} | C];
init_per_testcase(calls_with_cache, C) ->
    {ok, Sup} = start_tc_sup(),
    {ok, _} = start_caching_client(caching_client_ct, Sup),
    {ok, _} = start_woody_server(woody_ct, Sup, ['Weapons', 'Powerups'], C),
    [{sup, Sup} | C];
init_per_testcase(server_handled_client_timeout_test, C) ->
    {ok, Sup} = start_tc_sup(),
    {ok, _} = supervisor:start_child(Sup, server_timeout_event_handler:child_spec()),
    {ok, _} = start_woody_server(woody_ct, Sup, ['Weapons', 'Powerups'], server_timeout_event_handler, C),
    [{sup, Sup} | C];
init_per_testcase(_, C) ->
    {ok, Sup} = start_tc_sup(),
    {ok, _} = start_woody_server(woody_ct, Sup, ['Weapons', 'Powerups'], C),
    [{sup, Sup} | C].

init_per_group(woody_resolver, Config) ->
    [{env_inet6, inet_db:res_option(inet6)} | Config];
init_per_group(Name, Config) ->
    {ClientOpts, ServerOpts} = maps:get(Name, cross_test_groups(), {#{}, #{}}),
    [{client_opts, ClientOpts}, {server_opts, ServerOpts} | Config].

end_per_group(_Name, _Config) ->
    ok.

start_tc_sup() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_error_server(TC, Sup) ->
    Code = get_fail_code(TC),
    Dispatch = cowboy_router:compile([{'_', [{?PATH_WEAPONS, ?MODULE, Code}]}]),
    Server = ranch:child_spec(
        woody_ct,
        ranch_tcp,
        [{ip, ?SERVER_IP}, {port, ?SERVER_PORT}],
        cowboy_clear,
        #{env => #{dispatch => Dispatch}}
    ),
    supervisor:start_child(Sup, Server).

start_woody_server(Id, Sup, Services, C) ->
    start_woody_server(Id, Sup, Services, ?MODULE, C).

start_woody_server(Id, Sup, Services, EventHandler, C) ->
    Opts = maps:merge(
        proplists:get_value(server_opts, C, #{}),
        #{
            handlers => [get_handler(S) || S <- Services],
            event_handler => EventHandler,
            ip => ?SERVER_IP,
            port => ?SERVER_PORT
        }
    ),
    Server = woody_server:child_spec(Id, Opts),
    supervisor:start_child(Sup, Server).

start_woody_server_with_pools(Id, Sup, Services, Params, C) ->
    Opts = maps:merge(
        proplists:get_value(server_opts, C, #{}),
        #{
            handlers => [get_handler(S) || S <- Services],
            event_handler => ?MODULE,
            ip => ?SERVER_IP,
            port => ?SERVER_PORT
        }
    ),
    Server = woody_server:child_spec(Id, Opts),
    {ok, WoodyServer} = supervisor:start_child(Sup, Server),
    Specs = [woody_client:child_spec(pool_opts(Pool)) || Pool <- Params],

    _ = [supervisor:start_child(WoodyServer, Spec) || Spec <- Specs],
    ok.

start_caching_client(Id, Sup) ->
    supervisor:start_child(Sup, #{
        id => Id,
        start => {woody_caching_client, start_link, [woody_caching_client_options()]}
    }).

woody_caching_client_options() ->
    #{
        workers_name => test_caching_client_workers,
        cache => woody_caching_client_cache_options(test_caching_client_cache),
        woody_client => pool_opts({test_caching_client_pool, 1000, 10})
    }.

woody_caching_client_cache_options(Name) ->
    #{
        local_name => Name,
        n => 10,
        ttl => 60
    }.

pool_opts(Pool) ->
    {Url, _} = get_service_endpoint('Weapons'),
    #{
        url => Url,
        event_handler => ?MODULE,
        transport_opts => start_pool_opts(Pool)
    }.

start_pool_opts({Name, Timeout, MaxConnections}) ->
    #{
        pool => Name,
        timeout => Timeout,
        max_connections => MaxConnections
    }.

get_handler('Powerups') ->
    {
        ?PATH_POWERUPS,
        {{?THRIFT_DEFS, 'Powerups'}, ?MODULE}
    };
get_handler('Weapons') ->
    {
        ?PATH_WEAPONS,
        {
            {?THRIFT_DEFS, 'Weapons'},
            {?MODULE, #{
                meta_test_id => <<"call_seq_with_context_meta">>
            }}
        }
    }.

get_fail_code(call_no_headers_404_test) -> 404;
get_fail_code(call_no_headers_500_test) -> 500;
get_fail_code(call_no_headers_502_test) -> 502;
get_fail_code(call_no_headers_503_test) -> 503;
get_fail_code(call_no_headers_504_test) -> 504.

end_per_testcase(_, C) ->
    case proplists:get_value(sup, C, undefined) of
        undefined ->
            ok;
        Sup ->
            ok = proc_lib:stop(Sup)
    end.

%%
%% tests
%%

context_add_put_get_meta_ok_test(_) ->
    Meta = #{
        <<"world_says">> => <<"Hello">>,
        <<"human_says">> => <<"Nope!">>
    },

    Context = woody_context:add_meta(woody_context:new(), Meta),
    Meta = woody_context:get_meta(Context).

context_get_meta_by_key_ok_test(_) ->
    Meta = #{
        <<"world_says">> => <<"Hello">>,
        <<"human_says">> => <<"Nope!">>
    },

    Context = woody_context:add_meta(woody_context:new(), Meta),
    <<"Nope!">> = woody_context:get_meta(<<"human_says">>, Context).

context_get_empty_meta_ok_test(_) ->
    #{} = woody_context:get_meta(woody_context:new()).

context_get_empty_meta_by_key_ok_test(_) ->
    undefined = woody_context:get_meta(<<"fox_says">>, woody_context:new()).

context_given_rpc_id_test(_) ->
    ReqId = <<"context_given_rpc_id">>,
    RpcId = #{parent_id => ReqId, trace_id => ReqId, span_id => ReqId},
    #{
        rpc_id := RpcId
    } = woody_context:new(RpcId).

context_given_id_test(_) ->
    Id = <<"context_given_trace_id">>,
    #{
        rpc_id := #{parent_id := ?ROOT_REQ_PARENT_ID, span_id := Id, trace_id := _}
    } = woody_context:new(Id).

context_generated_rpc_id_test(_) ->
    #{
        rpc_id := #{parent_id := ?ROOT_REQ_PARENT_ID, span_id := _GenId1, trace_id := _GenId2}
    } = woody_context:new().

ids_monotonic_incr_test(_) ->
    TraceId = <<"ids_monotonic_incr">>,
    ParentCtx = woody_context:new(TraceId),
    Children = lists:map(fun(_) -> woody_context:new_child(ParentCtx) end, lists:seq(1, 10000)),
    SortFun = fun(C1, C2) ->
        Span1 = genlib:to_int(woody_context:get_rpc_id(span_id, C1)),
        Span2 = genlib:to_int(woody_context:get_rpc_id(span_id, C2)),
        Span1 < Span2
    end,
    ?assertEqual(Children, lists:sort(SortFun, Children)).

deadline_reached_test(_) ->
    {Date, {H, M, S}} = calendar:universal_time(),
    true = woody_deadline:is_reached({{Date, {H, M, S - 1}}, 0}),
    false = woody_deadline:is_reached({{Date, {H, M, S + 1}}, 745}).

deadline_to_from_timeout_test(_) ->
    {Date, {H, M, S}} = calendar:universal_time(),
    Timeout = woody_deadline:to_timeout({{Date, {H, M, S + 1}}, 500}),
    true = Timeout > 0 andalso Timeout =< 1500,

    Timeout1 = 300,
    Deadline = woody_deadline:from_timeout(Timeout1),
    false = woody_deadline:is_reached(Deadline),
    ok = timer:sleep(Timeout1),
    true = woody_deadline:is_reached(Deadline).

-dialyzer({nowarn_function, deadline_to_from_binary_test/1}).

deadline_to_from_binary_test(_) ->
    Deadline = {{{2010, 4, 11}, {22, 35, 41}}, 29},
    DeadlineBin = <<"2010-04-11T22:35:41.029Z">>,
    DeadlineBin = woody_deadline:to_binary(Deadline),
    Deadline = woody_deadline:from_binary(DeadlineBin),

    Deadline1 = {calendar:universal_time(), 542},
    DeadlineBin1 = woody_deadline:to_binary(Deadline1),
    Deadline1 = woody_deadline:from_binary(DeadlineBin1),

    Deadline2 = {{{2010, 4, 11}, {22, 35, 41}}, 0},
    DeadlineBin2 = <<"2010-04-11T22:35:41.000Z">>,
    Deadline2 = woody_deadline:from_binary(woody_deadline:to_binary(Deadline2)),
    DeadlineBin2 = woody_deadline:to_binary(Deadline2),

    Deadline3 = <<"2010-04-11T22:35:41+00:30">>,
    _ =
        try
            woody_deadline:from_binary(Deadline3)
        catch
            error:{bad_deadline, not_utc} ->
                ok
        end,

    _ = woody_deadline:from_binary(<<"2010-04-11T22:35:41+00:00">>),
    _ = woody_deadline:from_binary(<<"2010-04-11T22:35:41-00:00">>),

    _ =
        try
            woody_deadline:to_binary({{baddate, {22, 35, 41}}, 29})
        catch
            error:{bad_deadline, _} ->
                ok
        end,

    try
        woody_deadline:from_binary(<<"badboy">>)
    catch
        error:{bad_deadline, _} ->
            ok
    end.

call_ok_test(C) ->
    Gun = <<"Enforcer">>,
    gun_test_basic(<<"call_ok">>, Gun, {ok, genlib_map:get(Gun, weapons())}, C).

call_resolver_nxdomain(C) ->
    Context = make_context(<<"nxdomain">>),
    ?assertError(
        {woody_error, {internal, resource_unavailable, <<"{resolve_failed,nxdomain}">>}},
        call(Context, 'The Void', get_weapon, {<<"Enforcer">>, self_to_bin()}, C)
    ).

call3_ok_test(C) ->
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun = <<"Enforcer">>,
    Request = {Service, get_weapon, {Gun, self_to_bin()}},
    Opts = mk_client_opts(#{url => Url}, C),
    Expect = {ok, genlib_map:get(Gun, weapons())},
    Expect = woody_client:call(Request, Opts).

call3_ok_default_ev_handler_test(C) ->
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun = <<"Enforcer">>,
    Request = {Service, get_weapon, {Gun, self_to_bin()}},
    Opts = mk_client_opts(#{url => Url, event_handler => {woody_event_handler_default, #{}}}, C),
    Expect = {ok, genlib_map:get(Gun, weapons())},
    Expect = woody_client:call(Request, Opts).

call_business_error_test(C) ->
    Gun = <<"Bio Rifle">>,
    gun_test_basic(
        <<"call_business_error">>,
        Gun,
        {exception, ?WEAPON_FAILURE("out of ammo")},
        C
    ).

call_throw_unexpected_test(C) ->
    Id = <<"call_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, weapons()),
    Context = make_context(Id),
    ?assertError(
        {woody_error, {external, result_unexpected, _}},
        call(Context, 'Weapons', switch_weapon, {Current, next, 1, self_to_bin()}, C)
    ).

call_system_external_error_test(C) ->
    Id = <<"call_system_external_error">>,
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    Context = make_context(Id),
    ?assertError(
        {woody_error, {external, result_unexpected, _}},
        call(Context, 'Weapons', get_weapon, {Gun, self_to_bin()}, C)
    ).

call_client_error_test(C) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Context = make_context(<<"call_client_error">>),
    ?assertError(
        {woody_error, {internal, result_unexpected, <<"client thrift error: ", _/binary>>}},
        call(Context, 'Weapons', get_weapon, {Gun, self_to_bin()}, C)
    ).

call_server_internal_error_test(C) ->
    Armor = <<"Helmet">>,
    Context = make_context(<<"call_server_internal_error">>),
    ?assertError(
        {woody_error, {external, result_unexpected, _}},
        call(Context, 'Powerups', get_powerup, {Armor, self_to_bin()}, C)
    ),
    {ok, _} = receive_msg(Armor, Context).

call_oneway_void_test(C) ->
    Armor = <<"Helmet">>,
    Context = make_context(<<"call_oneway_void">>),
    {ok, ok} = call(Context, 'Powerups', like_powerup, {Armor, self_to_bin()}, C),
    {ok, _} = receive_msg(Armor, Context).

call_sequence_with_context_meta_test(C) ->
    Gun = <<"Enforcer">>,
    Current = genlib_map:get(Gun, weapons()),
    Context = woody_context:new(
        <<"call_seq_with_context_meta">>,
        #{genlib:to_binary(Current#'Weapon'.slot_pos) => Gun}
    ),
    Expect = {ok, genlib_map:get(<<"Ripper">>, weapons())},
    Expect = call(Context, 'Weapons', switch_weapon, {Current, next, 1, self_to_bin()}, C).

call_pass_thru_ok_test(C) ->
    Armor = <<"AntiGrav Boots">>,
    Context = make_context(<<"call_pass_thru_ok">>),
    Expect = {ok, genlib_map:get(Armor, powerups())},
    Expect = call(Context, 'Powerups', proxy_get_powerup, {Armor, self_to_bin()}, C),
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_except_test(C) ->
    Armor = <<"Shield Belt">>,
    Id = <<"call_pass_thru_except">>,
    RpcId = woody_context:new_rpc_id(?ROOT_REQ_PARENT_ID, Id, Id),
    Context = woody_context:new(RpcId),
    _Result =
        try
            call(Context, 'Powerups', proxy_get_powerup, {Armor, self_to_bin()}, C)
        catch
            error:{woody_error, {external, result_unexpected, _}} ->
                ok
        end,
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_bad_result_test(C) ->
    Armor = <<"AntiGrav Boots">>,
    Context = make_context(<<"call_pass_thru_bad_result">>),
    ?assertError(
        {woody_error, {external, result_unexpected, _}},
        call(Context, 'Powerups', bad_proxy_get_powerup, {Armor, self_to_bin()}, C)
    ),
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_bad_except_test(C) ->
    Armor = <<"Shield Belt">>,
    Context = make_context(<<"call_pass_thru_bad_except">>),
    ?assertError(
        {woody_error, {external, result_unexpected, _}},
        call(Context, 'Powerups', bad_proxy_get_powerup, {Armor, self_to_bin()}, C)
    ),
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_result_unexpected_test(C) ->
    call_pass_thru_error(
        <<"call_pass_thru_result_unexpected">>,
        <<"Helmet">>,
        error,
        result_unexpected,
        C
    ).

call_pass_thru_resource_unavail_test(C) ->
    call_pass_thru_error(
        <<"call_pass_thru_resource_unavail">>,
        <<"Damage Amplifier">>,
        error,
        resource_unavailable,
        C
    ).

call_pass_thru_result_unknown_test(C) ->
    call_pass_thru_error(
        <<"call_pass_thru_result_unknown">>,
        <<"Invisibility">>,
        error,
        result_unknown,
        C
    ).

call_pass_thru_error(Id, Powerup, ExceptClass, ErrClass, C) ->
    RpcId = woody_context:new_rpc_id(?ROOT_REQ_PARENT_ID, Id, Id),
    Context = woody_context:new(RpcId),
    ?assertException(
        ExceptClass,
        {woody_error, {external, ErrClass, _}},
        call(Context, 'Powerups', proxy_get_powerup, {Powerup, self_to_bin()}, C)
    ),
    {ok, _} = receive_msg(Powerup, Context).

call_no_headers_404_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_404">>, result_unexpected, 404).

call_no_headers_500_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_500">>, result_unexpected, 500).

call_no_headers_502_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_502">>, result_unexpected, 502).

call_no_headers_503_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_503">>, resource_unavailable, 503).

call_no_headers_504_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_404">>, result_unknown, 504).

call_fail_w_no_headers(Id, Class, Code) ->
    Gun = <<"Enforcer">>,
    Context = make_context(Id),
    {Url, Service} = get_service_endpoint('Weapons'),
    BinCode = integer_to_binary(Code),
    ?assertError(
        {woody_error, {external, Class, <<"got response with http code ", BinCode:3/binary, _/binary>>}},
        woody_client:call(
            {Service, get_weapon, {Gun, self_to_bin()}},
            #{url => Url, event_handler => ?MODULE},
            Context
        )
    ).

find_multiple_pools_test(_) ->
    true = is_pid(hackney_pool:find_pool(swords)),
    true = is_pid(hackney_pool:find_pool(shields)).

call_thrift_multiplexed_test(_) ->
    Client = make_thrift_multiplexed_client(
        <<"call_thrift_multiplexed">>,
        "powerups",
        get_service_endpoint('Powerups')
    ),
    {Client1, {error, {system, {external, result_unexpected, ?ERR_S_THRIFT_MULTIPLEX}}}} =
        thrift_client:call(Client, get_powerup, [<<"Body Armor">>, self_to_bin()]),
    thrift_client:close(Client1).

make_thrift_multiplexed_client(Id, ServiceName, {Url, Service}) ->
    EvHandler = ?MODULE,
    WoodyState = woody_state:new(client, make_context(Id), EvHandler),
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(Url, #{}, #{}, WoodyState),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Protocol1} = thrift_multiplexed_protocol:new(Protocol, ServiceName),
    {ok, Client} = thrift_client:new(Protocol1, Service),
    Client.

call_deadline_ok_test(C) ->
    Id = <<"call_deadline_timeout">>,
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun = <<"Enforcer">>,
    Request = {Service, get_weapon, {Gun, self_to_bin()}},
    Opts = mk_client_opts(#{url => Url}, C),
    Deadline = woody_deadline:from_timeout(3000),
    Context = woody_context:new(Id, #{<<"sleep">> => <<"100">>}, Deadline),
    Expect = {ok, genlib_map:get(Gun, weapons())},
    Expect = woody_client:call(Request, Opts, Context).

call_deadline_reached_on_client_test(C) ->
    Id = <<"call_deadline_reached_on_client">>,
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun = <<"Enforcer">>,
    Request = {Service, get_weapon, {Gun, self_to_bin()}},
    Opts = mk_client_opts(#{url => Url}, C),
    Deadline = woody_deadline:from_timeout(0),
    Context = woody_context:new(Id, #{<<"sleep">> => <<"1000">>}, Deadline),
    ?assertError(
        {woody_error, {internal, resource_unavailable, <<"deadline reached">>}},
        woody_client:call(Request, Opts, Context)
    ).

server_handled_client_timeout_test(C) ->
    Id = <<"server_handled_client_timeout">>,
    {Url, Service} = get_service_endpoint('Weapons'),
    Request = {Service, get_stuck_looping_weapons, {}},
    Opts = mk_client_opts(#{url => Url}, C),
    Deadline = woody_deadline:from_timeout(250),
    Context = woody_context:new(Id, #{}, Deadline),
    try
        case woody_client:call(Request, Opts, Context) of
            _ -> error(unexpected_result)
        end
    catch
        error:{woody_error, {external, result_unknown, <<"timeout">>}} ->
            1 = server_timeout_event_handler:get_socket_errors_caught(),
            ok
    end.

call_deadline_timeout_test(C) ->
    Id = <<"call_deadline_timeout">>,
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun = <<"Enforcer">>,
    Request = {Service, get_weapon, {Gun, self_to_bin()}},
    Opts = mk_client_opts(#{url => Url}, C),
    Deadline = woody_deadline:from_timeout(500),
    Context = woody_context:new(Id, #{<<"sleep">> => <<"3000">>}, Deadline),
    ?assertError(
        {woody_error, {external, result_unknown, <<"timeout">>}},
        woody_client:call(Request, Opts, Context)
    ),
    ?assertError(
        {woody_error, {internal, resource_unavailable, <<"deadline reached">>}},
        woody_client:call(Request, Opts, Context)
    ).

server_http_req_validation_test(_Config) ->
    Id = <<"server_http_req_validation">>,
    {Url, _Service} = get_service_endpoint('Weapons'),
    Headers = [
        {?HEADER_RPC_ROOT_ID, genlib:to_binary(Id)},
        {?HEADER_RPC_ID, genlib:to_binary(Id)},
        {?HEADER_RPC_PARENT_ID, genlib:to_binary(?ROOT_REQ_PARENT_ID)},
        {<<"content-type">>, ?CONTENT_TYPE_THRIFT},
        {<<"accept">>, ?CONTENT_TYPE_THRIFT}
    ],

    {ok, _Ref} = timer:kill_after(5000),
    Opts = [{url, Url}, {recv_timeout, 100}, {connect_timeout, 100}, {send_timeout, 100}],
    %% Check missing Id headers, content-type and an empty body on the last step,
    %% as missing Accept is allowed
    lists:foreach(
        fun({C, H}) ->
            {ok, C, _, _} = hackney:request(post, Url, Headers -- [H], <<>>, Opts)
        end,
        lists:zip([400, 400, 400, 415, 400], Headers)
    ),

    %% Check wrong Accept
    {ok, 406, _, _} = hackney:request(
        post,
        Url,
        lists:keyreplace(<<"accept">>, 1, Headers, {<<"accept">>, <<"application/text">>}),
        <<>>,
        [{url, Url}]
    ),

    %% Check wrong methods
    %% Cowboy 2.5.0 no longer supports trace and connect methods, so they were removed from tests
    Methods = [get, put, delete, options, patch],
    lists:foreach(
        fun(M) ->
            {ok, 405, _, _} = hackney:request(M, Url, Headers, <<>>, Opts)
        end,
        Methods
    ),
    {ok, 405, _} = hackney:request(head, Url, Headers, <<>>, Opts).

try_bad_handler_spec_test(_) ->
    NaughtyHandler = {?PATH_POWERUPS, {{'should', 'be'}, '3-tuple'}},
    try
        woody_server:child_spec('bad_spec', #{
            handlers => [get_handler('Powerups'), NaughtyHandler],
            event_handler => ?MODULE,
            ip => ?SERVER_IP,
            port => ?SERVER_PORT
        })
    catch
        error:{bad_handler_spec, NaughtyHandler} ->
            ok
    end.

calls_with_cache(_) ->
    Id = <<"call_with_cache">>,
    {_, Service} = get_service_endpoint('Weapons'),
    Request = {Service, get_weapon, {<<"Enforcer">>, self_to_bin()}},
    InvalidRequest = {Service, get_weapon, {<<"Bio Rifle">>, self_to_bin()}},
    Opts = woody_caching_client_options(),
    Context = woody_context:new(Id),

    {ok, Result} = woody_caching_client:call(Request, no_cache, Opts, Context),
    {ok, Result} = woody_caching_client:call(Request, {cache_for, 1000}, Opts, Context),
    {ok, Result} = woody_caching_client:call(Request, {cache_for, 1000}, Opts, Context),
    {ok, Result} = woody_caching_client:call(Request, cache, Opts, Context),
    {ok, Result} = woody_caching_client:call(Request, cache, Opts, Context),

    {exception, _} = woody_caching_client:call(InvalidRequest, no_cache, Opts, Context),
    {exception, _} = woody_caching_client:call(InvalidRequest, {cache_for, 1000}, Opts, Context),
    {exception, _} = woody_caching_client:call(InvalidRequest, {cache_for, 1000}, Opts, Context),
    {exception, _} = woody_caching_client:call(InvalidRequest, cache, Opts, Context),
    {exception, _} = woody_caching_client:call(InvalidRequest, cache, Opts, Context),
    ok.

%%

-define(HACKNEY_URL(Scheme, Netloc, Path), #hackney_url{scheme = Scheme, netloc = Netloc, raw_path = Path}).

-define(RESPONSE(Scheme, OldNetloc, NewNetloc, Path), {
    ?HACKNEY_URL(Scheme, OldNetloc, Path),
    ?HACKNEY_URL(Scheme, NewNetloc, Path)
}).

woody_resolver_inet(C) ->
    WoodyState = woody_state:new(client, woody_context:new(), ?MODULE),
    ok = inet_db:set_inet6(false),
    {ok, ?RESPONSE(http, <<"127.0.0.1">>, <<"127.0.0.1">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://127.0.0.1/test">>, WoodyState),
    {ok, ?RESPONSE(http, <<"localhost">>, <<"127.0.0.1:80">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://localhost/test">>, WoodyState),
    {ok, ?RESPONSE(http, <<"localhost">>, <<"127.0.0.1:80">>, <<"/test?q=a">>)} =
        woody_resolver:resolve_url("http://localhost/test?q=a", WoodyState),
    {ok, ?RESPONSE(https, <<"localhost:8080">>, <<"127.0.0.1:8080">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"https://localhost:8080/test">>, WoodyState),
    {ok, ?RESPONSE(https, <<"localhost">>, <<"127.0.0.1:443">>, <<>>)} =
        woody_resolver:resolve_url(<<"https://localhost">>, WoodyState),
    ok = inet_db:set_inet6(?config(env_inet6, C)).

woody_resolver_inet6(C) ->
    WoodyState = woody_state:new(client, woody_context:new(), ?MODULE),
    ok = inet_db:set_inet6(true),
    {ok, ?RESPONSE(http, <<"[::1]">>, <<"[::1]">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://[::1]/test">>, WoodyState),
    {ok, ?RESPONSE(http, <<"localhost">>, <<"[::1]:80">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://localhost/test">>, WoodyState),
    {ok, ?RESPONSE(http, <<"localhost">>, <<"[::1]:80">>, <<"/test?q=a">>)} =
        woody_resolver:resolve_url("http://localhost/test?q=a", WoodyState),
    {ok, ?RESPONSE(https, <<"localhost:8080">>, <<"[::1]:8080">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"https://localhost:8080/test">>, WoodyState),
    {ok, ?RESPONSE(https, <<"localhost">>, <<"[::1]:443">>, <<>>)} =
        woody_resolver:resolve_url(<<"https://localhost">>, WoodyState),
    ok = inet_db:set_inet6(?config(env_inet6, C)).

woody_resolver_errors(_) ->
    WoodyState = woody_state:new(client, woody_context:new(), ?MODULE),
    {error, nxdomain} = woody_resolver:resolve_url(<<"http://nxdomainme">>, WoodyState),
    UnsupportedUrl = <<"ftp://localhost">>,
    {error, {unsupported_url_scheme, UnsupportedUrl}} = woody_resolver:resolve_url(UnsupportedUrl, WoodyState).

%%
%% supervisor callbacks
%%
init(_) ->
    {ok,
        {
            {one_for_one, 1, 1},
            []
        }}.

%%
%% woody_server_thrift_handler callbacks
%%

%% Weapons
handle_function(switch_weapon, {CurrentWeapon, Direction, Shift, To}, Context, #{meta_test_id := AnnotTestId}) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), CurrentWeapon}),
    CheckAnnot = is_meta_check_required(AnnotTestId, woody_context:get_rpc_id(trace_id, Context)),
    ok = check_meta(CheckAnnot, Context, CurrentWeapon),
    switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot, []);
handle_function(get_weapon, {Name, To}, Context, _Opts) ->
    ok = handle_sleep(Context),
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    case genlib_map:get(Name, weapons()) of
        #'Weapon'{ammo = 0} ->
            throw(?WEAPON_FAILURE("out of ammo"));
        Weapon = #'Weapon'{} ->
            {ok, Weapon}
    end;
%% Powerups
handle_function(get_powerup, {Name, To}, Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    {ok, return_powerup(Name)};
handle_function(ProxyGetPowerup, {Name, To}, Context, _Opts) when
    ProxyGetPowerup =:= proxy_get_powerup orelse
        ProxyGetPowerup =:= bad_proxy_get_powerup
->
    % NOTE
    % Client may return `{exception, _}` tuple with some business level exception
    % here, yet handler expects us to `throw/1` them. This is expected here it
    % seems though.
    try
        call(Context, 'Powerups', get_powerup, {Name, self_to_bin()}, [])
    catch
        Class:Reason:Stacktrace ->
            erlang:raise(Class, Reason, Stacktrace)
    after
        {ok, _} = receive_msg(Name, Context),
        ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name})
    end;
handle_function(like_powerup, {Name, To}, Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    {ok, ok};
handle_function(get_stuck_looping_weapons, _, _, _) ->
    {ok, timer:sleep(infinity)}.

%%
%% woody_event_handler callbacks
%%
handle_event(
    Event,
    RpcId = #{
        trace_id := TraceId,
        parent_id := ParentId
    },
    Meta = #{code := Code},
    _
) when
    (TraceId =:= <<"call_pass_thru_except">> orelse
        TraceId =:= <<"call_pass_thru_resource_unavailable">> orelse
        TraceId =:= <<"call_pass_thru_result_unexpected">> orelse
        TraceId =:= <<"call_pass_thru_result_unknown">>) andalso
        (Event =:= ?EV_CLIENT_RECEIVE orelse Event =:= ?EV_SERVER_SEND)
->
    _ = handle_proxy_event(Event, Code, TraceId, ParentId),
    log_event(Event, RpcId, Meta);
handle_event(Event, RpcId, Meta, _) ->
    log_event(Event, RpcId, Meta).

handle_proxy_event(?EV_CLIENT_RECEIVE, Code, TraceId, ParentId) when TraceId =/= ParentId ->
    handle_proxy_event(?EV_CLIENT_RECEIVE, Code, TraceId);
handle_proxy_event(?EV_SERVER_SEND, Code, TraceId, ParentId) when TraceId =:= ParentId ->
    handle_proxy_event(?EV_SERVER_SEND, Code, TraceId);
handle_proxy_event(_, _, _, _) ->
    ok.

handle_proxy_event(?EV_CLIENT_RECEIVE, 200, <<"call_pass_thru_except">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND, 500, <<"call_pass_thru_except">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 500, <<"call_pass_thru_result_unexpected">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND, 502, <<"call_pass_thru_result_unexpected">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 503, <<"call_pass_thru_resource_unavailable">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND, 502, <<"call_pass_thru_resource_unavailable">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 504, <<"call_pass_thru_result_unknown">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND, 502, <<"call_pass_thru_result_unknown">>) ->
    ok;
handle_proxy_event(Event, Code, Descr) ->
    erlang:error(badarg, [Event, Code, Descr]).

log_event(Event, RpcId, Meta) ->
    woody_ct_event_h:handle_event(Event, RpcId, Meta, []).

%%
%% cowboy_http_handler callbacks
%%
init(Req, Code) ->
    ct:pal("Cowboy fail server received request. Replying: ~p", [Code]),
    {ok, cowboy_req:reply(Code, Req), Code}.

terminate(_, _, _) ->
    ok.

%%
%% Weapons service
%%

weapon_slots() ->
    #{
        1 => <<"Impact Hammer">>,
        2 => <<"Enforcer">>,
        3 => <<"Bio Rifle">>,
        4 => <<"Shock Rifle">>,
        5 => <<"Pulse Gun">>,
        6 => <<"Ripper">>,
        7 => <<"Minigun">>,
        8 => <<"Flak Cannon">>,
        9 => <<"Rocket Launcher">>,
        0 => <<"Sniper Rifle">>
    }.

weapon(Name, Pos) ->
    weapon(Name, Pos, undefined).

weapon(Name, Pos, Ammo) ->
    {Name, #'Weapon'{
        name = Name,
        slot_pos = Pos,
        ammo = Ammo
    }}.

weapons() ->
    maps:from_list([
        weapon(<<"Impact Hammer">>, 1),
        weapon(<<"Enforcer">>, 2, 25),
        weapon(<<"Bio Rifle">>, 3, 0),
        weapon(<<"Shock Rifle">>, 4, 0),
        weapon(<<"Pulse Gun">>, 5, 0),
        weapon(<<"Ripper">>, 6, 16),
        weapon(<<"Minigun">>, 7, 0),
        weapon(<<"Flak Cannon">>, 8, 30),
        weapon(<<"Rocket Launcher">>, 9, 6),
        weapon(<<"Sniper Rifle">>, 0, 20)
    ]).

%%
%% Powerup service
%%

powerup(Name, Level) ->
    powerup(Name, Level, undefined).

powerup(Name, Level, TimeLeft) ->
    {Name, #'Powerup'{name = Name, level = Level, time_left = TimeLeft}}.

powerups() ->
    maps:from_list([
        powerup(<<"Thigh Pads">>, 23),
        powerup(<<"Body Armor">>, 82),
        powerup(<<"Shield Belt">>, 0),
        powerup(<<"AntiGrav Boots">>, 2),
        powerup(<<"Damage Amplifier">>, undefined, 0),
        powerup(<<"Invisibility">>, undefined, 0)
    ]).

%%
%% internal functions
%%
gun_test_basic(Id, Gun, Expect, C) ->
    Context = make_context(Id),
    {Class, Reason} = get_except(Expect),
    try call(Context, 'Weapons', get_weapon, {Gun, self_to_bin()}, C) of
        Expect -> ok
    catch
        Class:Reason -> ok
    end,
    check_msg(Gun, Context).

get_except({ok, _}) ->
    {undefined, undefined};
get_except({exception, _}) ->
    {undefined, undefined}.

make_context(ReqId) ->
    woody_context:new(ReqId).

call(Context, ServiceName, Function, Args, C) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    woody_client:call({Service, Function, Args}, mk_client_opts(#{url => Url}, C), Context).

get_service_endpoint('Weapons') ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_WEAPONS),
        {?THRIFT_DEFS, 'Weapons'}
    };
get_service_endpoint('Powerups') ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_POWERUPS),
        {?THRIFT_DEFS, 'Powerups'}
    };
get_service_endpoint('The Void') ->
    {
        <<"http://nxdomainme">>,
        {?THRIFT_DEFS, 'Weapons'}
    }.

check_msg(Msg, Context) ->
    {ok, _} = receive_msg(Msg, Context).

switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot, C) ->
    {NextWName, NextWPos} = next_weapon(CurrentWeapon, Direction, Shift),
    ContextAnnot = annotate_weapon(CheckAnnot, Context, NextWName, NextWPos),
    case call(ContextAnnot, 'Weapons', get_weapon, {NextWName, self_to_bin()}, C) of
        {exception, #'WeaponFailure'{code = <<"weapon_error">>, reason = <<"out of ammo">>}} ->
            switch_weapon(CurrentWeapon, Direction, Shift + 1, Context, CheckAnnot, C);
        Ok ->
            Ok
    end.

annotate_weapon(true, Context, WName, WPos) ->
    woody_context:add_meta(Context, #{genlib:to_binary(WPos) => WName});
annotate_weapon(_, Context, _, _) ->
    Context.

next_weapon(#'Weapon'{slot_pos = Pos}, next, Shift) ->
    next_weapon(Pos + Shift);
next_weapon(#'Weapon'{slot_pos = Pos}, prev, Shift) ->
    next_weapon(Pos - Shift).

next_weapon(Pos) when is_integer(Pos), Pos >= 0, Pos < 10 ->
    {genlib_map:get(Pos, weapon_slots(), <<"no weapon">>), Pos};
next_weapon(_) ->
    throw(?WEAPON_STACK_OVERFLOW).

return_powerup(<<"Invisibility">>) ->
    woody_error:raise(system, {internal, result_unknown, ?ERR_POWERUP_STATE_UNKNOWN});
return_powerup(Name) when is_binary(Name) ->
    return_powerup(genlib_map:get(Name, powerups(), ?BAD_POWERUP_REPLY));
return_powerup(#'Powerup'{level = Level}) when Level == 0 ->
    throw(?POWERUP_FAILURE("run out"));
return_powerup(#'Powerup'{time_left = Time}) when Time == 0 ->
    woody_error:raise(system, {internal, resource_unavailable, ?ERR_POWERUP_UNAVAILABLE});
return_powerup(P = #'Powerup'{}) ->
    P;
return_powerup(P = ?BAD_POWERUP_REPLY) ->
    P.

mk_client_opts(TestCaseOpts, C) ->
    GroupOpts = proplists:get_value(client_opts, C, #{}),
    lists:foldl(fun maps:merge/2, GroupOpts, [
        #{event_handler => ?MODULE},
        TestCaseOpts
    ]).

self_to_bin() ->
    genlib:to_binary(pid_to_list(self())).

send_msg(<<>>, _) ->
    ok;
send_msg(To, Msg) when is_pid(To) ->
    To ! {self(), Msg},
    ok;
send_msg(To, Msg) when is_binary(To) ->
    send_msg(list_to_pid(genlib:to_list(To)), Msg).

receive_msg(Msg, Context) ->
    Msg1 = {woody_context:get_rpc_id(span_id, Context), Msg},
    receive
        {From, Msg1} ->
            {ok, From}
    after 1000 -> error(get_msg_timeout)
    end.

is_meta_check_required(AnnotTestId, AnnotTestId) ->
    true;
is_meta_check_required(_, _) ->
    false.

check_meta(true, Context, #'Weapon'{name = WName, slot_pos = WSlot}) ->
    WSlotBin = genlib:to_binary(WSlot),
    WName = woody_context:get_meta(WSlotBin, Context),
    ok;
check_meta(_, _, _) ->
    ok.

handle_sleep(Context) ->
    case woody_context:get_meta(<<"sleep">>, Context) of
        undefined ->
            ok;
        BinTimer ->
            timer:sleep(binary_to_integer(BinTimer))
    end.
