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
    call_with_client_pool_test/1,
    multiplexed_transport_test/1,
    allowed_transport_options_test/1,
    server_http_request_validation_test/1
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

-define(powerup_failure(Reason), #powerup_failure{
    code   = <<"powerup_error">>,
    reason = genlib:to_binary(Reason)
}).

-define(except_weapon_failure (Reason), {exception, ?weapon_failure (Reason)}).
-define(except_powerup_failure(Reason), {exception, ?powerup_failure(Reason)}).

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
-define(PATH_WEAPONS  , "/v1/woody/test/weapons").
-define(PATH_POWERUPS , "/v1/woody/test/powerups").

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
        call_oneway_void_test,
        call_async_ok_test,
        call_pass_through_ok_test,
        call_pass_through_except_test,
        call_no_pass_through_bad_ok_test,
        call_no_pass_through_bad_except_test,
        span_ids_sequence_test,
        call_with_client_pool_test,
        multiplexed_transport_test,
        allowed_transport_options_test,
        server_http_request_validation_test
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

init_per_testcase(_, C) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    {ok, _}   = start_woody_server(woody_ct, Sup, [weapons, powerups]),
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

get_handler(powerups) ->
    {
        ?PATH_POWERUPS,
        {{?THRIFT_DEFS, powerups}, ?MODULE, []}
    };
get_handler(weapons) ->
    {
        ?PATH_WEAPONS,
        {{?THRIFT_DEFS, weapons}, ?MODULE, []}
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
    Context = make_context(Id),
    Expect  = {{error, ?error_transport(server_error)}, Context},
    Expect  = call_safe(Context, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]),
    {ok, _} = receive_msg({Id, Current}).

call_handler_throw_unexpected_test(_) ->
    Id      = <<"call_handler_throw_unexpected">>,
    Current = genlib_map:get(<<"Rocket Launcher">>, ?WEAPONS),
    Context = make_context(Id),
    Expect  = {?error_transport(server_error), Context},
    try call(Context, weapons, switch_weapon, [Current, next, 1, self_to_bin()])
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
    Id  = <<"call_safe_client_transport_error">>,
    Context = make_context(Id),
    {{error, ?error_protocol(_)}, Context} = call_safe(Context,
        weapons, get_weapon, [Gun, self_to_bin()]).

call_client_transport_error_test(_) ->
    Gun = 'Wrong Type of Mega Destroyer',
    Id  = <<"call_client_transport_error">>,
    Context = make_context(Id),
    try call(Context, weapons, get_weapon, [Gun, self_to_bin()])
    catch
        error:{?error_protocol(_), Context} -> ok
    end.

