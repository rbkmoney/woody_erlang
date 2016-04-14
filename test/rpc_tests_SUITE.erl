-module(rpc_tests_SUITE).

-include_lib("common_test/include/ct.hrl").

-include("rpc_test_types.hrl").

-compile(export_all).

-behaviour(supervisor).
-behaviour(rpc_thrift_handler).
-behaviour(rpc_event_handler).

%% supervisor callbacks
-export([init/1]).

%% rpc_thrift_handler callbacks
-export([handle_function/4]).
-export([handle_error/4]).

%% rpc_event_handler callbacks
-export([handle_event/2]).

%% internal API
-export([call/4, call_safe/4]).

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

-define(weapon(Name, Pos, Ammo), Name => #weapon{
    name = Name,
    slot_pos = Pos,
    ammo = Ammo
}).
-define(weapon(Name, Pos), ?weapon(Name, Pos, undefined)).

-define(WEAPONS, #{
    ?weapon(<<"Impact Hammer">>, 1),
    ?weapon(<<"Enforcer">>, 2, 25),
    ?weapon(<<"Bio Rifle">>, 3, 0),
    ?weapon(<<"Shock Rifle">>, 4, 0),
    ?weapon(<<"Pulse Gun">>, 5, 0),
    ?weapon(<<"Ripper">>, 6, 16),
    ?weapon(<<"Minigun">>, 7, 0),
    ?weapon(<<"Flak Cannon">>, 8, 30),
    ?weapon(<<"Rocket Launcher">>, 9, 6),
    ?weapon(<<"Sniper Rifle">>, 0, 20)
}).

-define(weapon_failure(Reason), #failure{
    code = <<"weapon_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(pos_error, {pos_error, "pos out of boundaries"}).

%% Powerup service
-define(powerup(Name, Params),
    Name => #powerup{name = Name, Params}
).

-define(POWERUPS, #{
    ?powerup(<<"Thigh Pads">>, level = 23),
    ?powerup(<<"Body Armor">>, level = 82),
    ?powerup(<<"Shield Belt">>, level = 0),
    ?powerup(<<"AntiGrav Boots">>, level = 2),
    ?powerup(<<"Damage Amplifier">>, time_left = 0),
    ?powerup(<<"Invisibility">>, time_left = 0)
}).


-define(SERVER_IP, {0,0,0,0}).
-define(SERVER_PORT, 8085).
-define(URL_BASE, "0.0.0.0:8085").
-define(PATH_WEAPONS, "/v1/rpc/test/weapons").
-define(PATH_POWERUPS, "/v1/rpc/test/powerups").

%%
%% tests descriptions
%%
all() ->
    [
        call_safe_ok,
        call_ok,
        call_safe_handler_throw,
        call_handler_throw,
        call_safe_handler_throw_unexpected,
        call_handler_throw_unexpected,
        call_safe_handler_error,
        call_handler_error,
        call_safe_client_transport_error,
        call_client_transport_error,
        call_safe_server_transport_error,
        call_server_transport_error,
        call_async_ok,
        checkrpc_ids_sequence,
        call_two_services,
        call_with_client_pool
    ].

%%
%% starting/stopping
%%
init_per_suite(C) ->
    {ok, Apps} = application:ensure_all_started(rpc),
    [{apps, Apps}|C].

end_per_suite(C) ->
    [application_stop(App) || App <- proplists:get_value(apps, C)].

application_stop(App=sasl) ->
    %% hack for preventing sasl deadlock
    %% http://erlang.org/pipermail/erlang-questions/2014-May/079012.html
    error_logger:delete_report_handler(cth_log_redirect),
    application:stop(App),
    error_logger:add_report_handler(cth_log_redirect),
    ok;
application_stop(App) ->
    application:stop(App).

init_per_testcase(Tc, C) when
    Tc =:= call_safe_server_transport_error ;
    Tc =:= call_server_transport_error
->
    do_init_per_testcase([powerups], C);
