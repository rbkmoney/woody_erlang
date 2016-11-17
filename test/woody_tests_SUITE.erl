-module(woody_tests_SUITE).

-include_lib("common_test/include/ct.hrl").

-include("woody_test_thrift.hrl").
-include("src/woody_defs.hrl").

-behaviour(supervisor).
-behaviour(woody_server_thrift_handler).
-behaviour(woody_event_handler).

%% supervisor callbacks
-export([init/1]).

%% woody_server_thrift_handler callbacks
-export([handle_function/4]).

%% woody_event_handler callbacks
-export([handle_event/3]).

%% common test API
-export([all/0,
    init_per_suite/1, init_per_testcase/2, end_per_suite/1, end_per_test_case/2]).
-export([
    context_non_root_test/1,
    context_root_with_given_req_id_test/1,
    context_root_with_given_rpc_id_test/1,
    context_root_with_generated_rpc_id_test/1,
    call_safe_ok_test/1,
    call_ok_test/1,
    call_safe_handler_throw_test/1,
    call_handler_throw_test/1,
    call_safe_handler_throw_unexpected_test/1,
    call_handler_throw_unexpected_test/1,
    call_safe_handler_error_test/1,
    call_handler_error_test/1,
    call_safe_client_transport_error_test/1,
    call_client_transport_error_test/1,
    call_safe_server_transport_error_test/1,
    call_server_transport_error_test/1,
    call_oneway_void_test/1,
    call_async_ok_test/1,
    call_pass_through_ok_test/1,
    call_pass_through_except_test/1,
    call_no_pass_through_bad_ok_test/1,
    call_no_pass_through_bad_except_test/1,
    span_ids_sequence_test/1,
    span_ids_sequence_with_context_annotation_test/1,
    call_with_client_pool_test/1,
    multiplexed_transport_test/1,
    server_http_request_validation_test/1,
    try_bad_handler_spec/1
]).

%% internal API
-export([call/4, call_safe/4]).


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

-define(EXCEPT_WEAPON_FAILURE (Reason), {exception, ?WEAPON_FAILURE (Reason)}).
-define(EXCEPT_POWERUP_FAILURE(Reason), {exception, ?POWERUP_FAILURE(Reason)}).

-define(POS_ERROR, {pos_error, "pos out of boundaries"}).

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

-define(SERVER_IP     , {0, 0, 0, 0}).
-define(SERVER_PORT   , 8085).
-define(URL_BASE      , "0.0.0.0:8085").
-define(PATH_WEAPONS  , "/v1/woody/test/weapons").
-define(PATH_POWERUPS , "/v1/woody/test/powerups").

%%
%% tests descriptions
%%
all() ->
    [
        context_non_root_test,
        context_root_with_given_req_id_test,
        context_root_with_given_rpc_id_test,
        context_root_with_generated_rpc_id_test,
        call_safe_ok_test,
        call_ok_test,
        call_safe_handler_throw_test,
        call_handler_throw_test,
        call_safe_handler_throw_unexpected_test,
        call_handler_throw_unexpected_test,
        call_safe_handler_error_test,
        call_handler_error_test,
        call_safe_client_transport_error_test,
        call_client_transport_error_test,
        call_safe_server_transport_error_test,
        call_server_transport_error_test,
        call_oneway_void_test,
        call_async_ok_test,
        call_pass_through_ok_test,
        call_pass_through_except_test,
        call_no_pass_through_bad_ok_test,
        call_no_pass_through_bad_except_test,
        span_ids_sequence_test,
        span_ids_sequence_with_context_annotation_test,
        call_with_client_pool_test,
        multiplexed_transport_test,
        server_http_request_validation_test,
        try_bad_handler_spec
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

init_per_testcase(Tc, C) when
    Tc =:= try_bad_handler_spec
->
    C;
init_per_testcase(_, C) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    {ok, _}   = start_woody_server(woody_ct, Sup, ['Weapons', 'Powerups']),
    [{sup, Sup} | C].

start_woody_server(Id, Sup, Services) ->
    Server = woody_server:child_spec(Id, #{
        handlers      => [get_handler(S) || S <- Services],
        event_handler => ?MODULE,
        ip            => ?SERVER_IP,
        port          => ?SERVER_PORT,
        net_opts      => []
    }),
    {ok, _} = supervisor:start_child(Sup, Server).