call_safe_server_transport_error_test(_) ->
    Id      = <<"call_safe_server_transport_error">>,
    Armor   = <<"Helmet">>,
    Context = make_context(Id),
    Expect  = {{error, ?error_transport(server_error)}, Context},
    Expect  = call_safe(Context, powerups, get_powerup,
        [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_server_transport_error_test(_) ->
    do_call_server_transport_error(<<"call_server_transport_error">>).

do_call_server_transport_error(Id) ->
    Armor   = <<"Helmet">>,
    Context = make_context(Id),
    Expect  = {?error_transport(server_error), Context},
    try call(Context, powerups, get_powerup, [Armor, self_to_bin()])
    catch
        error:Expect -> ok
    end,
    {ok, _} = receive_msg({Id, Armor}).

call_oneway_void_test(_) ->
    Id      = <<"call_oneway_void_test">>,
    Armor   = <<"Helmet">>,
    Context = make_context(Id),
    Expect  = {ok, Context},
    Expect  = call(Context, powerups, like_powerup, [Armor, self_to_bin()]),
    {ok, _} = receive_msg({Id, Armor}).

call_async_ok_test(C) ->
    Sup        = proplists:get_value(sup, C),
    Pid        = self(),
    Callback   = fun(Res) -> collect(Res, Pid) end,
    Id1        = <<"call_async_ok1">>,
    Context1   = make_context(Id1),
    {ok, Pid1, Context1} = get_weapon(Context1, Sup, Callback, <<"Impact Hammer">>),
    Id2        = <<"call_async_ok2">>,
    Context2   = make_context(Id2),
    {ok, Pid2, Context2} = get_weapon(Context2, Sup, Callback, <<"Flak Cannon">>),
    {ok, Pid1} = receive_msg({Context1,
        genlib_map:get(<<"Impact Hammer">>, ?WEAPONS)}),
    {ok, Pid2} = receive_msg({Context2,
        genlib_map:get(<<"Flak Cannon">>, ?WEAPONS)}).

get_weapon(Context, Sup, Cb, Gun) ->
    call_async(Context, weapons, get_weapon, [Gun, <<>>], Sup, Cb).

collect({{ok, Result}, Context}, Pid) ->
    send_msg(Pid, {Context, Result}).

span_ids_sequence_test(_) ->
    Id      = <<"span_ids_sequence">>,
    Current = genlib_map:get(<<"Enforcer">>, ?WEAPONS),
    Context = make_context(Id),
    Expect  = {{ok, genlib_map:get(<<"Ripper">>, ?WEAPONS)}, Context},
    Expect  = call(Context, weapons, switch_weapon,
        [Current, next, 1, self_to_bin()]).

call_with_client_pool_test(_) ->
    Pool = guns,
    ok   = woody_client_thrift:start_pool(Pool, 10),
    Id   = <<"call_with_client_pool">>,
    Gun  =  <<"Enforcer">>,
    Context = make_context(Id),
    {Url, Service} = get_service_endpoint(weapons),
    Expect = {{ok, genlib_map:get(Gun, ?WEAPONS)}, Context},
    Expect = woody_client:call(
        Context,
        {Service, get_weapon, [Gun, self_to_bin()]},
        #{url => Url, pool => Pool}
    ),
    {ok, _} = receive_msg({Id, Gun}),
    ok = woody_client_thrift:stop_pool(Pool).

multiplexed_transport_test(_) ->
    Id  = <<"multiplexed_transport">>,
    {Client1, {error, ?error_transport(bad_request)}} = thrift_client:call(
        make_thrift_multiplexed_client(Id, "powerups",
            get_service_endpoint(powerups)),
        get_powerup,
        [<<"Body Armor">>, self_to_bin()]
    ),
    thrift_client:close(Client1).

make_thrift_multiplexed_client(Id, ServiceName, {Url, Service}) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(
            #{
                span_id => Id, trace_id => Id, parent_id => Id
            },
           #{url => Url}, ?MODULE
        ),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Protocol1} = thrift_multiplexed_protocol:new(Protocol, ServiceName),
    {ok, Context} = thrift_client:new(Protocol1, Service),
    Context.

allowed_transport_options_test(_) ->
    Id   = <<"allowed_transport_options">>,
    Gun  =  <<"Enforcer">>,
    Args = [Gun, self_to_bin()],
    {Url, Service} = get_service_endpoint(weapons),
    Pool = guns,
    ok = woody_client_thrift:start_pool(Pool, 1),
    Context = make_context(Id),
    Options = #{url => Url, pool => Pool, ssl_options => [], connect_timeout => 0},
    {{error, ?error_transport(connect_timeout)}, Context} = woody_client:call_safe(
        Context,
        {Service, get_weapon, Args},
        Options
    ),
    BadOpt = #{custom_option => 'fire!'},
    ErrorBadOpt = {badarg, {unsupported_options, BadOpt}},
    {{error, {error, ErrorBadOpt, _}}, Context} = woody_client:call_safe(
        Context,
        {Service, get_weapon, Args},
        maps:merge(Options, BadOpt)
    ),
    ok = woody_client_thrift:stop_pool(Pool).

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
    %% as missing Accept is allowed
    lists:foreach(fun({C, H}) ->
        {ok, C, _, _} = hackney:request(post, Url, Headers -- [H], <<>>, [{url, Url}])
        end, lists:zip([400,400,400,415,400], Headers)),

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
    Context = make_context(Id),
    Expect  = {{ok, genlib_map:get(Armor, ?POWERUPS)}, Context},
    Expect  = call(Context, powerups, proxy_get_powerup, [Armor, self_to_bin()]).

call_pass_through_except_test(_) ->
    Id      = <<"call_pass_through_except">>,
    Armor   = <<"Shield Belt">>,
    Context = make_context(Id),
    Expect = {?except_powerup_failure("run out"), Context},
    try call(Context, powerups, proxy_get_powerup, [Armor, self_to_bin()])
    catch
        throw:Expect -> ok
    end.

