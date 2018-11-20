-module(woody_transport_opts_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("woody_test_thrift.hrl").

%% woody_server_thrift_handler callbacks
-behaviour(woody_server_thrift_handler).
-export([handle_function/4]).

%% woody_event_handler callbacks
-behaviour(woody_event_handler).
-export([handle_event/4]).

-export([all/0]).
-export([init_per_suite/1]).
-export([end_per_suite/1]).
-export([init_per_testcase/2]).

-export([respects_max_connections/1]).

%%

all() ->
    [
        respects_max_connections
    ].

init_per_suite(C) ->
    % dbg:tracer(), dbg:p(all, c),
    % dbg:tpl({ranch_server, '_', '_'}, x),
    Apps = genlib_app:start_application_with(woody, [{acceptors_pool_size, 1}]),
    [{suite_apps, Apps} | C].

end_per_suite(C) ->
    [application:stop(App) || App <- ?config(suite_apps, C)].

%%

init_per_testcase(Name, C) ->
    Port = get_random_port(),
    [
        {client , #{
            url           => iolist_to_binary(["http://localhost:", integer_to_list(Port), "/"]),
            event_handler => {?MODULE, {client, Name}}
        }},
        {server , #{
            ip            => {127, 0, 0, 1},
            port          => Port,
            event_handler => {?MODULE, {server, Name}}
        }},
        {testcase, Name} | C
    ].

%%

respects_max_connections(C) ->
    %MaxConns = 10 + rand:uniform(10), % (10; 20]
    MaxConns = 10,
    Table = ets:new(?MODULE, [public, {read_concurrency, true}, {write_concurrency, true}]),
    true = ets:insert_new(Table, [{slot, 0}]),
    Service = {woody_test_thrift, 'Weapons'},
    Client = ?config(client, C),
    Handler = {"/", {Service, {?MODULE, {?config(testcase, C), Table}}}},
    % NOTE
    % > https://github.com/ninenines/ranch/blob/1.3.2/src/ranch_conns_sup.erl#L184
    % If we do not set `max_keepalive = 1` here then any request received by the server
    % except for `MaxConns` first will wait in queue until the keepalive times out in one of these
    % `MaxConns` connections, which results in that it exits cleanly. Unfortunately, the default keepalive
    % timeout is 5000 ms which is the same as the default woody request timeout.
    % I wonder how this behavior affects production traffic as most of woody servers there configured with
    % keepalive timeout of 60 s.
    TransportOpts = #{max_connections => MaxConns},
    ProtocolOpts = #{max_keepalive => 1},
    {ok, ServerPid} = start_woody_server(Handler, TransportOpts, ProtocolOpts, C),
    Results = genlib_pmap:map(
        fun (_) ->
            woody_client:call({Service, 'get_weapon', [<<"BFG">>, <<>>]}, Client)
        end,
        lists:seq(1, MaxConns * 10)
    ),
    Slots = lists:map(
        fun ({ok, #'Weapon'{slot_pos = Slot}}) -> Slot end,
        Results
    ),
    ?assert(lists:max(Slots) =< MaxConns),
    ok = stop_woody_server(ServerPid).

%%

start_woody_server(Handler, TransportOpts, ProtocolOpts, C) ->
    ServerOpts0 = ?config(server, C),
    SupervisorOpts = woody_server:child_spec(
            {?MODULE, ?config(testcase, C)},
            ServerOpts0#{
                handlers       => [Handler],
                transport_opts => TransportOpts,
                protocol_opts  => ProtocolOpts
            }
    ),
    woody_gen_supervisor:start_link([SupervisorOpts]).

stop_woody_server(Pid) ->
    true = unlink(Pid),
    true = exit(Pid, shutdown),
    ok.

handle_function(get_weapon, [Name, _], _Context, {respects_max_connections, Table}) ->
    Slot = ets:update_counter(Table, slot, 1),
    ok = timer:sleep(rand:uniform(10)),
    ets:update_counter(Table, slot, -1),
    {ok, #'Weapon'{name = Name, slot_pos = Slot}}.

handle_event(Event, RpcId, Meta, Opts) ->
    {_Severity, {Format, Msg}, _} = woody_event_handler:format_event_and_meta(Event, Meta, RpcId),
    ct:pal("~p ~p " ++ Format, [self(), Opts] ++ Msg).

%%

get_random_port() ->
    32767 + rand:uniform(32000).