init_per_testcase(Tc, C) when
    Tc =:= call_two_services
->
    do_init_per_testcase([weapons, powerups], C);
init_per_testcase(_, C) ->
    do_init_per_testcase([weapons], C).

do_init_per_testcase(Services, C) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    {ok, _} = start_rpc_server(rpc_ct, Sup, Services),
    [{sup, Sup} | C].

start_rpc_server(Id, Sup, Services) ->
    Server = rpc_server:child_spec(Id, #{
        handlers => [get_handler(S) || S <- Services],
        event_handler => ?MODULE,
        ip => ?SERVER_IP,
        port => ?SERVER_PORT,
        net_opts => []
    }),
    {ok, _} = supervisor:start_child(Sup, Server).

get_handler(powerups) ->
    {
        ?PATH_POWERUPS,
        {rpc_test_powerups_service, ?MODULE, []}
    };
get_handler(weapons) ->
    {
        ?PATH_WEAPONS,
        {rpc_test_weapons_service, ?MODULE, []}
    }.

end_per_test_case(_,C) ->
    Sup = proplists:get_value(sup, C),
    exit(Sup, shutdown),
    Ref = monitor(process, Sup),
    receive
        {'DOWN', Ref, process, Sup, _Reason} ->
        ok
    after 1000 ->
        error(exit_timeout)
    end.


%%
%% tests
%%
call_safe_ok(_) ->
    Gun =  <<"Enforcer">>,
    basic_gun_test(call_safe, <<"call_safe_ok">>, Gun, {ok, genlib_map:get(Gun, ?WEAPONS)}, true).

call_ok(_) ->
    Gun = <<"Enforcer">>,
    basic_gun_test(call, <<"call_ok">>, Gun, {ok, genlib_map:get(Gun, ?WEAPONS)}, true).

call_safe_handler_throw(_) ->
    Gun = <<"Bio Rifle">>,
    basic_gun_test(call_safe, <<"call_safe_handler_throw">>, Gun, {throw, ?weapon_failure("out of ammo")}, true).

call_handler_throw(_) ->
    Gun = <<"Bio Rifle">>,
    basic_gun_catch_test(<<"call_handler_throw">>, Gun, {throw, ?weapon_failure("out of ammo")}, true).

call_safe_handler_throw_unexpected(_) ->
    Id = <<"call_safe_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Client = get_client(Id),
    Expect = {error, rpc_failed, Client#{req_id => Id}},
    Expect = call_safe(Client, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]),
    {ok, _} = receive_msg({Id, Current}).