call_no_pass_through_bad_ok_test(_) ->
    Id      = <<"call_no_pass_through_bad_ok">>,
    Armor   = <<"AntiGrav Boots">>,
    Context = make_context(Id),
    try call(Context, powerups, bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{?error_transport(server_error), Context} ->
            ok
    end.

call_no_pass_through_bad_except_test(_) ->
    Id      = <<"call_no_pass_through_bad_except">>,
    Armor   = <<"Shield Belt">>,
    Context = make_context(Id),
    try call(Context, powerups, bad_proxy_get_powerup, [Armor, self_to_bin()])
    catch
        error:{?error_transport(server_error), Context} ->
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
handle_function(switch_weapon, {CurrentWeapon, Direction, Shift, To},
    Context = #{  parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    send_msg(To, {SpanId, CurrentWeapon}),
    {switch_weapon(CurrentWeapon, Direction, Shift, Context), Context};

handle_function(get_weapon, {Name, To},
    Context  = #{ parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    send_msg(To,{SpanId, Name}),
    Res = case genlib_map:get(Name, ?WEAPONS) of
        #weapon{ammo = 0}  ->
            throw({?weapon_failure("out of ammo"), Context});
        Weapon = #weapon{} ->
            Weapon
    end,
    {{ok, Res}, Context};

%% Powerups
handle_function(get_powerup, {Name, To},
    Context  = #{ parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    send_msg(To, {SpanId, Name}),
    {{ok, return_powerup(Name, Context)}, Context};

handle_function(proxy_get_powerup, {Name, To},
    Context  = #{ parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    call(Context, powerups, get_powerup, [Name, To]);

handle_function(bad_proxy_get_powerup, {Name, To},
    Context  = #{ parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    call(Context, powerups, get_powerup, [Name, To]);

handle_function(like_powerup, {Name, To},
    Context  = #{ parent_id := SpanId, trace_id := TraceId,
        rpc_id := #{span_id := SpanId, trace_id := TraceId}}, _Opts)
->
    send_msg(To, {SpanId, Name}),
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
    woody_client:new_context(ReqId, ?MODULE).

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

get_service_endpoint(weapons) ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_WEAPONS),
        {?THRIFT_DEFS, weapons}
    };
get_service_endpoint(powerups) ->
    {
        genlib:to_binary(?URL_BASE ++ ?PATH_POWERUPS),
        {?THRIFT_DEFS, powerups}
    }.

gun_test_basic(CallFun, Id, Gun, {ExpectStatus, ExpectRes}, WithMsg) ->
    Context = make_context(Id),
    Expect  = {{ExpectStatus, ExpectRes}, Context},
    Expect  = ?MODULE:CallFun(Context, weapons, get_weapon, [Gun, self_to_bin()]),
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _    -> ok
    end.

gun_catch_test_basic(Id, Gun, {Class, Exception}, WithMsg) ->
    Context = make_context(Id),
    Expect  = {Exception, Context},
    try call(Context, weapons, get_weapon, [Gun, self_to_bin()])
    catch
        Class:Expect -> ok
    end,
    case WithMsg of
        true -> {ok, _} = receive_msg({Id, Gun});
        _    -> ok
    end.

switch_weapon(CurrentWeapon, Direction, Shift, Context) ->
    case call_safe(Context, weapons, get_weapon,
             [new_weapon_name(CurrentWeapon, Direction, Shift, Context), self_to_bin()])
    of
        {{ok, Weapon}, _} ->
            {ok, Weapon};
        {{exception, #weapon_failure{
            code   = <<"weapon_error">>,
            reason = <<"out of ammo">>
        }}, NextContex} ->
            ok = validate_next_context(NextContex, Context),
            switch_weapon(CurrentWeapon, Direction, Shift + 1, NextContex)
    end.

new_weapon_name(#weapon{slot_pos = Pos}, next, Shift, Ctx) ->
    new_weapon_name(Pos + Shift, Ctx);
new_weapon_name(#weapon{slot_pos = Pos}, prev, Shift, Ctx) ->
    new_weapon_name(Pos - Shift, Ctx).

new_weapon_name(Pos, _) when is_integer(Pos), Pos >= 0, Pos < 10 ->
    genlib_map:get(Pos, ?SLOTS, <<"no weapon">>);
new_weapon_name(_, Context) ->
    throw({?pos_error, Context}).

validate_next_context(#{seq := NextSeq}, #{seq := Seq}) ->
    NextSeq = Seq + 1,
    ok.

-define(BAD_POWERUP_REPLY, powerup_unknown).

return_powerup(Name, Context) when is_binary(Name) ->
    return_powerup(genlib_map:get(Name, ?POWERUPS, ?BAD_POWERUP_REPLY), Context);
return_powerup(#powerup{level = Level}, Context) when Level == 0 ->
    throw({?powerup_failure("run out"), Context});
return_powerup(#powerup{time_left = Time}, Context) when Time == 0 ->
    throw({?powerup_failure("expired"), Context});
return_powerup(P = #powerup{}, _) ->
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

