-module(woody_client_thrift).

-behaviour(woody_client_behaviour).

-include_lib("thrift/include/thrift_constants.hrl").
-include("woody_defs.hrl").

%% woody_client_behaviour callback
-export([call      /3]).
-export([child_spec/1]).

-export([get_rpc_type/2]).

%% Types
-type thrift_client() :: term().

-define(WOODY_OPTS, [protocol, transport, event_handler]).

%%
%% API
%%
-spec child_spec(woody_client:options()) ->
    supervisor:child_spec().
child_spec(Options) ->
    woody_client_thrift_http_transport:child_spec(get_transport_opts(Options)).

-spec call(woody:request(), woody_client:options(), woody_state:st()) ->
    woody_client:result().
call({Service = {_, ServiceName}, Function, Args}, Opts, WoodyState) ->
    WoodyContext = woody_state:get_context(WoodyState),
    WoodyState1 = woody_state:add_ev_meta(
        #{
            service        => ServiceName,
            service_schema => Service,
            function       => Function,
            type           => get_rpc_type(Service, Function),
            args           => Args,
            deadline       => woody_context:get_deadline(WoodyContext),
            metadata       => woody_context:get_meta(WoodyContext)
        },
        WoodyState
    ),
    _ = log_event(?EV_CALL_SERVICE, WoodyState1, #{}),
    do_call(make_thrift_client(Service, Opts, WoodyState1), Function, Args, WoodyState1).

-spec get_rpc_type(woody:service(), woody:func()) ->
    woody:rpc_type().
get_rpc_type(ThriftService = {Module, Service}, Function) ->
    try woody_util:get_rpc_reply_type(Module:function_info(Service, Function, reply_type))
    catch
        error:Reason when Reason =:= undef orelse Reason =:= badarg ->
            error(badarg, [ThriftService, Function])
    end.

%%
%% Internal functions
%%
-spec make_thrift_client(woody:service(), woody_client:options(), woody_state:st()) ->
    thrift_client().
make_thrift_client(Service, Opts = #{url := Url}, WoodyState) ->
    {ok, Protocol} = thrift_binary_protocol:new(
        woody_client_thrift_http_transport:new(
            Url,
            get_transport_opts(Opts),
            get_resolver_opts(Opts),
            WoodyState
        ),
        [{strict_read, true}, {strict_write, true}]
    ),
    {ok, Client} = thrift_client:new(Protocol, Service),
    Client.

-spec get_transport_opts(woody_client:options()) ->
    woody_client_thrift_http_transport:options().
get_transport_opts(Opts) ->
    maps:get(transport_opts, Opts, []).

-spec get_resolver_opts(woody_client:options()) ->
    woody_resolver:options().
get_resolver_opts(Opts) ->
    maps:get(resolver_opts, Opts, #{}).

-spec do_call(thrift_client(), woody:func(), woody:args(), woody_state:st()) ->
    woody_client:result().
do_call(Client, Function, Args, WoodyState) ->
    {ClientNext, Result} = try thrift_client:call(Client, Function, Args)
        catch
            throw:{Client1, {exception, #'TApplicationException'{}}} ->
                {Client1, {error, {system, get_server_violation_error()}}};
            throw:{Client1, {exception, ThriftExcept}} ->
                {Client1, {error, {business, ThriftExcept}}}
        end,
    _ = thrift_client:close(ClientNext),
    log_result(Result, WoodyState),
    map_result(Result).

get_server_violation_error() ->
    {external, result_unexpected, <<
        "server violated thrift protocol: "
        "sent TApplicationException (unknown exception) with http code 200"
    >>}.

log_result({error, {business, ThriftExcept}}, WoodyState) ->
    log_event(?EV_SERVICE_RESULT, WoodyState, #{status => ok, result => ThriftExcept});
log_result({Status, Result}, WoodyState) ->
    log_event(?EV_SERVICE_RESULT, WoodyState, #{status => Status, result => Result}).

-spec map_result(woody_client:result() | {error, _ThriftError}) ->
    woody_client:result().
map_result(Res = {ok, _}) ->
    Res;
map_result(Res = {error, {Type, _}}) when Type =:= business orelse Type =:= system ->
    Res;
map_result({error, ThriftError}) ->
    BinError = woody_error:format_details(ThriftError),
    {error, {system, {internal, result_unexpected, <<"client thrift error: ", BinError/binary>>}}}.

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
