-module(woody_tests_SUITE).

-include_lib("common_test/include/ct.hrl").

-include("woody_test_thrift.hrl").
-include("src/woody_defs.hrl").

-behaviour(supervisor).
-behaviour(woody_server_thrift_handler).
-behaviour(woody_event_handler).
-behaviour(cowboy_http_handler).

%% supervisor callbacks
-export([init/1]).

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%% woody_event_handler callbacks
-export([handle_event/4]).

%% cowboy_http_handler callbacks
-export([init/3, handle/2, terminate/3]).

%% common test API
-export([all/0, init_per_suite/1, init_per_testcase/2, end_per_suite/1, end_per_test_case/2]).
-export([
    context_given_rpc_id_test/1,
    context_given_trace_id_test/1,
    context_generated_rpc_id_test/1,
    ids_monotonic_incr_test/1,
    call_ok_test/1,
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
    call_with_client_pool_test/1,
    call_thrift_multiplexed_test/1,
    server_http_req_validation_test/1,
    try_bad_handler_spec_test/1
]).

-define(THRIFT_DEFS, woody_test_thrift).

%% Weapons service
-define(SLOTS, #{
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
}).

-define(WEAPON(Name, Pos, Ammo), Name => #'Weapon'{
    name     = Name,
    slot_pos = Pos,
    ammo     = Ammo
}).
-define(WEAPON(Name, Pos), ?WEAPON(Name, Pos, undefined)).

-define(WEAPONS, #{
    ?WEAPON(<<"Impact Hammer">>   , 1),
    ?WEAPON(<<"Enforcer">>        , 2, 25),
    ?WEAPON(<<"Bio Rifle">>       , 3, 0),
    ?WEAPON(<<"Shock Rifle">>     , 4, 0),
    ?WEAPON(<<"Pulse Gun">>       , 5, 0),
    ?WEAPON(<<"Ripper">>          , 6, 16),
    ?WEAPON(<<"Minigun">>         , 7, 0),
    ?WEAPON(<<"Flak Cannon">>     , 8, 30),
    ?WEAPON(<<"Rocket Launcher">> , 9, 6),
    ?WEAPON(<<"Sniper Rifle">>    , 0, 20)
}).

-define(WEAPON_FAILURE(Reason), #'WeaponFailure'{
    code   = <<"weapon_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(POWERUP_FAILURE(Reason), #'PowerupFailure'{
    code   = <<"powerup_error">>,
    reason = genlib:to_binary(Reason)
}).

%% Powerup service
-define(POWERUP(Name, Params),
    Name => #'Powerup'{name = Name, Params}
).

-define(POWERUPS, #{
    ?POWERUP(<<"Thigh Pads">>       , level = 23),
    ?POWERUP(<<"Body Armor">>       , level = 82),
    ?POWERUP(<<"Shield Belt">>      , level = 0),
    ?POWERUP(<<"AntiGrav Boots">>   , level = 2),
    ?POWERUP(<<"Damage Amplifier">> , time_left = 0),
    ?POWERUP(<<"Invisibility">>     , time_left = 0)
}).

-define(SERVER_IP      , {0, 0, 0, 0}).
-define(SERVER_PORT    , 8085).
-define(URL_BASE       , "0.0.0.0:8085").
-define(PATH_WEAPONS   , "/v1/woody/test/weapons").
-define(PATH_POWERUPS  , "/v1/woody/test/powerups").

-define(ROOT_REQ_PARENT_ID, <<"undefined">>).

-define(ERR_S_THRIFT_MULTIPLEX    , <<"thrift: multiplexing (not supported)">>).
-define(ERR_S_THRIFT_ENCODE       , <<"thrift: encode error">>).
-define(ERR_C_THRIFT              , <<"client thrift error">>).
-define(ERR_POWERUP_UNAVAILABLE   , <<"expired">>).
-define(ERR_POWERUP_STATE_UNKNOWN , <<"invisible">>).
-define(ERR_BAD_PROXYING          , <<"case_clause">>).

-define(WEAPON_STACK_OVERFLOW  , pos_out_of_boundaries).
-define(BAD_POWERUP_REPLY      , powerup_unknown).

%%
%% tests descriptions
%%
all() ->
    [
        context_given_rpc_id_test,
        context_given_trace_id_test,
        context_generated_rpc_id_test,
        ids_monotonic_incr_test,
        call_ok_test,
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
        call_with_client_pool_test,
        call_thrift_multiplexed_test,
        server_http_req_validation_test,
        try_bad_handler_spec_test
    ].

