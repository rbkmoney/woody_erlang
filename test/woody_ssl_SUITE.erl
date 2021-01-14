-module(woody_ssl_SUITE).

-include_lib("public_key/include/public_key.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-include("woody_test_thrift.hrl").

-behaviour(supervisor).
-behaviour(woody_server_thrift_handler).
-behaviour(woody_event_handler).

%% common test callbacks
-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1,
    init_per_group/2,
    end_per_group/2
]).

%% tests
-export([
    client_wo_cert_test/1,
    valid_client_cert_test/1,
    invalid_client_cert_test/1
]).

%% woody_event_handler callback
-export([handle_event/4]).

%% woody_server_thrift_handler callback
-export([handle_function/4]).

%% supervisor callback
-export([init/1]).

-type config() :: [{atom(), any()}].
-type group_name() :: atom().
-type case_name() :: atom().

-define(PATH, "/v1/test/weapons").
-define(THRIFT_DEFS, woody_test_thrift).

-define(data_dir(C), ?config(data_dir, C)).
-define(valid_subdir(C), filename:join(?data_dir(C), "valid")).
-define(invalid_subdir(C), filename:join(?data_dir(C), "invalid")).

-define(ca_cert(C), filename:join(?valid_subdir(C), "ca.crt")).
-define(server_cert(C), filename:join(?valid_subdir(C), "server.pem")).
-define(client_cert(C), filename:join(?valid_subdir(C), "client.pem")).

-define(invalid_client_cert(C), filename:join(?invalid_subdir(C), "client.pem")).

%%%
%%% CT callbacks
%%%

-spec all() -> [{group, group_name()}].
all() ->
    [
        {group, 'tlsv1.3'},
        {group, 'tlsv1.2'},
        {group, 'tlsv1.1'}
    ].

-spec groups() -> [{group_name(), list(), [case_name()]}].
groups() ->
    TestGroup = [
        client_wo_cert_test,
        invalid_client_cert_test,
        valid_client_cert_test
    ],
    [
        {'tlsv1.1', [parallel], TestGroup},
        {'tlsv1.2', [parallel], TestGroup},
        {'tlsv1.3', [parallel], TestGroup}
    ].

-spec init_per_suite(config()) -> config().
init_per_suite(C) ->
    {ok, Sup} = supervisor:start_link({local, ?MODULE}, ?MODULE, []),
    true = erlang:unlink(Sup),
    {ok, Apps} = application:ensure_all_started(woody),
    [{sup, Sup}, {apps, Apps} | C].

-spec end_per_suite(config()) -> ok.
end_per_suite(C) ->
    Sup = ?config(sup, C),
    ok = proc_lib:stop(Sup),
    _ = [application:stop(App) || App <- proplists:get_value(apps, C)],
    ok.

-spec init_per_group(group_name(), config()) -> config().
init_per_group(Name, C) ->
    {ok, WoodyServer} = start_woody_server(Name, C),
    [{woody_server, WoodyServer}, {group_name, Name} | C].

-spec end_per_group(group_name(), config()) -> any().
end_per_group(_Name, C) ->
    stop_woody_server(C).

%%%
%%% Tests
%%%

-spec client_wo_cert_test(config()) -> _.
client_wo_cert_test(C) ->
    Vsn = ?config(group_name, C),
    SSLOptions = [{cacertfile, ?ca_cert(C)} | client_ssl_opts(Vsn)],
    try
        _ = get_weapon(?FUNCTION_NAME, <<"BFG">>, SSLOptions),
        error(unreachable)
    catch
        % NOTE
        % Seems that TLSv1.3 connection setup kinda racy.
        error:{woody_error, {internal, result_unexpected, Reason}} when Vsn =:= 'tlsv1.3' ->
            ?assertMatch(<<"{tls_alert,{certificate_required", _/binary>>, Reason);
        error:{woody_error, {external, result_unknown, <<"closed">>}} when Vsn =:= 'tlsv1.3' ->
            ok;
        error:{woody_error, {internal, result_unexpected, Reason}} ->
            {match, _} = re:run(Reason, <<"^{tls_alert,[\"\{]handshake[ _]failure.*$">>, [])
    end.

