-module(rpc_tests_SUITE).

-include_lib("common_test/include/ct.hrl").

-include("rpc_test_types.hrl").
-include("src/rpc_defs.hrl").

-compile(export_all).

-behaviour(supervisor).
-behaviour(rpc_thrift_handler).
-behaviour(rpc_event_handler).

%% supervisor callbacks
-export([init/1]).

%% rpc_thrift_handler callbacks
-export([handle_function/5]).
-export([handle_error/5]).

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
    name     = Name,
    slot_pos = Pos,
    ammo     = Ammo
}).
-define(weapon(Name, Pos), ?weapon(Name, Pos, undefined)).

-define(WEAPONS, #{
    ?weapon(<<"Impact Hammer">>   , 1),
    ?weapon(<<"Enforcer">>        , 2, 25),
    ?weapon(<<"Bio Rifle">>       , 3, 0),
    ?weapon(<<"Shock Rifle">>     , 4, 0),
    ?weapon(<<"Pulse Gun">>       , 5, 0),
    ?weapon(<<"Ripper">>          , 6, 16),
    ?weapon(<<"Minigun">>         , 7, 0),
    ?weapon(<<"Flak Cannon">>     , 8, 30),
    ?weapon(<<"Rocket Launcher">> , 9, 6),
    ?weapon(<<"Sniper Rifle">>    , 0, 20)
}).

-define(weapon_failure(Reason), #weapon_failure{
    code   = <<"weapon_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(except_weapon_failure(Reason), {exception, ?weapon_failure(Reason)}).

-define(pos_error, {pos_error, "pos out of boundaries"}).

%% Powerup service
-define(powerup(Name, Params),
    Name => #powerup{name = Name, Params}
).

-define(POWERUPS, #{
    ?powerup(<<"Thigh Pads">>       , level = 23),
    ?powerup(<<"Body Armor">>       , level = 82),
    ?powerup(<<"Shield Belt">>      , level = 0),
    ?powerup(<<"AntiGrav Boots">>   , level = 2),
    ?powerup(<<"Damage Amplifier">> , time_left = 0),
    ?powerup(<<"Invisibility">>     , time_left = 0)
}).


-define(SERVER_IP     , {0,0,0,0}).
-define(SERVER_PORT   , 8085).
-define(URL_BASE      , "0.0.0.0:8085").
-define(PATH_WEAPONS  , "/v1/rpc/test/weapons").
-define(PATH_POWERUPS , "/v1/rpc/test/powerups").