%%
%% starting/stopping
%%
init_per_suite(C) ->
    {ok, Apps} = application:ensure_all_started(woody),
    [{apps, Apps}|C].

end_per_suite(C) ->
    [application_stop(App) || App <- proplists:get_value(apps, C)].

application_stop(App=sasl) ->
    %% hack for preventing sasl deadlock
    %% http://erlang.org/pipermail/erlang-questions/2014-May/079012.html
    error_logger:delete_report_handler(cth_log_redirect),
    _ = application:stop(App),
    error_logger:add_report_handler(cth_log_redirect),
    ok;
application_stop(App) ->
    application:stop(App).

init_per_testcase(TC, C) when
      TC =:= try_bad_handler_spec_test     ;
      TC =:= context_given_rpc_id_test     ;
      TC =:= context_given_trace_id_test   ;
      TC =:= context_generated_rpc_id_test ;
      TC =:= ids_monotonic_incr_test       ;
      TC =:= call_client_error_test
->
    C;
init_per_testcase(TC, C) when
      TC =:= call_no_headers_404_test ;
      TC =:= call_no_headers_500_test ;
      TC =:= call_no_headers_502_test ;
      TC =:= call_no_headers_503_test ;
      TC =:= call_no_headers_504_test
->
    {ok, Sup} = start_tc_sup(),
    {ok, _} = start_error_server(TC, Sup),
    [{sup, Sup} | C];
init_per_testcase(_, C) ->
    {ok, Sup} = start_tc_sup(),
    {ok, _}   = start_woody_server(woody_ct, Sup, ['Weapons', 'Powerups']),
    [{sup, Sup} | C].

start_tc_sup() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_error_server(TC, Sup) ->
    Code      = get_fail_code(TC),
    Dispatch  = cowboy_router:compile([{'_', [{?PATH_WEAPONS, ?MODULE, Code}]}]),
    Server    = ranch:child_spec(woody_ct, 10, ranch_tcp,
                 [{ip, ?SERVER_IP}, {port, ?SERVER_PORT}],
                 cowboy_protocol, [{env, [{dispatch, Dispatch}]}]
             ),
    supervisor:start_child(Sup, Server).

start_woody_server(Id, Sup, Services) ->
    Server = woody_server:child_spec(Id, #{
        handlers      => [get_handler(S) || S <- Services],
        event_handler => ?MODULE,
        ip            => ?SERVER_IP,
        port          => ?SERVER_PORT
    }),
    supervisor:start_child(Sup, Server).

get_handler('Powerups') ->
    {
        ?PATH_POWERUPS,
        {{?THRIFT_DEFS, 'Powerups'}, ?MODULE}
    };

get_handler('Weapons') ->
    {
        ?PATH_WEAPONS,
        {{?THRIFT_DEFS, 'Weapons'}, {?MODULE, #{
            meta_test_id => <<"call_seq_with_context_meta">>}}
        }
    }.

get_fail_code(call_no_headers_404_test) -> 404;
get_fail_code(call_no_headers_500_test) -> 500;
get_fail_code(call_no_headers_502_test) -> 502;
get_fail_code(call_no_headers_503_test) -> 503;
get_fail_code(call_no_headers_504_test) -> 504.

end_per_test_case(_, C) ->
    case proplists:get_value(sup, C, undefined) of
        undefined ->
            ok;
        Sup ->
            exit(Sup, shutdown),
            Ref = monitor(process, Sup),
            receive
                {'DOWN', Ref, process, Sup, _Reason} ->
                    demonitor(Ref),
                    ok
            after 1000 ->
                    demonitor(Ref, [flush]),
                    error(exit_timeout)
            end
    end.

%%
%% tests
%%
context_given_rpc_id_test(_) ->
    ReqId = <<"context_given_rpc_id">>,
    RpcId = #{parent_id => ReqId, trace_id => ReqId, span_id => ReqId},
    #{
        rpc_id     := RpcId
    } = woody_context:new(RpcId).

context_given_trace_id_test(_) ->
    TraceId = <<"context_given_trace_id">>,
    #{
        rpc_id := #{parent_id := ?ROOT_REQ_PARENT_ID, span_id := _, trace_id := TraceId}
    } = woody_context:new(TraceId).