get_handler('Powerups') ->
    {
        ?PATH_POWERUPS,
        {{?THRIFT_DEFS, 'Powerups'}, ?MODULE, []}
    };

get_handler('Weapons') ->
    {
        ?PATH_WEAPONS,
        {{?THRIFT_DEFS, 'Weapons'}, ?MODULE, #{
            annotation_test_id => <<"span_ids_sequence_with_context_annotation">>}
        }
    }.

end_per_test_case(_, C) ->
    Sup = proplists:get_value(sup, C),
    exit(Sup, shutdown),
    Ref = monitor(process, Sup),
    receive
        {'DOWN', Ref, process, Sup, _Reason} ->
            demonitor(Ref),
            ok
    after 1000 ->
        demonitor(Ref, [flush]),
        error(exit_timeout)
    end.


%%
%% tests
%%
context_non_root_test(_) ->
    ReqId = <<"context_non_root">>,
    RpcId = woody_context:make_rpc_id(ReqId, ReqId, ReqId),
    Expect = #{
        root_rpc => false,
        rpc_id => RpcId,
        seq => 0,
        event_handler => ?MODULE
    },
    Expect = woody_context:new(RpcId, ?MODULE).

context_root_with_given_req_id_test(_) ->
    ReqId = <<"context_root_with_given_req_id">>,
    Expect = #{
        root_rpc => true,
        rpc_id => #{parent_id => <<"undefined">>, span_id => ReqId, trace_id => ReqId},
        seq => 0,
        event_handler => ?MODULE
    },
    Expect = woody_context:new(ReqId, ?MODULE).

context_root_with_given_rpc_id_test(_) ->
    ReqId = <<"context_root_with_given_rpc_id">>,
    RpcId = woody_context:make_rpc_id(<<"undefined">>, ReqId, ReqId),
    Expect = #{
        root_rpc => true,
        rpc_id => RpcId,
        seq => 0,
        event_handler => ?MODULE
    },
    Expect = woody_context:new(RpcId, ?MODULE).

context_root_with_generated_rpc_id_test(_) ->
    ReqId = undefined,
    #{
        root_rpc      := true,
        event_handler := ?MODULE,
        seq           := 0,
        rpc_id        := #{
            parent_id := <<"undefined">>,
            span_id   := Generated,
            trace_id  := Generated
        }
    } = woody_context:new(ReqId, ?MODULE).

call_safe_ok_test(_) ->
    Gun =  <<"Enforcer">>,
    gun_test_basic(call_safe, <<"call_safe_ok">>, Gun,
        genlib_map:get(Gun, ?WEAPONS), true).

call_ok_test(_) ->
    Gun = <<"Enforcer">>,
    gun_test_basic(call, <<"call_ok">>, Gun,
        genlib_map:get(Gun, ?WEAPONS), true).

call_safe_handler_throw_test(_) ->
    Gun = <<"Bio Rifle">>,
    gun_test_basic(call_safe, <<"call_safe_handler_throw">>, Gun,
        ?EXCEPT_WEAPON_FAILURE("out of ammo"), true).

call_handler_throw_test(_) ->
    Gun = <<"Bio Rifle">>,
    gun_catch_test_basic(<<"call_handler_throw">>, Gun,
        {throw, ?EXCEPT_WEAPON_FAILURE("out of ammo")}, true).