call_handler_throw_unexpected(_) ->
    Id = <<"call_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Client = get_client(Id),
    Expect = {rpc_failed, Client#{req_id => Id}},
    try call(Client, weapons, switch_weapon, [Current, next, 1, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Current}).

call_safe_handler_error(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    basic_gun_test(call_safe, <<"call_safe_handler_error">>, Gun, {error, rpc_failed}, true).

call_handler_error(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    basic_gun_catch_test(<<"call_handler_error">>, Gun, {error, rpc_failed}, true).

call_safe_client_transport_error(_) ->
    Gun = 'The Ultimate Super Mega Destroyer',
    basic_gun_test(call_safe, <<"call_safe_client_transport_error">>, Gun, {error, rpc_failed}, false).

call_client_transport_error(_) ->
    Gun = 'The Ultimate Super Mega Destroyer',
    basic_gun_catch_test(<<"call_client_transport_error">>, Gun, {error, rpc_failed}, false).

call_safe_server_transport_error(_) ->
    Id = <<"call_safe_server_transport_error">>,
    Armor = <<"Helmet">>,
    Client = get_client(Id),
    Client1 = Client#{req_id => Id},
    {error, rpc_failed , Client1} = call_safe(Client, powerups, get_powerup,
        [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_server_transport_error(_) ->
    Id = <<"call_server_transport_error">>,
    Armor = <<"Helmet">>,
    Client = get_client(Id),
    Client1 = Client#{req_id => Id},
    try call(Client, powerups, get_powerup, [Armor, self_to_bin()])
    catch
        error:{rpc_failed, Client1} -> ok
    end,
    {ok, _} = receive_msg({Id, Armor}).

call_async_ok(C) ->
    Sup = proplists:get_value(sup, C),
    Pid = self(),
    Callback = fun(Res) -> collect(Res, Pid) end,
    Id1 = <<"call_async_ok1">>,
    Client1 = get_client(Id1),
    Client11 = Client1#{req_id => Id1},
    {ok, Pid1, Client11} = get_weapon(Client1, Sup, Callback, <<"Impact Hammer">>),
    Id2 = <<"call_async_ok2">>,
    Client2 = get_client(Id2),
    Client22 = Client2#{req_id => Id2},
    {ok, Pid2, Client22} = get_weapon(Client2, Sup, Callback, <<"Flak Cannon">>),
    {ok, Pid1} = receive_msg({Client11, genlib_map:get(<<"Impact Hammer">>, ?WEAPONS)}),
    {ok, Pid2} = receive_msg({Client22, genlib_map:get(<<"Flak Cannon">>, ?WEAPONS)}).

get_weapon(Client, Sup, Cb, Gun) ->
    call_async(Client, weapons, get_weapon, [Gun, <<>>], Sup, Cb).

collect({ok, Result, Tag}, Pid) ->
    send_msg(Pid, {Tag, Result}).

checkrpc_ids_sequence(_) ->
    Id = <<"checkrpc_ids_sequence">>,
    Current = genlib_map:get(<<"Enforcer">>, ?WEAPONS),
    Client = get_client(Id),
    Expect = {ok, genlib_map:get(<<"Ripper">>, ?WEAPONS), Client#{req_id => Id}},
    Expect = call(Client, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]).

call_two_services(_) ->
    Gun =  <<"Enforcer">>,
    basic_gun_test(call_safe, <<"two_services1">>, Gun, {ok, genlib_map:get(Gun, ?WEAPONS)}, true),
    Id = <<"two_services2">>,
    Armor = <<"Body Armor">>,
    Client = get_client(Id),
    Expect = {ok, genlib_map:get(<<"Body Armor">>, ?POWERUPS), Client#{req_id => Id}},
    Expect = call_safe(Client, powerups, get_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_with_client_pool(_) ->
    Pool = guns,
    ok = rpc_thrift_client:start_pool(Pool, 10),
    Id = <<"call_with_client_pool">>,
    Gun =  <<"Enforcer">>,
    Client = get_client(Id),
    {Url, Service} = get_service_endpoint(weapons),
    Expect = {ok, genlib_map:get(Gun, ?WEAPONS), Client#{req_id => Id}},
    Expect = rpc_client:call(
        Client,
        {Service, get_weapon, [Gun, self_to_bin()]},
        #{url => Url, pool => Pool}
    ),
    receive_msg({Id, Gun}),
    ok = rpc_thrift_client:stop_pool(Pool).

%%
%% supervisor callbacks
%%
init(_) ->
    {ok, {
        {one_for_one, 1, 1}, []
}}.

%%
%% rpc_thrift_handler callbacks
%%

%% Weapons
handle_function(switch_weapon, RpcClient = #{parent_req_id := PaReqId},
    {CurrentWeapon, Direction, Shift, To}, _Opts
) ->
    send_msg(To, {PaReqId, CurrentWeapon}),
    switch_weapon(CurrentWeapon, Direction, Shift, RpcClient);

handle_function(get_weapon, #{parent_req_id := PaReqId},
    {Name, To}, _Opts)
->
    send_msg(To,{PaReqId,Name}),
    Res = case genlib_map:get(Name, ?WEAPONS) of
        #weapon{ammo = 0} ->
            throw(?weapon_failure("out of ammo"));
        Weapon = #weapon{} ->
            Weapon
    end,
    {ok, Res};

%% Powerups
handle_function(get_powerup, #{parent_req_id := PaReqId}, {Name, To}, _Opts) ->
    send_msg(To, {PaReqId, Name}),
    {ok, genlib_map:get(Name, ?POWERUPS, powerup_unknown)}.

handle_error(_Function, _RpcId, _Reason, _Opts) ->
    ok.


%%
%% rpc_event_handler callbacks
%%
handle_event(Type, Meta) ->
    ct:pal(info, "rpc event ~p: ~p", [Type, Meta]).

%%
%% internal functions
%%
get_client(ReqId) ->
    rpc_client:new(ReqId, ?MODULE).

call(Client, ServiceName, Function, Args) ->
    do_call(call, Client, ServiceName, Function, Args).

call_safe(Client, ServiceName, Function, Args) ->
    do_call(call_safe, Client, ServiceName, Function, Args).

do_call(Call, Client, ServiceName, Function, Args) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    rpc_client:Call(
        Client,
        {Service, Function, Args},
        #{url => Url}
    ).

call_async(Client, ServiceName, Function, Args, Sup, Callback) ->
    {Url, Service} = get_service_endpoint(ServiceName),
    rpc_client:call_async(Sup, Callback,
        Client,
        {Service, Function, Args},
        #{url => Url}
    ).

get_service_endpoint(weapons) ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_WEAPONS),
        rpc_test_weapons_service
    };
get_service_endpoint(powerups) ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_POWERUPS),
        rpc_test_powerups_service
    }.

basic_gun_test(CallFun, Id, Gun, {ExpectStatus, ExpectRes}, WithMsg) ->
    Client = get_client(Id),
    Expect = {ExpectStatus, ExpectRes, Client#{req_id => Id}},
    Expect = ?MODULE:CallFun(Client, weapons, get_weapon, [Gun, self_to_bin()]),
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _ -> ok
    end.

basic_gun_catch_test(Id, Gun, {Class, Exception}, WithMsg) ->
    Client = get_client(Id),
    Expect = {Exception, Client#{req_id => Id}},
    try call(Client, weapons, get_weapon, [Gun, self_to_bin()])
    catch
        Class:Expect -> ok
    end,
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _ -> ok
    end.

switch_weapon(CurrentWeapon, Direction, Shift, RpcClient) ->
    case call_safe(RpcClient, weapons, get_weapon,
             [new_weapon_name(CurrentWeapon, Direction, Shift), self_to_bin()])
    of
        {ok, Weapon, _} ->
            {ok, Weapon};
        {throw, #failure{
            code = <<"weapon_error">>,
            reason = <<"out of ammo">>
        }, NextClient} ->
            ok = validate_next_client(NextClient, RpcClient),
            switch_weapon(CurrentWeapon, Direction, Shift + 1, NextClient)
    end.

new_weapon_name(#weapon{slot_pos = Pos}, next, Shift) ->
    new_weapon_name(Pos + Shift);
new_weapon_name(#weapon{slot_pos = Pos}, prev, Shift) ->
    new_weapon_name(Pos - Shift).

new_weapon_name(Pos) when is_integer(Pos), Pos >= 0, Pos < 10 ->
    genlib_map:get(Pos, ?SLOTS, <<"no weapon">>);
new_weapon_name(_) ->
    throw(?pos_error).

validate_next_client(#{seq := NextSeq}, #{seq := Seq}) ->
    NextSeq = Seq + 1,
    ok.

self_to_bin() ->
    genlib:to_binary(pid_to_list(self())).

send_msg(<<>>, _) ->
    ok;
send_msg(To, Msg) when is_pid(To) ->
    To ! {self(), Msg};
send_msg(To, Msg) when is_binary(To) ->
    send_msg(list_to_pid(genlib:to_list(To)), Msg).

receive_msg(Msg) ->
    receive
        {From, Msg} ->
            {ok, From}
    after 1000 ->
        error(get_msg_timeout)
    end.