context_generated_rpc_id_test(_) ->
    #{
        rpc_id := #{parent_id := ?ROOT_REQ_PARENT_ID, span_id := _GenId1, trace_id := _GenId2}
    } = woody_context:new().

ids_monotonic_incr_test(_) ->
    TraceId   = <<"ids_monotonic_incr">>,
    ParentCtx = woody_context:new(TraceId),
    Children  = lists:map(fun(_) -> woody_context:new_child(ParentCtx) end, lists:seq(1, 10000)),
    SortFun   = fun(C1, C2) ->
                    Span1 = genlib:to_int(woody_context:get_rpc_id(span_id, C1)),
                    Span2 = genlib:to_int(woody_context:get_rpc_id(span_id, C2)),
                    Span1 < Span2
                end,
    Children = lists:sort(SortFun, Children).

call_ok_test(_) ->
    Gun = <<"Enforcer">>,
    gun_test_basic(<<"call_ok">>, Gun, {ok, genlib_map:get(Gun, ?WEAPONS)}, true).

call3_ok_test(_) ->
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun     = <<"Enforcer">>,
    Request = {Service, get_weapon, [Gun, self_to_bin()]},
    Opts    = #{url => Url, event_handler => ?MODULE},
    Expect  = {ok, genlib_map:get(Gun, ?WEAPONS)},
    Expect  = woody_client:call(Request, Opts).

call3_ok_default_ev_handler_test(_) ->
    {Url, Service} = get_service_endpoint('Weapons'),
    Gun     = <<"Enforcer">>,
    Request = {Service, get_weapon, [Gun, self_to_bin()]},
    Opts    = #{url => Url, event_handler => woody_event_handler_default},
    Expect  = {ok, genlib_map:get(Gun, ?WEAPONS)},
    Expect  = woody_client:call(Request, Opts).

call_business_error_test(_) ->
    Gun = <<"Bio Rifle">>,
    gun_test_basic(<<"call_business_error">>, Gun,
        {exception, ?WEAPON_FAILURE("out of ammo")}, true).

call_throw_unexpected_test(_) ->
    Id      = <<"call_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Context = make_context(Id),
    Error   = genlib:to_binary(?WEAPON_STACK_OVERFLOW),
    try call(Context, 'Weapons', switch_weapon, [Current, next, 1, self_to_bin()])
    catch
        error:{woody_error, {external, result_unexpected, Error}} -> ok
    end,
    {ok, _} = receive_msg(Current, Context).