-spec valid_client_cert_test(config()) -> _.
valid_client_cert_test(C) ->
    Vsn = ?config(group_name, C),
    SSLOptions = [{cacertfile, ?ca_cert(C)}, {certfile, ?client_cert(C)} | client_ssl_opts(Vsn)],
    {ok, #'Weapon'{}} = get_weapon(?FUNCTION_NAME, <<"BFG">>, SSLOptions).

-spec invalid_client_cert_test(config()) -> _.
invalid_client_cert_test(C) ->
    Vsn = ?config(group_name, C),
    SSLOptions = [{cacertfile, ?ca_cert(C)}, {certfile, ?invalid_client_cert(C)} | client_ssl_opts(Vsn)],
    try
        _ = get_weapon(?FUNCTION_NAME, <<"BFG">>, SSLOptions),
        error(unreachable)
    catch
        % NOTE
        % Seems that TLSv1.3 connection setup kinda racy.
        error:{woody_error, {external, result_unknown, <<"closed">>}} when Vsn =:= 'tlsv1.3' ->
            ok;
        error:{woody_error, {internal, result_unexpected, Reason}} ->
            {match, _} = re:run(Reason, <<"^{tls_alert,[\"\{]unknown[ _]ca.*$">>, [])
    end.

-spec client_ssl_opts(atom()) -> [ssl:tls_client_option()].
client_ssl_opts('tlsv1.3') ->
    % NOTE
    % We need at least an extra TLSv1.2 here and default OTP cipher suites,
    % otherwise hackney messes up client options.
    [
        {versions, ['tlsv1.3', 'tlsv1.2']},
        {ciphers, ssl:cipher_suites(default, 'tlsv1.3')}
    ];
client_ssl_opts(Vsn) ->
    [{versions, [Vsn]}].

%%%
%%% woody_event_handler callback
%%%

-spec handle_event(
    woody_event_handler:event(),
    woody:rpc_id(),
    woody_event_handler:event_meta(),
    woody:options()
) -> _.
handle_event(Event, RpcId, Meta, _) ->
    {_Severity, {Format, Msg}, EvMeta} = woody_event_handler:format_event_and_meta(
        Event,
        Meta,
        RpcId,
        [
            event,
            role,
            service,
            service_schema,
            function,
            type,
            args,
            metadata,
            deadline,
            status,
            url,
            code,
            result,
            execution_time
        ]
    ),
    ct:pal(Format ++ "~nmeta: ~p", Msg ++ [EvMeta]).

%%%
%%% woody_server_thrift_handler callback
%%%

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) -> {ok, woody:result()}.
handle_function(get_weapon, {Name, _Data}, Context, _Opts) ->
    _ = assert_common_name([<<"Valid Test Client">>], Context),
    {ok, #'Weapon'{name = Name, slot_pos = 0}}.

%%%
%%% Supervisor callback
%%%

-spec init(_) -> genlib_gen:supervisor_ret().
init(_) ->
    {ok,
        {
            {one_for_one, 1, 1},
            []
        }}.

%%%
%%% Internal functions
%%%

start_woody_server(Vsn, C) ->
    Sup = ?config(sup, C),
    Server = woody_server:child_spec(?MODULE, #{
        handlers => [{?PATH, {{?THRIFT_DEFS, 'Weapons'}, ?MODULE}}],
        event_handler => ?MODULE,
        ip => {0, 0, 0, 0},
        port => 8043,
        transport_opts => #{
            transport => ranch_ssl,
            socket_opts => [
                {cacertfile, ?ca_cert(C)},
                {certfile, ?server_cert(C)},
                {verify, verify_peer},
                {fail_if_no_peer_cert, true},
                {versions, [Vsn]}
            ]
        }
    }),
    supervisor:start_child(Sup, Server).

-spec stop_woody_server(config()) -> ok.
stop_woody_server(C) ->
    ok = supervisor:terminate_child(?config(sup, C), ?MODULE),
    ok = supervisor:delete_child(?config(sup, C), ?MODULE).

get_weapon(Id, Gun, SSLOptions) ->
    Context = woody_context:new(to_binary(Id)),
    {Url, Service} = get_service_endpoint('Weapons'),
    Options = #{
        url => Url,
        event_handler => ?MODULE,
        transport_opts => #{
            ssl_options => [
                {server_name_indication, "Test Server"},
                {verify, verify_peer}
                | SSLOptions
            ]
        }
    },
    woody_client:call({Service, get_weapon, {Gun, <<>>}}, Options, Context).

get_service_endpoint('Weapons') ->
    {
        "https://localhost:8043" ?PATH,
        {?THRIFT_DEFS, 'Weapons'}
    }.

to_binary(Atom) when is_atom(Atom) ->
    erlang:atom_to_binary(Atom, utf8).

assert_common_name(CNs, Context) ->
    CN = woody_context:get_common_name(Context),
    true = lists:member(CN, CNs).