call_safe_handler_throw_unexpected_test(_) ->
    Id      = <<"call_safe_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {{error, ?ERROR_TRANSPORT(server_error)}, Context#{child_rpc_id => RpcId}},
    Expect  = call_safe(Context, 'Weapons', switch_weapon,
        [Current, next, 1, self_to_bin()]),
    {ok, _} = receive_msg({Id, Current}).

call_handler_throw_unexpected_test(_) ->
    Id      = <<"call_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {?ERROR_TRANSPORT(server_error), Context#{child_rpc_id => RpcId}},
    try call(Context, 'Weapons', switch_weapon, [Current, next, 1, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Current}).

call_safe_handler_error_test(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    gun_test_basic(call_safe, <<"call_safe_handler_error">>, Gun,
        {error, ?ERROR_TRANSPORT(server_error)}, true).

call_handler_error_test(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    gun_catch_test_basic(<<"call_handler_error">>, Gun,
        {error, ?ERROR_TRANSPORT(server_error)}, true).

call_safe_client_transport_error_test(_) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Id  = <<"call_safe_client_transport_error">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Context1 = Context#{child_rpc_id => RpcId},
    {{error, ?ERROR_PROTOCOL(_)}, Context1} = call_safe(Context,
        'Weapons', get_weapon, [Gun, self_to_bin()]).

call_client_transport_error_test(_) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Id  = <<"call_client_transport_error">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Context1 = Context#{child_rpc_id => RpcId},
    try call(Context, 'Weapons', get_weapon, [Gun, self_to_bin()])
    catch
        error:{?ERROR_PROTOCOL(_), Context1} -> ok
    end.

call_safe_server_transport_error_test(_) ->
    Id      = <<"call_safe_server_transport_error">>,
    Armor   = <<"Helmet">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {{error, ?ERROR_TRANSPORT(server_error)}, Context#{child_rpc_id => RpcId}},
    Expect  = call_safe(Context, 'Powerups', get_powerup,
        [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_server_transport_error_test(_) ->
    do_call_server_transport_error(<<"call_server_transport_error">>).

do_call_server_transport_error(Id) ->
    Armor   = <<"Helmet">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {?ERROR_TRANSPORT(server_error), Context#{child_rpc_id => RpcId}},
    try call(Context, 'Powerups', get_powerup, [Armor, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Armor}).

call_oneway_void_test(_) ->
    Id      = <<"call_oneway_void_test">>,
    Armor   = <<"Helmet">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {ok, Context#{child_rpc_id => RpcId}},
    Expect  = call(Context, 'Powerups', like_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_async_ok_test(C) ->
    Sup        = proplists:get_value(sup, C),
    Pid        = self(),
    Callback   = fun(Res) -> collect(Res, Pid) end,
    Id1        = <<"call_async_ok1">>,
    Context1   =  #{rpc_id := RpcId1} = make_context(Id1),
    Context1Exp =  Context1#{child_rpc_id => RpcId1},
    {ok, Pid1, Context1Exp} = get_weapon(Context1, Sup, Callback, <<"Impact Hammer">>),
    Id2        = <<"call_async_ok2">>,
    Context2   = make_context(Id2),
    Context2   =  #{rpc_id := RpcId2} = make_context(Id2),
    Context2Exp =  Context2#{child_rpc_id => RpcId2},
    {ok, Pid2, Context2Exp} = get_weapon(Context2, Sup, Callback, <<"Flak Cannon">>),
    {ok, Pid1} = receive_msg({Context1Exp,
        genlib_map:get(<<"Impact Hammer">>, ?WEAPONS)}),
    {ok, Pid2} = receive_msg({Context2Exp,
        genlib_map:get(<<"Flak Cannon">>, ?WEAPONS)}).

get_weapon(Context, Sup, Cb, Gun) ->
    call_async(Context, 'Weapons', get_weapon, [Gun, <<>>], Sup, Cb).

collect({Result, Context}, Pid) ->
    ok = send_msg(Pid, {Context, Result}).

span_ids_sequence_test(_) ->
    Id      = <<"span_ids_sequence">>,
    Current = genlib_map:get(<<"Enforcer">>, ?WEAPONS),
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {genlib_map:get(<<"Ripper">>, ?WEAPONS), Context#{child_rpc_id => RpcId}},
    Expect  = call(Context, 'Weapons', switch_weapon,
        [Current, next, 1, self_to_bin()]).

span_ids_sequence_with_context_annotation_test(_) ->
    Id      = <<"span_ids_sequence_with_context_annotation">>,
    Gun     = <<"Enforcer">>,
    Current = genlib_map:get(Gun, ?WEAPONS),
    Context = #{rpc_id := RpcId} = woody_context:new(
        Id, ?MODULE, #{genlib:to_binary(Current#'Weapon'.slot_pos) => Gun}),
    Expect  = {genlib_map:get(<<"Ripper">>, ?WEAPONS), Context#{child_rpc_id => RpcId}},
    Expect  = call(Context, 'Weapons', switch_weapon,
        [Current, next, 1, self_to_bin()]).

call_with_client_pool_test(_) ->
    Pool = guns,
    ok   = woody_client_thrift:start_pool(Pool, 10),
    Id   = <<"call_with_client_pool">>,
    Gun  =  <<"Enforcer">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    {Url, Service} = get_service_endpoint('Weapons'),
    Expect = {genlib_map:get(Gun, ?WEAPONS), Context#{child_rpc_id => RpcId}},
    Expect = woody_client:call(
        Context,
        {Service, get_weapon, [Gun, self_to_bin()]},
        #{url => Url, pool => Pool}
    ),
    {ok, _} = receive_msg({Id, Gun}),
    ok = woody_client_thrift:stop_pool(Pool).

multiplexed_transport_test(_) ->
    Id  = <<"multiplexed_transport">>,
    {Client1, {error, ?ERROR_TRANSPORT(bad_request)}} = thrift_client:call(
        make_thrift_multiplexed_client(Id, "powerups",
            get_service_endpoint('Powerups')),
        get_powerup,
        [<<"Body Armor">>, self_to_bin()]
    ),
    thrift_client:close(Client1).

make_thrift_multiplexed_client(Id, ServiceName, {Url, Service}) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(
            woody_context:next(woody_context:new(Id, ?MODULE)),
            #{url => Url}
        ),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Protocol1} = thrift_multiplexed_protocol:new(Protocol, ServiceName),
    {ok, Context} = thrift_client:new(Protocol1, Service),
    Context.

server_http_request_validation_test(_) ->
    Id  = <<"server_http_request_validation">>,
    {Url, _Service} = get_service_endpoint('Weapons'),
    Headers = [
        {?HEADER_NAME_RPC_ROOT_ID   , genlib:to_binary(Id)},
        {?HEADER_NAME_RPC_ID        , genlib:to_binary(Id)},
        {?HEADER_NAME_RPC_PARENT_ID , genlib:to_binary(<<"undefined">>)},
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT}
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

call_pass_through_ok_test(_) ->
    Id      = <<"call_pass_through_ok">>,
    Armor   = <<"AntiGrav Boots">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {genlib_map:get(Armor, ?POWERUPS), Context#{child_rpc_id => RpcId}},
    Expect  = call(Context, 'Powerups', proxy_get_powerup, [Armor, self_to_bin()]).

call_pass_through_except_test(_) ->
    Id      = <<"call_pass_through_except">>,
    Armor   = <<"Shield Belt">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect = {?EXCEPT_POWERUP_FAILURE("run out"), Context#{child_rpc_id => RpcId}},
    try call(Context, 'Powerups', proxy_get_powerup, [Armor, self_to_bin()])
    catch
        throw:Expect -> ok
    end.

call_no_pass_through_bad_ok_test(_) ->
    Id      = <<"call_no_pass_through_bad_ok">>,
    Armor   = <<"AntiGrav Boots">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Context1 = Context#{child_rpc_id => RpcId},
    try call(Context, 'Powerups', bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{?ERROR_TRANSPORT(server_error), Context1} ->
            ok
    end.

call_no_pass_through_bad_except_test(_) ->
    Id      = <<"call_no_pass_through_bad_except">>,
    Armor   = <<"Shield Belt">>,
    Context = #{rpc_id := RpcId} = make_context(Id),
    Context1 = Context#{child_rpc_id => RpcId},
    try call(Context, 'Powerups', bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{?ERROR_TRANSPORT(server_error), Context1} ->
            ok
    end.

try_bad_handler_spec(_) ->
    NaughtyHandler = {?PATH_POWERUPS, {{'should', 'be'}, '3-tuple'}},
    try
        woody_server:child_spec('bad_spec', #{
            handlers      => [get_handler('Powerups'), NaughtyHandler],
            event_handler => ?MODULE,
            ip            => ?SERVER_IP,
            port          => ?SERVER_PORT,
            net_opts      => []
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
handle_function(switch_weapon, {CurrentWeapon, Direction, Shift, To}, Context, #{annotation_test_id := AnnotTestId}) ->
    ok = send_msg(To, {woody_context:get_rpc_id(span_id, Context), CurrentWeapon}),
    CheckAnnot = is_annotation_check_required(AnnotTestId, woody_context:get_rpc_id(trace_id, Context)),
    ok = check_annotation(CheckAnnot, Context, CurrentWeapon),
    switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot);

handle_function(get_weapon, {Name, To}, Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(span_id, Context), Name}),
    Res = case genlib_map:get(Name, ?WEAPONS) of
        #'Weapon'{ammo = 0}  ->
            throw({?WEAPON_FAILURE("out of ammo"), Context});
        Weapon = #'Weapon'{} ->
            Weapon
    end,
    {Res, Context};

%% Powerups
handle_function(get_powerup, {Name, To}, Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(span_id, Context), Name}),
    {return_powerup(Name, Context), Context};

handle_function(ProxyGetPowerup, {Name, To}, Context, _Opts) when
    ProxyGetPowerup =:= proxy_get_powerup orelse
    ProxyGetPowerup =:= bad_proxy_get_powerup
->
    call(Context, 'Powerups', get_powerup, [Name, To]);

handle_function(like_powerup, {Name, To}, Context, _Opts) ->
    ok = send_msg(To, {woody_context:get_rpc_id(span_id, Context), Name}),
    {ok, Context}.

%%
%% woody_event_handler callbacks
%%
handle_event(Type, RpcId, Meta) ->
    ct:pal(info, "woody event ~p for RPC ID: ~p~n~p", [Type, RpcId, Meta]).

%%
%% internal functions
%%
make_context(ReqId) ->
    woody_context:new(ReqId, ?MODULE).

call(Context, ServiceName, Function, Args) ->
    do_call(call, Context, ServiceName, Function, Args).

call_safe(Context, ServiceName, Function, Args) ->
    do_call(call_safe, Context, ServiceName, Function, Args).

do_call(Call, Context, ServiceName, Function, Args) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    woody_client:Call(
        Context,
        {Service, Function, Args},
        #{url => Url}
    ).

call_async(Context, ServiceName, Function, Args, Sup, Callback) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    woody_client:call_async(Sup, Callback,
        Context,
        {Service, Function, Args},
        #{url => Url}
    ).

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

gun_test_basic(CallFun, Id, Gun, ExpectRes, WithMsg) ->
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {ExpectRes, Context#{child_rpc_id => RpcId}},
    Expect  = ?MODULE:CallFun(Context, 'Weapons', get_weapon, [Gun, self_to_bin()]),
    check_msg(WithMsg, Id, Gun).

gun_catch_test_basic(Id, Gun, {Class, Exception}, WithMsg) ->
    Context = #{rpc_id := RpcId} = make_context(Id),
    Expect  = {Exception, Context#{child_rpc_id => RpcId}},
    try call(Context, 'Weapons', get_weapon, [Gun, self_to_bin()])
    catch
        Class:Expect -> ok
    end,
    check_msg(WithMsg, Id, Gun).

check_msg(true, Id, Gun) ->
    {ok, _} = receive_msg({Id, Gun});
check_msg(false, _, _) ->
    ok.

switch_weapon(CurrentWeapon, Direction, Shift, Context, CheckAnnot) ->
    {NextWName, NextWPos} = next_weapon(CurrentWeapon, Direction, Shift, Context),
    ContextAnnot = annotate_weapon(CheckAnnot, Context, NextWName, NextWPos),
    case call_safe(ContextAnnot, 'Weapons', get_weapon,
             [NextWName, self_to_bin()])
    of
        {{exception, #'WeaponFailure'{
            code   = <<"weapon_error">>,
            reason = <<"out of ammo">>
        }}, NextContex} ->
            ok = validate_next_context(CheckAnnot, NextContex, Context),
            switch_weapon(CurrentWeapon, Direction, Shift + 1, NextContex, CheckAnnot);
        ResultOk = {_Weapon, _NextContext} ->
            ResultOk
    end.

annotate_weapon(true, Context, WName, WPos) ->
    woody_context:annotate(Context, #{genlib:to_binary(WPos) => WName});
annotate_weapon(_, Context, _, _) ->
    Context.

next_weapon(#'Weapon'{slot_pos = Pos}, next, Shift, Ctx) ->
    next_weapon(Pos + Shift, Ctx);
next_weapon(#'Weapon'{slot_pos = Pos}, prev, Shift, Ctx) ->
    next_weapon(Pos - Shift, Ctx).

next_weapon(Pos, _) when is_integer(Pos), Pos >= 0, Pos < 10 ->
    {genlib_map:get(Pos, ?SLOTS, <<"no weapon">>), Pos};
next_weapon(_, Context) ->
    throw({?POS_ERROR, Context}).

validate_next_context(true, #{seq := NextSeq, annotation := NextAnnot}, #{seq := Seq, annotation := Annot}) ->
    NextSeq = Seq + 1,
    NextAnnot = maps:merge(NextAnnot, Annot), %% check that Annot map is a submap of NextAnnot
    ok;
validate_next_context(false, #{seq := NextSeq}, #{seq := Seq}) ->
    NextSeq = Seq + 1,
    ok.

-define(BAD_POWERUP_REPLY, powerup_unknown).

return_powerup(Name, Context) when is_binary(Name) ->
    return_powerup(genlib_map:get(Name, ?POWERUPS, ?BAD_POWERUP_REPLY), Context);
return_powerup(#'Powerup'{level = Level}, Context) when Level == 0 ->
    throw({?POWERUP_FAILURE("run out"), Context});
return_powerup(#'Powerup'{time_left = Time}, Context) when Time == 0 ->
    throw({?POWERUP_FAILURE("expired"), Context});
return_powerup(P = #'Powerup'{}, _) ->
    P;
return_powerup(P = ?BAD_POWERUP_REPLY, _) ->
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

receive_msg(Msg) ->
    receive
        {From, Msg} ->
            {ok, From}
    after 1000 ->
        error(get_msg_timeout)
    end.

is_annotation_check_required(AnnotTestId, AnnotTestId) ->
    true;
is_annotation_check_required(_, _) ->
    false.

check_annotation(true, Context, #'Weapon'{name = WName, slot_pos = WSlot}) ->
    WSlotBin = genlib:to_binary(WSlot),
    WName = woody_context:annotation(WSlotBin, Context),
    ok;
check_annotation(_, _, _) ->
    ok.