call_system_external_error_test(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    gun_test_basic(<<"call_system_external_error">>, Gun,
        {error, {woody_error, {external, result_unexpected, <<"case_clause">>}}}, true).

call_client_error_test(_) ->
    Gun     = 'Wrong Type of Mega Destroyer',
    Context = make_context(<<"call_client_error">>),
    try call(Context, 'Weapons', get_weapon, [Gun, self_to_bin()])
    catch
        error:{woody_error, {internal, result_unexpected, ?ERR_C_THRIFT}} -> ok
    end.

call_server_internal_error_test(_) ->
    Armor   = <<"Helmet">>,
    Context = make_context(<<"call_server_internal_error">>),
    try call(Context, 'Powerups', get_powerup, [Armor, self_to_bin()])
    catch
        error:{woody_error, {external, result_unexpected, ?ERR_S_THRIFT_ENCODE}} -> ok
    end,
    {ok, _} = receive_msg(Armor, Context).

call_oneway_void_test(_) ->
    Armor   = <<"Helmet">>,
    Context = make_context(<<"call_oneway_void">>),
    {ok, ok} = call(Context, 'Powerups', like_powerup, [Armor, self_to_bin()]),
    {ok, _}  = receive_msg(Armor, Context).

call_sequence_with_context_meta_test(_) ->
    Gun     = <<"Enforcer">>,
    Current = genlib_map:get(Gun, ?WEAPONS),
    Context = woody_context:new(
                <<"call_seq_with_context_meta">>,
                #{genlib:to_binary(Current#'Weapon'.slot_pos) => Gun}),
    Expect = {ok, genlib_map:get(<<"Ripper">>, ?WEAPONS)},
    Expect = call(Context, 'Weapons', switch_weapon, [Current, next, 1, self_to_bin()]).

call_pass_thru_ok_test(_) ->
    Armor   = <<"AntiGrav Boots">>,
    Context = make_context(<<"call_pass_thru_ok">>),
    Expect  = {ok, genlib_map:get(Armor, ?POWERUPS)},
    Expect  = call(Context, 'Powerups', proxy_get_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_except_test(_) ->
    Armor   = <<"Shield Belt">>,
    Id      = <<"call_pass_thru_except">>,
    RpcId   = woody_context:new_rpc_id(?ROOT_REQ_PARENT_ID, Id, Id),
    Context = woody_context:new(RpcId),
    try call(Context, 'Powerups', proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{woody_error, {external, result_unexpected, ?ERR_BAD_PROXYING}} ->
            ok
    end,
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_bad_result_test(_) ->
    Armor    = <<"AntiGrav Boots">>,
    Context  = make_context(<<"call_pass_thru_bad_result">>),
    try call(Context, 'Powerups', bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{woody_error, {external, result_unexpected, ?ERR_S_THRIFT_ENCODE}} ->
            ok
    end,
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_bad_except_test(_) ->
    Armor    = <<"Shield Belt">>,
    Context  = make_context(<<"call_pass_thru_bad_except">>),
    try call(Context, 'Powerups', bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{woody_error, {external, result_unexpected, ?ERR_BAD_PROXYING}} ->
            ok
    end,
    {ok, _} = receive_msg(Armor, Context).

call_pass_thru_result_unexpected_test(_) ->
    call_pass_thru_error(<<"call_pass_thru_result_unexpected">>, <<"Helmet">>,
        error, result_unexpected, ?ERR_S_THRIFT_ENCODE).

call_pass_thru_resource_unavail_test(_) ->
    call_pass_thru_error(<<"call_pass_thru_resource_unavail">>, <<"Damage Amplifier">>,
        error, resource_unavailable, ?ERR_POWERUP_UNAVAILABLE).

call_pass_thru_result_unknown_test(_) ->
    call_pass_thru_error(<<"call_pass_thru_result_unknown">>, <<"Invisibility">>,
        error, result_unknown, ?ERR_POWERUP_STATE_UNKNOWN).

call_pass_thru_error(Id, Powerup, ExceptClass, ErrClass, ErrDetails) ->
    RpcId   = woody_context:new_rpc_id(?ROOT_REQ_PARENT_ID, Id, Id),
    Context = woody_context:new(RpcId),
    try call(Context, 'Powerups', proxy_get_powerup, [Powerup, self_to_bin()])
    catch
        ExceptClass:{woody_error, {external, ErrClass, ErrDetails}} ->
            ok
    end,
    {ok, _} = receive_msg(Powerup, Context).

call_no_headers_404_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_404">>, result_unexpected,
        <<"http code: 404">>).

call_no_headers_500_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_500">>, result_unexpected,
        <<"http code: 500">>).

call_no_headers_502_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_502">>, result_unexpected,
        <<"http code: 502">>).

call_no_headers_503_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_503">>, resource_unavailable,
        <<"http code: 503">>).

call_no_headers_504_test(_) ->
    call_fail_w_no_headers(<<"call_no_headers_404">>, result_unknown,
        <<"http code: 504">>).

call_fail_w_no_headers(Id, Class, Details) ->
    Gun     =  <<"Enforcer">>,
    Context = make_context(Id),
    {Url, Service} = get_service_endpoint('Weapons'),
    try woody_client:call({Service, get_weapon, [Gun, self_to_bin()]},
            #{url => Url, event_handler => ?MODULE}, Context)
    catch
        error:{woody_error, {external, Class, Details}} ->
            ok
    end.

call_with_client_pool_test(_) ->
    Pool    = guns,
    ok      = woody_client_thrift:start_pool(Pool, 10),
    Gun     =  <<"Enforcer">>,
    Context = make_context(<<"call_with_client_pool">>),
    {Url, Service} = get_service_endpoint('Weapons'),
    Expect = {ok, genlib_map:get(Gun, ?WEAPONS)},
    Expect = woody_client:call({Service, get_weapon, [Gun, self_to_bin()]},
                 #{url => Url, event_handler => ?MODULE, pool => Pool}, Context),
    {ok, _} = receive_msg(Gun, Context),
    ok = woody_client_thrift:stop_pool(Pool).

call_thrift_multiplexed_test(_) ->
    Client = make_thrift_multiplexed_client(<<"call_thrift_multiplexed">>,
                 "powerups", get_service_endpoint('Powerups')),
    {Client1, {error, {system, {external, result_unexpected, ?ERR_S_THRIFT_MULTIPLEX}}}} =
        thrift_client:call(Client, get_powerup, [<<"Body Armor">>, self_to_bin()]),
    thrift_client:close(Client1).

make_thrift_multiplexed_client(Id, ServiceName, {Url, Service}) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(
            woody_context:enrich(make_context(Id), ?MODULE),
            #{url => Url}
        ),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Protocol1} = thrift_multiplexed_protocol:new(Protocol, ServiceName),
    {ok, Context} = thrift_client:new(Protocol1, Service),
    Context.

server_http_req_validation_test(_) ->
    Id  = <<"server_http_req_validation">>,
    {Url, _Service} = get_service_endpoint('Weapons'),
    Headers = [
        {?HEADER_RPC_ROOT_ID   , genlib:to_binary(Id)},
        {?HEADER_RPC_ID        , genlib:to_binary(Id)},
        {?HEADER_RPC_PARENT_ID , genlib:to_binary(?ROOT_REQ_PARENT_ID)},
        {<<"content-type">>    , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>          , ?CONTENT_TYPE_THRIFT}
    ],

    %% Check missing Id headers, content-type and an empty body on the last step,
    %% as missing Accept is allowed
    lists:foreach(fun({C, H}) ->
        {ok, C, _, _} = hackney:request(post, Url, Headers -- [H], <<>>, [{url, Url}])
        end, lists:zip([400, 400, 400, 415, 400], Headers)),

    %% Check wrong Accept
    {ok, 406, _, _} = hackney:request(post, Url,
        lists:keyreplace(<<"accept">>, 1, Headers, {<<"accept">>, <<"application/text">>}),
        <<>>, [{url, Url}]),

    %% Check wrong methods
    lists:foreach(fun(M) ->
        {ok, 405, _, _} = hackney:request(M, Url, Headers, <<>>, [{url, Url}]) end,
        [get, put, delete, trace, options, patch]),
    {ok, 405, _}    = hackney:request(head, Url, Headers, <<>>, [{url, Url}]),
    {ok, 400, _, _} = hackney:request(connect, Url, Headers, <<>>, [{url, Url}]).

try_bad_handler_spec_test(_) ->
    NaughtyHandler = {?PATH_POWERUPS, {{'should', 'be'}, '3-tuple'}},
    try
        woody_server:child_spec('bad_spec', #{
            handlers      => [get_handler('Powerups'), NaughtyHandler],
            event_handler => ?MODULE,
            ip            => ?SERVER_IP,
            port          => ?SERVER_PORT
        })
    catch
        error:{bad_handler_spec, NaughtyHandler} ->
            ok
    end.


%%
%% supervisor callbacks
%%
init(_) ->
    {ok, {
        {one_for_one, 1, 1}, []
}}.

%%
%% woody_server_thrift_handler callbacks
%%

%% Weapons
handle_function(switch_weapon, [CurrentWeapon, Direction, Shift, To], Context, #{meta_test_id := AnnotTestId}) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), CurrentWeapon}),
    CheckAnnot = is_meta_check_required(AnnotTestId, woody_context:get_rpc_id(trace_id, Context)),
    ok = check_meta(CheckAnnot, Context, CurrentWeapon),
    switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot);

handle_function(get_weapon, [Name, To], Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    case genlib_map:get(Name, ?WEAPONS) of
        #'Weapon'{ammo = 0}  ->
            throw(?WEAPON_FAILURE("out of ammo"));
        Weapon = #'Weapon'{} ->
            {ok, Weapon}
    end;

%% Powerups
handle_function(get_powerup, [Name, To], Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    {ok, return_powerup(Name)};

handle_function(ProxyGetPowerup, [Name, To], Context, _Opts) when
    ProxyGetPowerup =:= proxy_get_powerup orelse
    ProxyGetPowerup =:= bad_proxy_get_powerup
->
    try call(Context, 'Powerups', get_powerup, [Name, self_to_bin()])
    catch
        Class:Reason ->
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    after
        {ok, _} = receive_msg(Name, Context),
        ok      = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name})
    end;

handle_function(like_powerup, [Name, To], Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(parent_id, Context), Name}),
    {ok, ok}.

%%
%% woody_event_handler callbacks
%%
handle_event(Event, RpcId = #{
    trace_id := TraceId, parent_id := ParentId}, Meta = #{code := Code}, _)
when
    (
        TraceId =:= <<"call_pass_thru_except">>               orelse
        TraceId =:= <<"call_pass_thru_resource_unavailable">> orelse
        TraceId =:= <<"call_pass_thru_result_unexpected">>    orelse
        TraceId =:= <<"call_pass_thru_result_unknown">>
    ) andalso
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
handle_proxy_event(?EV_SERVER_SEND,    500, <<"call_pass_thru_except">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 500, <<"call_pass_thru_result_unexpected">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND,    502, <<"call_pass_thru_result_unexpected">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 503, <<"call_pass_thru_resource_unavailable">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND,    502, <<"call_pass_thru_resource_unavailable">>) ->
    ok;
handle_proxy_event(?EV_CLIENT_RECEIVE, 504, <<"call_pass_thru_result_unknown">>) ->
    ok;
handle_proxy_event(?EV_SERVER_SEND,    502, <<"call_pass_thru_result_unknown">>) ->
    ok;
handle_proxy_event(Event, Code, Descr) ->
    erlang:error(badarg, [Event, Code, Descr]).

log_event(Event, RpcId, Meta) ->
    %% woody_event_handler_default:handle_event(Event, RpcId, Meta, []).
    {_Severity, {Format, Msg}} = woody_event_handler:format_event(Event, Meta, RpcId),
    ct:pal(Format, Msg).

%%
%% cowboy_http_handler callbacks
%%
init({_, http}, Req, Code) ->
    ct:pal("Cowboy fail server received request. Replying: ~p", [Code]),
    {ok, Req1} = cowboy_req:reply(Code, Req),
    {shutdown, Req1, Code}.

handle(Req, _) ->
    {ok, Req, neverhappen}.

terminate(_, _, _) ->
    ok.

%%
%% internal functions
%%
gun_test_basic(Id, Gun, Expect, WithMsg) ->
    Context   = make_context(Id),
    {Class, Reason} = get_except(Expect),
    try call(Context, 'Weapons', get_weapon, [Gun, self_to_bin()]) of
        Expect -> ok
    catch
        Class:Reason -> ok
    end,
    check_msg(WithMsg, Gun, Context).

get_except({ok, _}) ->
    {undefined, undefined};
get_except({exception, _}) ->
    {undefined, undefined};
get_except(Except = {_Class, _Reason}) ->
    Except.

make_context(ReqId) ->
    woody_context:new(ReqId).

call(Context, ServiceName, Function, Args) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    woody_client:call({Service, Function, Args}, #{url => Url, event_handler => ?MODULE}, Context).

get_service_endpoint('Weapons') ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_WEAPONS),
        {?THRIFT_DEFS, 'Weapons'}
    };