%%
%% tests descriptions
%%
all() ->
    [
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
        call_handle_error_fails_test,
        call_oneway_void_test,
        call_async_ok_test,
        span_ids_sequence_test,
        call_two_services_test,
        call_with_client_pool_test,
        multiplexed_transport_test,
        allowed_transport_options_test,
        server_http_request_validation_test
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
    Tc =:= call_safe_server_transport_error_test ;
    Tc =:= call_server_transport_error_test ;
    Tc =:= call_handle_error_fails_test ;
    Tc =:= call_oneway_void_test ;
    Tc =:= multiplexed_transport_test
->
    do_init_per_testcase([powerups], C);
init_per_testcase(Tc, C) when
    Tc =:= call_two_services_test
->
    do_init_per_testcase([weapons, powerups], C);
init_per_testcase(_, C) ->
    do_init_per_testcase([weapons], C).

do_init_per_testcase(Services, C) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    {ok, _}   = start_rpc_server(rpc_ct, Sup, Services),
    [{sup, Sup} | C].

start_rpc_server(Id, Sup, Services) ->
    Server = rpc_server:child_spec(Id, #{
        handlers      => [get_handler(S) || S <- Services],
        event_handler => ?MODULE,
        ip            => ?SERVER_IP,
        port          => ?SERVER_PORT,
        net_opts      => []
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
            demonitor(Ref),
            ok
    after 1000 ->
        demonitor(Ref,[flush]),
        error(exit_timeout)
    end.


%%
%% tests
%%
call_safe_ok_test(_) ->
    Gun =  <<"Enforcer">>,
    gun_test_basic(call_safe, <<"call_safe_ok">>, Gun,
        {ok, genlib_map:get(Gun, ?WEAPONS)}, true).

call_ok_test(_) ->
    Gun = <<"Enforcer">>,
    gun_test_basic(call, <<"call_ok">>, Gun,
        {ok, genlib_map:get(Gun, ?WEAPONS)}, true).

call_safe_handler_throw_test(_) ->
    Gun = <<"Bio Rifle">>,
    gun_test_basic(call_safe, <<"call_safe_handler_throw">>, Gun,
        ?except_weapon_failure("out of ammo"), true).

call_handler_throw_test(_) ->
    Gun = <<"Bio Rifle">>,
    gun_catch_test_basic(<<"call_handler_throw">>, Gun,
        {throw, ?except_weapon_failure("out of ammo")}, true).

call_safe_handler_throw_unexpected_test(_) ->
    Id      = <<"call_safe_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Client  = get_client(Id),
    Expect  = {{error, ?error_transport(server_error)}, Client},
    Expect  = call_safe(Client, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]),
    {ok, _} = receive_msg({Id, Current}).

call_handler_throw_unexpected_test(_) ->
    Id      = <<"call_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Client  = get_client(Id),
    Expect  = {?error_transport(server_error), Client},
    try call(Client, weapons, switch_weapon, [Current, next, 1, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Current}).

call_safe_handler_error_test(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    gun_test_basic(call_safe, <<"call_safe_handler_error">>, Gun,
        {error, ?error_transport(server_error)}, true).

call_handler_error_test(_) ->
    Gun = <<"The Ultimate Super Mega Destroyer">>,
    gun_catch_test_basic(<<"call_handler_error">>, Gun,
        {error, ?error_transport(server_error)}, true).

call_safe_client_transport_error_test(_) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Id = <<"call_safe_client_transport_error">>,
    Client = get_client(Id),
    {{error, ?error_protocol(_), _Stack}, Client} = call_safe(Client,
        weapons, get_weapon, [Gun, self_to_bin()]).

call_client_transport_error_test(_) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Id = <<"call_client_transport_error">>,
    Client = get_client(Id),
    try call(Client, weapons, get_weapon, [Gun, self_to_bin()])
    catch
        error:{?error_protocol(_), Client} -> ok
    end.

call_safe_server_transport_error_test(_) ->
    Id     = <<"call_safe_server_transport_error">>,
    Armor  = <<"Helmet">>,
    Client = get_client(Id),
    Expect = {{error, ?error_transport(server_error)}, Client},
    Expect = call_safe(Client, powerups, get_powerup,
        [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_server_transport_error_test(_) ->
    do_call_server_transport_error(<<"call_server_transport_error">>).

call_handle_error_fails_test(_) ->
    do_call_server_transport_error(<<"call_handle_error_fails">>).

do_call_server_transport_error(Id) ->
    Armor  = <<"Helmet">>,
    Client = get_client(Id),
    Expect = {?error_transport(server_error), Client},
    try call(Client, powerups, get_powerup, [Armor, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Armor}).

call_oneway_void_test(_) ->
    Id      = <<"call_oneway_void_test">>,
    Armor   = <<"Helmet">>,
    Client  = get_client(Id),
    Expect  = {ok, Client},
    Expect  = call(Client, powerups, like_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_async_ok_test(C) ->
    Sup        = proplists:get_value(sup, C),
    Pid        = self(),
    Callback   = fun(Res) -> collect(Res, Pid) end,
    Id1        = <<"call_async_ok1">>,
    Client1    = get_client(Id1),
    {ok, Pid1, Client1} = get_weapon(Client1, Sup, Callback, <<"Impact Hammer">>),
    Id2        = <<"call_async_ok2">>,
    Client2    = get_client(Id2),
    {ok, Pid2, Client2} = get_weapon(Client2, Sup, Callback, <<"Flak Cannon">>),
    {ok, Pid1} = receive_msg({Client1, genlib_map:get(<<"Impact Hammer">>, ?WEAPONS)}),
    {ok, Pid2} = receive_msg({Client2, genlib_map:get(<<"Flak Cannon">>, ?WEAPONS)}).

get_weapon(Client, Sup, Cb, Gun) ->
    call_async(Client, weapons, get_weapon, [Gun, <<>>], Sup, Cb).

collect({{ok, Result}, Client}, Pid) ->
    send_msg(Pid, {Client, Result}).

span_ids_sequence_test(_) ->
    Id      = <<"span_ids_sequence">>,
    Current = genlib_map:get(<<"Enforcer">>, ?WEAPONS),
    Client  = get_client(Id),
    Expect  = {{ok, genlib_map:get(<<"Ripper">>, ?WEAPONS)}, Client},
    Expect  = call(Client, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]).

call_two_services_test(_) ->
    Gun     =  <<"Enforcer">>,
    gun_test_basic(call_safe, <<"two_services1">>, Gun, {ok, genlib_map:get(Gun, ?WEAPONS)}, true),
    Id      = <<"two_services2">>,
    Armor   = <<"Body Armor">>,
    Client  = get_client(Id),
    Expect  = {{ok, genlib_map:get(<<"Body Armor">>, ?POWERUPS)}, Client},
    Expect  = call_safe(Client, powerups, get_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_with_client_pool_test(_) ->
    Pool = guns,
    ok = rpc_thrift_client:start_pool(Pool, 10),
    Id = <<"call_with_client_pool">>,
    Gun =  <<"Enforcer">>,
    Client = get_client(Id),
    {Url, Service} = get_service_endpoint(weapons),
    Expect = {{ok, genlib_map:get(Gun, ?WEAPONS)}, Client},
    Expect = rpc_client:call(
        Client,
        {Service, get_weapon, [Gun, self_to_bin()]},
        #{url => Url, pool => Pool}
    ),
    receive_msg({Id, Gun}),
    ok = rpc_thrift_client:stop_pool(Pool).

multiplexed_transport_test(_) ->
    Id  = <<"multiplexed_transport">>,
    {Client1, {error, ?error_transport(bad_request)}} = thrift_client:call(
        make_thrift_multiplexed_client(Id, "powerups", get_service_endpoint(powerups)),
        get_powerup,
        [<<"Body Armor">>, self_to_bin()]
    ),
    thrift_client:close(Client1).

make_thrift_multiplexed_client(Id, ServiceName, {Url, Service}) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        rpc_thrift_http_transport:new(
            #{
                span_id => Id, trace_id => Id, parent_id => Id
            },
           #{url => Url}, ?MODULE
        ),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Protocol1} = thrift_multiplexed_protocol:new(Protocol, ServiceName),
    {ok, Client} = thrift_client:new(Protocol1, Service),
    Client.

allowed_transport_options_test(_) ->
    Id  = <<"allowed_transport_options">>,
    Gun =  <<"Enforcer">>,
    Args = [Gun, self_to_bin()],
    {Url, Service} = get_service_endpoint(weapons),
    Pool = guns,
    ok = rpc_thrift_client:start_pool(Pool, 1),
    Client = get_client(Id),
    Options = #{url => Url, pool => Pool, ssl_options => [], connect_timeout => 0},
    {{error, ?error_transport(connect_timeout)}, Client} = rpc_client:call_safe(
        Client,
        {Service, get_weapon, Args},
        Options
    ),
    BadOpt = #{custom_option => 'fire!'},
    {{error, {badarg, {unsupported_options, BadOpt}}, _}, Client}  = rpc_client:call_safe(
        Client,
        {Service, get_weapon, Args},
        maps:merge(Options, BadOpt)
    ).

server_http_request_validation_test(_) ->
    Id  = <<"server_http_request_validation">>,
    {Url, _Service} = get_service_endpoint(weapons),
    Headers = [
        {?HEADER_NAME_RPC_ROOT_ID   , genlib:to_binary(Id)},
        {?HEADER_NAME_RPC_ID        , genlib:to_binary(Id)},
        {?HEADER_NAME_RPC_PARENT_ID , genlib:to_binary(<<"undefined">>)},
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT}
    ],

    %% Check missing Id headers, content-type and an empty body on the last step,
    %% as no Accept is allowed
    lists:foreach(fun({C, H}) ->
        {ok, C, _, _} = hackney:request(post, Url, Headers -- [H], <<>>, [{url, Url}])
        end, lists:zip([403,403,403,403,400], Headers)),

    %% Check wrong Accept,
    {ok, 406, _, _} = hackney:request(post, Url,
        lists:keyreplace(<<"accept">>, 1, Headers, {<<"accept">>, <<"application/text">>}),
        <<>>, [{url, Url}]),
    %% Check wrong methods
    lists:foreach(fun(M) ->
        {ok, 405, _, _} = hackney:request(M, Url, Headers, <<>>, [{url, Url}]) end,
        [get, put, delete, trace, options, patch]), %% head, options, connect
    {ok, 400, _, _} = hackney:request(connect, Url, Headers, <<>>, [{url, Url}]),
    {ok, 405, _} = hackney:request(head, Url, Headers, <<>>, [{url, Url}]).


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
handle_function(switch_weapon, {CurrentWeapon, Direction, Shift, To},
    _RpcId    = #{span_id   := SpanId, trace_id := TraceId},
    RpcClient = #{parent_id := SpanId, trace_id := TraceId}, _Opts)
->
    send_msg(To, {SpanId, CurrentWeapon}),
    switch_weapon(CurrentWeapon, Direction, Shift, RpcClient);

handle_function(get_weapon, {Name, To},
    #{span_id   := SpanId, trace_id := TraceId},
    #{parent_id := SpanId, trace_id := TraceId}, _Opts)
->
    send_msg(To,{SpanId, Name}),
    Res = case genlib_map:get(Name, ?WEAPONS) of
        #weapon{ammo = 0}  ->
            throw(?weapon_failure("out of ammo"));
        Weapon = #weapon{} ->
            Weapon
    end,
    {ok, Res};

%% Powerups
handle_function(get_powerup, {Name, To},
    #{span_id   := SpanId, trace_id := TraceId},
    #{parent_id := SpanId, trace_id := TraceId}, _Opts)
->
    send_msg(To, {SpanId, Name}),
    {ok, genlib_map:get(Name, ?POWERUPS, powerup_unknown)};
handle_function(like_powerup, {Name, To},
    #{span_id   := SpanId, trace_id := TraceId},
    #{parent_id := SpanId, trace_id := TraceId}, _Opts)
->
    send_msg(To, {SpanId, Name}),
    ok.

handle_error(get_powerup, _,
    #{trace_id := TraceId, span_id   := SpanId = <<"call_handle_error_fails">>},
    #{trace_id := TraceId, parent_id := SpanId}, _Opts)
->
    error(no_more_powerups);
handle_error(_Function, _Reason,
    _RpcId     = #{span_id   := SpanId, trace_id := TraceId},
    _RpcClient = #{parent_id := SpanId, trace_id := TraceId}, _Opts)
->
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

gun_test_basic(CallFun, Id, Gun, {ExpectStatus, ExpectRes}, WithMsg) ->
    Client = get_client(Id),
    Expect = {{ExpectStatus, ExpectRes}, Client},
    Expect = ?MODULE:CallFun(Client, weapons, get_weapon, [Gun, self_to_bin()]),
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _    -> ok
    end.

gun_catch_test_basic(Id, Gun, {Class, Exception}, WithMsg) ->
    Client = get_client(Id),
    Expect = {Exception, Client},
    try call(Client, weapons, get_weapon, [Gun, self_to_bin()])
    catch
        Class:Expect -> ok
    end,
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _    -> ok
    end.

switch_weapon(CurrentWeapon, Direction, Shift, RpcClient) ->
    case call_safe(RpcClient, weapons, get_weapon,
             [new_weapon_name(CurrentWeapon, Direction, Shift), self_to_bin()])
    of
        {{ok, Weapon}, _} ->
            {ok, Weapon};
        {{exception, #weapon_failure{
            code   = <<"weapon_error">>,
            reason = <<"out of ammo">>
        }}, NextClient} ->
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