get_service_endpoint('Powerups') ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_POWERUPS),
        {?THRIFT_DEFS, 'Powerups'}
    }.

check_msg(true, Msg, Context) ->
    {ok, _} = receive_msg(Msg, Context);
check_msg(false, _, _) ->
    ok.

switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot) ->
    {NextWName, NextWPos} = next_weapon(CurrentWeapon, Direction, Shift),
    ContextAnnot = annotate_weapon(CheckAnnot, Context, NextWName, NextWPos),
    case call(ContextAnnot, 'Weapons', get_weapon, [NextWName, self_to_bin()]) of
        {exception, #'WeaponFailure'{code = <<"weapon_error">>, reason = <<"out of ammo">>}}
        ->
            switch_weapon(CurrentWeapon, Direction, Shift + 1, Context, CheckAnnot);
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
    {genlib_map:get(Pos, ?SLOTS, <<"no weapon">>), Pos};
next_weapon(_) ->
    throw(?WEAPON_STACK_OVERFLOW).

return_powerup(<<"Invisibility">>) ->
    woody_error:raise(system, {internal, result_unknown, ?ERR_POWERUP_STATE_UNKNOWN});
return_powerup(Name) when is_binary(Name) ->
    return_powerup(genlib_map:get(Name, ?POWERUPS, ?BAD_POWERUP_REPLY));
return_powerup(#'Powerup'{level = Level}) when Level == 0 ->
    throw(?POWERUP_FAILURE("run out"));
return_powerup(#'Powerup'{time_left = Time}) when Time == 0 ->
    woody_error:raise(system, {internal, resource_unavailable, ?ERR_POWERUP_UNAVAILABLE});
return_powerup(P = #'Powerup'{}) ->
    P;
return_powerup(P = ?BAD_POWERUP_REPLY) ->
    P.

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
    after 1000 ->
        error(get_msg_timeout)
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

