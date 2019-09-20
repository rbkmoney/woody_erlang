-module(woody_event_handler).

%% API
-export([handle_event/3, handle_event/4]).
-export([format_event/2, format_event/3]).
-export([format_event_and_meta/3, format_event_and_meta/4]).
-export([format_rpc_id/1]).

-include("woody_defs.hrl").

%%
%% behaviour definition
%%

-type event_client() ::
    ?EV_CLIENT_BEGIN   |
    ?EV_CALL_SERVICE   |
    ?EV_SERVICE_RESULT |
    ?EV_CLIENT_SEND    |
    ?EV_CLIENT_RESOLVE_BEGIN |
    ?EV_CLIENT_RESOLVE_RESULT |
    ?EV_CLIENT_RECEIVE |
    ?EV_CLIENT_END.

-type event_server() ::
    ?EV_INVOKE_SERVICE_HANDLER |
    ?EV_SERVICE_HANDLER_RESULT |
    ?EV_SERVER_RECEIVE         |
    ?EV_SERVER_SEND.

-type event_cache() ::
    ?EV_CLIENT_CACHE_BEGIN  |
    ?EV_CLIENT_CACHE_HIT    |
    ?EV_CLIENT_CACHE_MISS   |
    ?EV_CLIENT_CACHE_UPDATE |
    ?EV_CLIENT_CACHE_RESULT |
    ?EV_CLIENT_CACHE_END.

%% Layer             Client               Server
%% App invocation    EV_CALL_SERVICE      EV_INVOKE_SERVICE_HANDLER
%% App result        EV_SERVICE_RESULT    EV_SERVICE_HANDLER_RESULT
%% Transport req     EV_CLIENT_SEND       EV_SERVER_RECEIVE
%% Transport resp    EV_CLIENT_RECEIVE    EV_SERVER_SEND

-type event() :: event_client() | event_server() | event_cache() | ?EV_INTERNAL_ERROR | ?EV_TRACE.
-export_type([event/0]).

-type meta_client() :: #{
    role           := client,
    service        := woody:service_name(),
    service_schema := woody:service(),
    function       := woody:func(),
    type           := woody:rpc_type(),
    args           := woody:args(),
    metadata       := woody_context:meta(),
    deadline       := woody:deadline(),

    execution_start_time  := integer(),
    execution_duration_ms => integer(),              %% EV_CLIENT_RECEIVE
    execution_end_time    => integer(),              %% EV_CLIENT_RECEIVE

    url      => woody:url(),                        %% EV_CLIENT_SEND
    code     => woody:http_code(),                  %% EV_CLIENT_RECEIVE
    reason   => woody_error:details(),              %% EV_CLIENT_RECEIVE | EV_CLIENT_RESOLVE_RESULT
    status   => status(),                           %% EV_CLIENT_RECEIVE | EV_SERVICE_RESULT | EV_CLIENT_RESOLVE_RESULT
    address  => string(),                           %% EV_CLIENT_RESOLVE_RESULT
    host     => string(),                           %% EV_CLIENT_RESOLVE_RESULT | EV_CLIENT_RESOLVE_BEGIN
    result   => woody:result() | woody_error:error()  %% EV_SERVICE_RESULT
}.
-export_type([meta_client/0]).

-type meta_server() :: #{
    role     := server,
    url      => woody:url(),           %% EV_SERVER_RECEIVE
    status   => status(),              %% EV_SERVER_RECEIVE | EV_SERVER_SEND | EV_SERVICE_HANDLER_RESULT
    reason   => woody_error:details(), %% EV_SERVER_RECEIVE
    code     => woody:http_code(),     %% EV_SERVER_SEND

    execution_start_time  := integer(),
    execution_duration_ms => integer(),       %% EV_SERVER_SEND
    execution_end_time    => integer(),       %% EV_SERVER_SEND

    service        => woody:service_name(),  %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    service_schema => woody:service(),       %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    function       => woody:func(),          %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    type           => woody:rpc_type(),      %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    args           => woody:args(),          %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    metadata       => woody_context:meta(),  %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND
    deadline       => woody:deadline(),      %% EV_INVOKE_SERVICE_HANDLER | EV_SERVICE_HANDLER_RESULT | EV_SERVER_SEND

    result   => woody:result()               |   %% EV_SERVICE_HANDLER_RESULT
                woody_error:business_error() |
                woody_error:system_error()   |
                _Error,
    ignore       => boolean(),                   %% EV_SERVICE_HANDLER_RESULT
    except_class => woody_error:erlang_except(), %% EV_SERVICE_HANDLER_RESULT
    class        => business | system,           %% EV_SERVICE_HANDLER_RESULT
    stack        => woody_error:stack()          %% EV_SERVICE_HANDLER_RESULT
}.
-export_meta([meta_server/0]).

-type meta_internal_error() :: #{
    role   := woody:role(),
    error  := any(),
    reason := any(),
    class  := atom(),
    final  => boolean(),  %% Server handler failed and woody_server_thrift_http_handler:terminate/3
                          %% is called abnormally.
                          %% Cleanup proc dict if necessary: this is the last event in request flow
                          %% on woody server and the proces is about to be returned to cowboy pool.

    service        => woody:service_name(),
    service_schema => woody:service(),
    function => woody:func(),
    type     => woody:rpc_type(),
    args     => woody:args(),
    metadata => woody_context:meta()
}.
-type meta_trace() :: #{
    event       := binary(),
    role        := woody:role(),
    url         => woody:url(),
    code        => woody:http_code(),
    headers     => woody:http_headers(),
    body        => woody:http_body(),
    body_status => atom()
}.
-export_type([meta_internal_error/0, meta_trace/0]).
-type meta_client_cache() :: #{
    role           := client,
    service        := woody:service_name(),
    service_schema := woody:service(),
    function       := woody:func(),
    type           := woody:rpc_type(),
    args           := woody:args(),
    metadata       := woody_context:meta(),

    url      := woody:url(),
    result   => woody:result() %% EV_CLIENT_CACHE_HIT | EV_CLIENT_CACHE_UPDATE
}.
-export_type([meta_client_cache/0]).

-type event_meta() :: meta_client() | meta_server() | meta_internal_error() | meta_trace() | meta_client_cache().
-export_type([event_meta/0]).

-callback handle_event
    (event_client(), woody:rpc_id(), meta_client(), woody:options()) -> _;
    (event_server(), woody:rpc_id(), meta_server(), woody:options()) -> _;
    (event_cache(), woody:rpc_id(), meta_client_cache(), woody:options()) -> _;

    (?EV_INTERNAL_ERROR, woody:rpc_id(), meta_internal_error(), woody:options()) -> _;
    (?EV_TRACE, woody:rpc_id() | undefined, meta_trace(), woody:options()) -> _.


%% Util Types
-type status() :: ok | error.
-export_type([status/0]).

-type severity() :: debug | info | warning | error.
-type msg     () :: {list(), list()}.
-type log_msg () :: {severity(), msg()}.
-type meta_key() :: event | role | service | service_schema | function | type | args |
                    metadata | deadline | status | url | code | result.
-export_type([severity/0, msg/0, log_msg/0, meta_key/0]).

-type meta() :: #{atom() => _}.
-export_type([meta/0]).


%%
%% API
%%
-spec handle_event(event(), woody_state:st(), meta()) ->
    ok.
handle_event(Event, WoodyState, ExtraMeta) ->
    EvMeta = maybe_add_exec_time(Event, woody_state:get_ev_meta(WoodyState)),
    handle_event(
        woody_state:get_ev_handler(WoodyState),
        Event,
        woody_context:get_rpc_id(woody_state:get_context(WoodyState)),
        maps:merge(EvMeta, ExtraMeta)
    ).

-spec handle_event(woody:ev_handlers(), event(), woody:rpc_id() | undefined, event_meta()) ->
    ok.
handle_event(Handlers, Event, RpcId, Meta) when is_list(Handlers) ->
    lists:foreach(
        fun(Handler) ->
            {Module, Opts} = woody_util:get_mod_opts(Handler),
            _ = Module:handle_event(Event, RpcId, Meta, Opts)
        end,
        Handlers),
    ok;
handle_event(Handler, Event, RpcId, Meta) ->
    handle_event([Handler], Event, RpcId, Meta).

-spec format_rpc_id(woody:rpc_id() | undefined) ->
    msg().
format_rpc_id(#{span_id:=Span, trace_id:=Trace, parent_id:=Parent}) ->
    {"[~s ~s ~s]", [Trace, Parent, Span]};
format_rpc_id(undefined) ->
    {"~p", [undefined]}.

-spec format_event(event(), event_meta(), woody:rpc_id() | undefined) ->
    log_msg().
format_event(Event, Meta, RpcId) ->
    {Severity, Msg} = format_event(Event, Meta),
    {Severity, append_msg(format_rpc_id(RpcId), Msg)}.

-spec format_event_and_meta(event(), event_meta(), woody:rpc_id() | undefined) ->
    {severity(), msg(), meta()}.
format_event_and_meta(Event, Meta, RpcID) ->
    format_event_and_meta(Event, Meta, RpcID, [role, service, function, type]).

-spec format_event_and_meta(event(), event_meta(), woody:rpc_id() | undefined, list(meta_key())) ->
    {severity(), msg(), meta()}.
format_event_and_meta(Event, Meta, RpcID, EssentialMetaKeys) ->
    {Severity, Msg} = format_event(Event, Meta, RpcID),
    {Severity, Msg, get_essential_meta(Meta, Event, EssentialMetaKeys)}.

get_essential_meta(Meta, Event, Keys) ->
    Meta1 = maps:with(Keys, Meta),
    Meta2 = case lists:member(event, Keys) of
        true ->
            Meta1#{event => Event};
        false ->
            Meta1
    end,
    format_deadline(Meta2).

format_deadline(Meta = #{deadline := Deadline}) when Deadline =/= undefined ->
    Meta#{deadline => woody_deadline:to_binary(Deadline)};
format_deadline(Meta) ->
    Meta.

-spec format_event(event(), event_meta()) ->
    log_msg().
format_event(?EV_CLIENT_BEGIN, _Meta) ->
    {debug, {"[client] request begin", []}};
format_event(?EV_CLIENT_END, _Meta) ->
    {debug, {"[client] request end", []}};
format_event(?EV_CALL_SERVICE, Meta) ->
    {info, append_msg({"[client] calling ", []}, format_service_request(Meta))};
format_event(?EV_SERVICE_RESULT, #{status:=error, result:=Error, stack:= Stack}) ->
    {error, format_exception({"[client] error while handling request: ~p", [Error]}, Stack)};
format_event(?EV_SERVICE_RESULT, #{status:=error, result:=Result}) ->
    {warning, {"[client] error while handling request ~p", [Result]}};
format_event(?EV_SERVICE_RESULT, #{status:=ok, result:=_Result} = Meta) ->
    {info, append_msg({"[client] request handled successfully: ", []}, format_service_reply(Meta))};
format_event(?EV_CLIENT_SEND, #{url:=URL}) ->
    {debug, {"[client] sending request to ~s", [URL]}};
format_event(?EV_CLIENT_RESOLVE_BEGIN, #{host:=Host}) ->
    {debug, {"[client] resolving location of ~s", [Host]}};
format_event(?EV_CLIENT_RESOLVE_RESULT, #{status:=ok, host:=Host, address:=Address}) ->
    {debug, {"[client] resolved location of ~s to ~ts", [Host, Address]}};
format_event(?EV_CLIENT_RESOLVE_RESULT, #{status:=error, host:=Host, reason:=Reason}) ->
    {debug, {"[client] resolving location of ~s failed due to: ~ts", [Host, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=ok, code:=Code, reason:=Reason}) ->
    {debug, {"[client] received response with code ~p and info details: ~ts", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=ok, code:=Code}) ->
    {debug, {"[client] received response with code ~p", [Code]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, code:=Code, reason:=Reason}) ->
    {warning, {"[client] received response with code ~p and details: ~ts", [Code, Reason]}};
format_event(?EV_CLIENT_RECEIVE, #{status:=error, reason:=Reason}) ->
    {warning, {"[client] sending request error ~ts", [Reason]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=ok}) ->
    {debug, {"[server] request to ~s received", [URL]}};
format_event(?EV_SERVER_RECEIVE, #{url:=URL, status:=error, reason:=Reason}) ->
    {debug, {"[server] request to ~s unpacking error ~ts", [URL, Reason]}};
format_event(?EV_SERVER_SEND, #{status:=ok, code:=Code}) ->
    {debug, {"[server] response sent with code ~p", [Code]}};
format_event(?EV_SERVER_SEND, #{status:=error, code:=Code}) ->
    {warning, {"[server] response sent with code ~p", [Code]}};
format_event(?EV_INVOKE_SERVICE_HANDLER, Meta) ->
    {info, append_msg({"[server] handling ", []}, format_service_request(Meta))};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=ok, result:=_Result} = Meta) ->
    {info, append_msg({"[server] handling result: ", []}, format_service_reply(Meta))};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=business, result:=Error}) ->
    {info, {"[server] handling result business error: ~p", [Error]}};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=system, result:=Error, stack:=Stack,
    except_class:=Class})
->
    {error, format_exception({"[server] handling system internal error: ~s:~p", [Class, Error]}, Stack)};
format_event(?EV_SERVICE_HANDLER_RESULT, #{status:=error, class:=system, result:=Error}) ->
    {warning, {"[server] handling system woody error: ~p", [Error]}};
format_event(?EV_CLIENT_CACHE_BEGIN, _Meta) ->
    {debug, {"[client] request begin", []}};
format_event(?EV_CLIENT_CACHE_END, _Meta) ->
    {debug, {"[client] request end", []}};
format_event(?EV_CLIENT_CACHE_HIT, #{url := URL}) ->
    {info, {"[client] request to '~s' cache hit", [URL]}};
format_event(?EV_CLIENT_CACHE_MISS, #{url := URL}) ->
    {debug, {"[client] request to '~s' cache miss", [URL]}};
format_event(?EV_CLIENT_CACHE_UPDATE, #{url := URL, result := _Result} = Meta) ->
    {debug, append_msg({"[client] request to '~s' cache update: ", [URL]}, format_service_reply(Meta))};
format_event(?EV_CLIENT_CACHE_RESULT, #{url := URL, result := _Result} = Meta) ->
    {debug, append_msg({"[client] request to '~s' cache result: ", [URL]}, format_service_reply(Meta))};
format_event(?EV_INTERNAL_ERROR, #{role:=Role, error:=Error, class := Class, reason:=Reason, stack:=Stack}) ->
    {error, format_exception({"[~p] internal error ~ts ~s:~ts", [Role, Error, Class, Reason]}, Stack)};
format_event(?EV_INTERNAL_ERROR, #{role:=Role, error:=Error, reason:=Reason}) ->
    {warning, {"[~p] internal error ~p, ~ts", [Role, Error, Reason]}};
format_event(?EV_TRACE, Meta = #{event:=Event, role:=Role, headers:=Headers, body:=Body}) ->
    {debug, {"[~p] trace ~s, with ~p~nheaders:~n~p~nbody:~n~ts", [Role, Event, get_url_or_code(Meta), Headers, Body]}};
format_event(?EV_TRACE, #{event:=Event, role:=Role}) ->
    {debug, {"[~p] trace ~ts", [Role, Event]}};
format_event(UnknownEventType, Meta) ->
    {warning, {" unknown woody event type '~s' with meta ~p", [UnknownEventType, Meta]}}.

%%
%% Internal functions
%%
-spec format_service_request(map()) ->
    msg().
format_service_request(#{service_schema := {Module, Service}, function:=Function, args:=Args}) ->
    woody_event_formatter:format_call(Module, Service, Function, Args).

-spec format_service_reply(map()) ->
    msg().
format_service_reply(#{service_schema := {Module, Service}, function:=Function, result:={_, Result}} = Meta) ->
    FormatasException =  maps:get(format_as_exception, Meta, false),
    woody_event_formatter:format_reply(Module, Service, Function, Result, FormatasException);
format_service_reply(#{service_schema := {Module, Service}, function:=Function, status := ok, result:=Result} = Meta) ->
    FormatasException =  maps:get(format_as_exception, Meta, false),
    woody_event_formatter:format_reply(Module, Service, Function, Result, FormatasException);
format_service_reply(Result) ->
    {"~w", [Result]}.

-spec format_exception(msg(), woody_error:stack()) ->
    msg().
format_exception(BaseMsg, Stack) ->
    append_msg(BaseMsg, {"~n~s", [genlib_format:format_stacktrace(Stack, [newlines])]}).

-spec append_msg(msg(), msg()) ->
    msg().
append_msg({F1, A1}, {F2, A2}) ->
    {F1 ++ F2, A1 ++ A2}.

get_url_or_code(#{url := Url}) ->
    Url;
get_url_or_code(#{code := Code}) ->
    Code.

maybe_add_exec_time(Event, #{execution_start_time := ExecutionStartTime} = WoodyStateEvMeta) when
    Event =:= ?EV_CLIENT_RECEIVE; Event =:= ?EV_SERVER_SEND ->

    ExecutionEndTime = os:system_time(millisecond),
    ExecutionTimeMs =  ExecutionEndTime - ExecutionStartTime,
    WoodyStateEvMeta#{
        execution_end_time => ExecutionEndTime,
        execution_duration_ms => ExecutionTimeMs
    };
maybe_add_exec_time(_Event, WoodyStateEvMeta) ->
    WoodyStateEvMeta.


-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-spec test() -> _.

format_msg({Fmt, Params}) ->
    lists:flatten(
        io_lib:format(Fmt, Params)
    ).

-spec format_service_request_test_() -> _.
format_service_request_test_() -> [
    ?_assertEqual(
        lists:flatten(
            "PartyManagement:Create(party_id = '1CQdDqPROyW', params = PartyParams{",
            "contact_info = PartyContactInfo{email = 'hg_ct_helper'}})"
        ),
        format_msg(
            format_service_request(
                #{args =>
                [undefined, <<"1CQdDqPROyW">>,
                    {payproc_PartyParams, {domain_PartyContactInfo, <<"hg_ct_helper">>}}],
                    deadline => undefined, execution_start_time => 1565596875497,
                    function => 'Create',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "PartyManagement:Create(user = UserInfo{id = '1CQdDqPROyW', type = UserType{",
            "external_user = ExternalUser{}}}, params = PartyParams{contact_info = PartyContactInfo{",
            "email = 'hg_ct_helper'}})"
            ]),
        format_msg(
            format_service_request(
                #{args =>
                [{payproc_UserInfo, <<"1CQdDqPROyW">>,
                    {external_user, {payproc_ExternalUser}}}, undefined,
                    {payproc_PartyParams, {domain_PartyContactInfo, <<"hg_ct_helper">>}}],
                    deadline => undefined, execution_start_time => 1565596875497,
                    function => 'Create',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:Get(party_id = '1CQdDqPROyW')",
        format_msg(
            format_service_request(
                #{args => [undefined, <<"1CQdDqPROyW">>],
                    deadline => undefined, execution_start_time => 1565596875696,
                    function => 'Get',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten(
            "CustomerManagement:Create(params = CustomerParams{party_id = '1CQdDqPROyW', shop_id = '1CQdDwgt3R3', ",
            "contact_info = ContactInfo{email = 'invalid_shop'}, metadata = Value{nl = Null{}}})"
        ),
        format_msg(
            format_service_request(
                #{args =>
                [{payproc_CustomerParams, <<"1CQdDqPROyW">>, <<"1CQdDwgt3R3">>,
                    {domain_ContactInfo, undefined, <<"invalid_shop">>},
                    {nl, {json_Null}}}],
                    deadline => undefined,
                    execution_start_time => 1565596876258,
                    function => 'Create',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'CustomerManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'CustomerManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten(
            "PartyManagement:GetRevision(user = UserInfo{id = '1CQdDqPROyW', type = UserType{",
            "external_user = ExternalUser{}}}, party_id = '1CQdDqPROyW')"
        ),
        format_msg(
            format_service_request(
                #{args =>
                [{payproc_UserInfo, <<"1CQdDqPROyW">>,
                    {external_user, {payproc_ExternalUser}}},
                    <<"1CQdDqPROyW">>],
                    deadline => {{{2019, 8, 12}, {8, 1, 46}}, 263},
                    execution_start_time => 1565596876266, function => 'GetRevision',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten(
            "PartyManagement:Checkout(user = UserInfo{id = '1CQdDqPROyW', type = UserType{",
            "external_user = ExternalUser{}}}, party_id = '1CQdDqPROyW', revision = PartyRevisionParam{revision = 1})"
        ),
        format_msg(
            format_service_request(
                #{args =>
                [{payproc_UserInfo, <<"1CQdDqPROyW">>,
                    {external_user, {payproc_ExternalUser}}},
                    <<"1CQdDqPROyW">>,
                    {revision, 1}],
                    deadline => {{{2019, 8, 12}, {8, 1, 46}}, 263},
                    execution_start_time => 1565596876292,
                    function => 'Checkout',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:Block(party_id = '1CQdDqPROyW', reason = '')",
        format_msg(
            format_service_request(
                #{args => [undefined, <<"1CQdDqPROyW">>, <<>>],
                    deadline => undefined,
                    execution_start_time => 1565596876383,
                    function => 'Block',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server,
                    service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:Unblock(party_id = '1CQdDqPROyW', reason = '')",
        format_msg(
            format_service_request(
                #{args => [undefined, <<"1CQdDqPROyW">>, <<>>],
                    deadline => undefined,
                    execution_start_time => 1565596876458,
                    function => 'Unblock',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CQdDqPROyW">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server,
                    service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "Processor:ProcessSignal(a = SignalArgs{signal = Signal{init = InitSignal{arg = Value{bin = <<...>>}}}, ",
            "machine = Machine{ns = 'party', id = '1CQxZsCgLJY', history = [], history_range = HistoryRange{",
            "direction = forward}, aux_state = Content{data = Value{bin = ''}}, aux_state_legacy = Value{bin = ''}}})"
        ]),
        format_msg(
            format_service_request(
                #{args =>
                [{mg_stateproc_SignalArgs,
                    {init,
                        {mg_stateproc_InitSignal,
                            {bin,
                                <<131, 109, 0, 0, 0, 24, 12, 0, 1, 11, 0, 1, 0, 0, 0, 12, 104, 103, 95,
                                    99, 116, 95, 104, 101, 108, 112, 101, 114, 0, 0>>}}},
                    {mg_stateproc_Machine, <<"party">>, <<"1CQxZsCgLJY">>, [],
                        {mg_stateproc_HistoryRange, undefined, undefined, forward},
                        {mg_stateproc_Content, undefined, {bin, <<>>}},
                        undefined,
                        {bin, <<>>}}}],
                    deadline => {{{2019, 8, 12}, {12, 46, 36}}, 433},
                    execution_start_time => 1565613966542,
                    function => 'ProcessSignal',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CQxZsCgLJY">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server,
                    service => 'Processor',
                    service_schema => {mg_proto_state_processing_thrift, 'Processor'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{",
            "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ",
            "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, ",
            "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = ",
            "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', ",
            "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, ",
            "Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', ",
            "representative_full_name = 'Someone', representative_document = '100$ banknote', ",
            "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', ",
            "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...skipped 2 entry(-ies)..., ",
            "PartyModification{shop_modification = ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ",
            "ShopModification{shop_account_creation = ShopAccountParams{currency = CurrencyRef{",
            "symbolic_code = 'RUB'}}}}}])"
        ]),
        format_msg(
            format_service_request(
                #{args =>
                [undefined, <<"1CR1Xziml7o">>,
                    [{contract_modification,
                        {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
                            {creation,
                                {payproc_ContractParams, undefined,
                                    {domain_ContractTemplateRef, 1},
                                    {domain_PaymentInstitutionRef, 1},
                                    {legal_entity,
                                        {russian_legal_entity,
                                            {domain_RussianLegalEntity, <<"Hoofs & Horns OJSC">>,
                                                <<"1234509876">>, <<"1213456789012">>,
                                                <<"Nezahualcoyotl 109 Piso 8, Centro, 06082, MEXICO">>, <<"NaN">>,
                                                <<"Director">>, <<"Someone">>, <<"100$ banknote">>,
                                                {domain_RussianBankAccount, <<"4276300010908312893">>,
                                                    <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}}}}}},
                        {contract_modification,
                            {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
                                {payout_tool_modification,
                                    {payproc_PayoutToolModificationUnit, <<"1CR1Y2ZcrA1">>,
                                        {creation,
                                            {payproc_PayoutToolParams,
                                                {domain_CurrencyRef, <<"RUB">>},
                                                {russian_bank_account,
                                                    {domain_RussianBankAccount, <<"4276300010908312893">>,
                                                        <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}}}}}},
                        {shop_modification,
                            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                                {creation,
                                    {payproc_ShopParams,
                                        {domain_CategoryRef, 1},
                                        {url, <<>>},
                                        {domain_ShopDetails, <<"Battle Ready Shop">>, undefined},
                                        <<"1CR1Y2ZcrA0">>, <<"1CR1Y2ZcrA1">>}}}},
                        {shop_modification,
                            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                                {shop_account_creation,
                                    {payproc_ShopAccountParams, {domain_CurrencyRef, <<"RUB">>}}}}}]],
                    deadline => undefined,
                    execution_start_time => 1565617299263,
                    function => 'CreateClaim',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CR1Xziml7o">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server, service => 'PartyManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<...>>}, machine = Machine{ns = 'party', ",
            "id = '1CSHThTEJ84', history = [Event{id = 1, created_at = '2019-08-13T07:52:11.080519Z', ",
            "data = Value{arr = [Value{obj = #{Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}, ",
            "Value{str = 'vsn'} => Value{i = 6}}}, Value{bin = <<...>>}]}}], history_range = HistoryRange{",
            "limit = 10, direction = backward}, aux_state = Content{data = Value{obj = #{Value{str = 'aux_state'} ",
            "=> Value{bin = <<...>>}, Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}}}}, ",
            "aux_state_legacy = Value{obj = #{Value{str = 'aux_state'} => Value{bin = <<...>>}, Value{str = 'ct'} ",
            "=> Value{str = 'application/x-erlang-binary'}}}}})"
        ]),
        format_msg(
            format_service_request(
                #{args =>
                [{mg_stateproc_CallArgs,
                    {bin,
                        <<131, 104, 4, 100, 0, 11, 116, 104, 114, 105, 102, 116, 95, 99, 97, 108, 108,
                            100, 0, 16, 112, 97, 114, 116, 121, 95, 109, 97, 110, 97, 103, 101, 109, 101,
                            110, 116, 104, 2, 100, 0, 15, 80, 97, 114, 116, 121, 77, 97, 110, 97, 103,
                            101, 109, 101, 110, 116, 100, 0, 11, 67, 114, 101, 97, 116, 101, 67, 108, 97,
                            105, 109, 109, 0, 0, 2, 145, 11, 0, 2, 0, 0, 0, 11, 49, 67, 83, 72, 84, 104, 84,
                            69, 74, 56, 52, 15, 0, 3, 12, 0, 0, 0, 4, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67,
                            83, 72, 84, 106, 75, 108, 51, 52, 75, 12, 0, 2, 12, 0, 1, 12, 0, 2, 8, 0, 1, 0, 0,
                            0, 1, 0, 12, 0, 3, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 1, 12, 0, 1, 12, 0, 1, 11, 0, 1, 0, 0,
                            0, 18, 72, 111, 111, 102, 115, 32, 38, 32, 72, 111, 114, 110, 115, 32, 79, 74,
                            83, 67, 11, 0, 2, 0, 0, 0, 10, 49, 50, 51, 52, 53, 48, 57, 56, 55, 54, 11, 0, 3, 0,
                            0, 0, 13, 49, 50, 49, 51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 11, 0, 4, 0, 0, 0,
                            48, 78, 101, 122, 97, 104, 117, 97, 108, 99, 111, 121, 111, 116, 108, 32, 49,
                            48, 57, 32, 80, 105, 115, 111, 32, 56, 44, 32, 67, 101, 110, 116, 114, 111,
                            44, 32, 48, 54, 48, 56, 50, 44, 32, 77, 69, 88, 73, 67, 79, 11, 0, 5, 0, 0, 0, 3,
                            78, 97, 78, 11, 0, 6, 0, 0, 0, 8, 68, 105, 114, 101, 99, 116, 111, 114, 11, 0, 7,
                            0, 0, 0, 7, 83, 111, 109, 101, 111, 110, 101, 11, 0, 8, 0, 0, 0, 13, 49, 48, 48,
                            36, 32, 98, 97, 110, 107, 110, 111, 116, 101, 12, 0, 9, 11, 0, 1, 0, 0, 0, 19,
                            52, 50, 55, 54, 51, 48, 48, 48, 49, 48, 57, 48, 56, 51, 49, 50, 56, 57, 51, 11,
                            0, 2, 0, 0, 0, 8, 83, 111, 109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9, 49,
                            50, 51, 49, 50, 57, 56, 55, 54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54,
                            54, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106,
                            75, 108, 51, 52, 75, 12, 0, 2, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84,
                            106, 75, 108, 51, 52, 76, 12, 0, 2, 12, 0, 1, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82,
                            85, 66, 0, 12, 0, 2, 12, 0, 1, 11, 0, 1, 0, 0, 0, 19, 52, 50, 55, 54, 51, 48, 48,
                            48, 49, 48, 57, 48, 56, 51, 49, 50, 56, 57, 51, 11, 0, 2, 0, 0, 0, 8, 83, 111,
                            109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9, 49, 50, 51, 49, 50, 57, 56, 55,
                            54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54, 54, 0, 0, 0, 0, 0, 0, 0, 0, 12,
                            0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 77, 12, 0,
                            2, 12, 0, 5, 12, 0, 1, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 0, 0, 12, 0,
                            2, 11, 0, 1, 0, 0, 0, 17, 66, 97, 116, 116, 108, 101, 32, 82, 101, 97, 100, 121,
                            32, 83, 104, 111, 112, 0, 11, 0, 3, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75,
                            108, 51, 52, 75, 11, 0, 4, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52,
                            76, 0, 0, 0, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108,
                            51, 52, 77, 12, 0, 2, 12, 0, 12, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82, 85, 66, 0, 0, 0,
                            0, 0, 0>>},
                    {mg_stateproc_Machine, <<"party">>, <<"1CSHThTEJ84">>,
                        [{mg_stateproc_Event, 1, <<"2019-08-13T07:52:11.080519Z">>,
                            undefined,
                            {arr,
                                [{obj,
                                    #{{str, <<"ct">>} =>
                                    {str, <<"application/x-erlang-binary">>},
                                        {str, <<"vsn">>} => {i, 6}}},
                                    {bin,
                                        <<131, 104, 2, 100, 0, 13, 112, 97, 114, 116, 121, 95,
                                            99, 104, 97, 110, 103, 101, 115, 108, 0, 0, 0, 2, 104,
                                            2, 100, 0, 13, 112, 97, 114, 116, 121, 95, 99, 114,
                                            101, 97, 116, 101, 100, 104, 4, 100, 0, 20, 112, 97,
                                            121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121, 67,
                                            114, 101, 97, 116, 101, 100, 109, 0, 0, 0, 11, 49, 67,
                                            83, 72, 84, 104, 84, 69, 74, 56, 52, 104, 2, 100, 0, 23,
                                            100, 111, 109, 97, 105, 110, 95, 80, 97, 114, 116,
                                            121, 67, 111, 110, 116, 97, 99, 116, 73, 110, 102,
                                            111, 109, 0, 0, 0, 12, 104, 103, 95, 99, 116, 95, 104,
                                            101, 108, 112, 101, 114, 109, 0, 0, 0, 27, 50, 48, 49,
                                            57, 45, 48, 56, 45, 49, 51, 84, 48, 55, 58, 53, 50, 58,
                                            49, 49, 46, 48, 55, 50, 56, 51, 53, 90, 104, 2, 100, 0,
                                            16, 114, 101, 118, 105, 115, 105, 111, 110, 95, 99,
                                            104, 97, 110, 103, 101, 100, 104, 3, 100, 0, 28, 112,
                                            97, 121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121,
                                            82, 101, 118, 105, 115, 105, 111, 110, 67, 104, 97,
                                            110, 103, 101, 100, 109, 0, 0, 0, 27, 50, 48, 49, 57,
                                            45, 48, 56, 45, 49, 51, 84, 48, 55, 58, 53, 50, 58, 49,
                                            49, 46, 48, 55, 50, 56, 51, 53, 90, 97, 0, 106>>}]}}],
                        {mg_stateproc_HistoryRange, undefined, 10, backward},
                        {mg_stateproc_Content, undefined,
                            {obj,
                                #{{str, <<"aux_state">>} =>
                                {bin,
                                    <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116,
                                        121, 95, 114, 101, 118, 105, 115, 105, 111, 110, 95,
                                        105, 110, 100, 101, 120, 116, 0, 0, 0, 0, 100, 0, 14,
                                        115, 110, 97, 112, 115, 104, 111, 116, 95, 105, 110,
                                        100, 101, 120, 106>>},
                                    {str, <<"ct">>} => {str, <<"application/x-erlang-binary">>}}}},
                        undefined,
                        {obj,
                            #{{str, <<"aux_state">>} =>
                            {bin,
                                <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116, 121, 95,
                                    114, 101, 118, 105, 115, 105, 111, 110, 95, 105, 110, 100,
                                    101, 120, 116, 0, 0, 0, 0, 100, 0, 14, 115, 110, 97, 112,
                                    115, 104, 111, 116, 95, 105, 110, 100, 101, 120, 106>>},
                                {str, <<"ct">>} =>
                                {str, <<"application/x-erlang-binary">>}}}}}],
                    deadline => {{{2019, 8, 13}, {7, 52, 41}}, 105},
                    execution_start_time => 1565682731109,
                    function => 'ProcessCall',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CSHThTEJ84">>,
                        <<"user-identity.realm">> => <<"external">>},
                    role => server,
                    service => 'Processor',
                    service_schema => {mg_proto_state_processing_thrift, 'Processor'},
                    type => call}
            )
        )
    )
].

-spec result_test_() -> _.
result_test_() -> [
    ?_assertEqual(
        lists:flatten([
            "CallResult{response = Value{bin = <<131,100,0,2,111,107>>}, change = MachineStateChange{",
            "aux_state = Content{data = Value{obj = #{Value{str = 'aux_state'} => Value{bin = <<...>>}, ",
            "Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}}}}, events = [Content{data = Value{",
            "arr = [Value{obj = #{Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}, ",
            "Value{str = 'vsn'} => Value{i = 6}}}, Value{bin = <<...>>}]}}]}, action = ComplexAction{}}"
        ]),
        format_msg(
            format_service_reply(
                #{
                    deadline => {{{2019, 8, 13}, {11, 19, 32}}, 986},
                    execution_start_time => 1565695142994,
                    function => 'ProcessCall',
                    metadata =>
                        #{<<"user-identity.id">> => <<"1CSWG2vduGe">>,
                        <<"user-identity.realm">> => <<"external">>},
                    result =>
                    {ok, {mg_stateproc_CallResult,
                        {bin, <<131, 100, 0, 2, 111, 107>>},
                        {mg_stateproc_MachineStateChange,
                            {mg_stateproc_Content, undefined,
                                {obj,
                                    #{{str, <<"aux_state">>} =>
                                    {bin,
                                        <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116,
                                            121, 95, 114, 101, 118, 105, 115, 105, 111, 110,
                                            95, 105, 110, 100, 101, 120, 116, 0, 0, 0, 7, 97, 0,
                                            104, 2, 97, 1, 97, 1, 97, 1, 104, 2, 97, 2, 97, 2, 97,
                                            2, 104, 2, 97, 3, 97, 3, 97, 3, 104, 2, 97, 4, 97, 4,
                                            97, 4, 104, 2, 97, 5, 97, 5, 97, 5, 104, 2, 97, 6, 97,
                                            6, 97, 6, 104, 2, 97, 7, 97, 7, 100, 0, 14, 115, 110,
                                            97, 112, 115, 104, 111, 116, 95, 105, 110, 100,
                                            101, 120, 106>>},
                                        {str, <<"ct">>} =>
                                        {str, <<"application/x-erlang-binary">>}}}},
                            [{mg_stateproc_Content, undefined,
                                {arr,
                                    [{obj,
                                        #{{str, <<"ct">>} =>
                                        {str, <<"application/x-erlang-binary">>},
                                            {str, <<"vsn">>} => {i, 6}}},
                                        {bin,
                                            <<131, 104, 2, 100, 0, 13, 112, 97, 114, 116, 121,
                                                95, 99, 104, 97, 110, 103, 101, 115, 108, 0, 0, 0,
                                                2, 104, 2, 100, 0, 13, 115, 104, 111, 112, 95, 98,
                                                108, 111, 99, 107, 105, 110, 103, 104, 3, 100, 0,
                                                20, 112, 97, 121, 112, 114, 111, 99, 95, 83, 104,
                                                111, 112, 66, 108, 111, 99, 107, 105, 110, 103,
                                                109, 0, 0, 0, 11, 49, 67, 83, 87, 71, 56, 106, 48,
                                                52, 119, 77, 104, 2, 100, 0, 7, 98, 108, 111, 99,
                                                107, 101, 100, 104, 3, 100, 0, 14, 100, 111, 109,
                                                97, 105, 110, 95, 66, 108, 111, 99, 107, 101, 100,
                                                109, 0, 0, 0, 0, 109, 0, 0, 0, 27, 50, 48, 49, 57, 45,
                                                48, 56, 45, 49, 51, 84, 49, 49, 58, 49, 57, 58, 48,
                                                51, 46, 48, 49, 53, 50, 50, 50, 90, 104, 2, 100, 0,
                                                16, 114, 101, 118, 105, 115, 105, 111, 110, 95,
                                                99, 104, 97, 110, 103, 101, 100, 104, 3, 100, 0,
                                                28, 112, 97, 121, 112, 114, 111, 99, 95, 80, 97,
                                                114, 116, 121, 82, 101, 118, 105, 115, 105, 111,
                                                110, 67, 104, 97, 110, 103, 101, 100, 109, 0, 0, 0,
                                                27, 50, 48, 49, 57, 45, 48, 56, 45, 49, 51, 84, 49,
                                                49, 58, 49, 57, 58, 48, 51, 46, 48, 49, 53, 50, 50,
                                                50, 90, 97, 6, 106>>}]}}],
                            undefined, undefined},
                        {mg_stateproc_ComplexAction, undefined, undefined, undefined,
                            undefined}}},
                    role => server,
                    service => 'Processor',
                    service_schema => {mg_proto_state_processing_thrift, 'Processor'},
                    status => ok,
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "Party{id = '1CSWG2vduGe', contact_info = PartyContactInfo{email = 'hg_ct_helper'}, ",
            "created_at = '2019-08-13T11:19:01.249440Z', blocking = Blocking{unblocked = Unblocked{reason = '', ",
            "since = '2019-08-13T11:19:02.655869Z'}}, suspension = Suspension{active = Active{",
            "since = '2019-08-13T11:19:02.891892Z'}}, contractors = #{}, contracts = #{'1CSWG8j04wK' => ",
            "Contract{id = '1CSWG8j04wK', payment_institution = PaymentInstitutionRef{id = 1}, ",
            "created_at = '2019-08-13T11:19:01.387269Z', status = ContractStatus{active = ContractActive{}}, ",
            "terms = TermSetHierarchyRef{id = 1}, adjustments = [], payout_tools = [PayoutTool{id = '1CSWG8j04wL', ",
            "created_at = '2019-08-13T11:19:01.387269Z', currency = CurrencyRef{symbolic_code = 'RUB'}, ",
            "payout_tool_info = PayoutToolInfo{russian_bank_account = RussianBankAccount{",
            "account = '4276300010908312893', bank_name = 'SomeBank', bank_post_account = '123129876', ",
            "bank_bik = '66642666'}}}], contractor = Contractor{legal_entity = LegalEntity{",
            "russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', ",
            "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, ",
            "Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', ",
            "representative_full_name = 'Someone', representative_document = '100$ banknote', ",
            "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', ",
            "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}, shops = #{'1CSWG8j04wM' => ",
            "Shop{id = '1CSWG8j04wM', created_at = '2019-08-13T11:19:01.387269Z', blocking = Blocking{blocked = ",
            "Blocked{reason = '', since = '2019-08-13T11:19:03.015222Z'}}, suspension = Suspension{",
            "active = Active{since = '2019-08-13T11:19:01.387269Z'}}, details = ShopDetails{",
            "name = 'Battle Ready Shop'}, location = ShopLocation{url = ''}, category = CategoryRef{id = 1}, ",
            "account = ShopAccount{currency = CurrencyRef{symbolic_code = 'RUB'}, settlement = 7, guarantee = 6, ",
            "payout = 8}, contract_id = '1CSWG8j04wK', payout_tool_id = '1CSWG8j04wL'}}, wallets = #{}, revision = 6}"
        ]),
        format_msg(
            format_service_reply(
            #{args =>
            [{payproc_UserInfo, <<"1CSWG2vduGe">>,
                {external_user, {payproc_ExternalUser}}},
                <<"1CSWG2vduGe">>,
                {revision, 6}],
                deadline => {{{2019, 8, 13}, {11, 19, 33}}, 42},
                execution_start_time => 1565695143068,
                function => 'Checkout',
                metadata =>
                    #{<<"user-identity.id">> => <<"1CSWG2vduGe">>,
                    <<"user-identity.realm">> => <<"external">>},
                result =>
                {ok,
                    {domain_Party, <<"1CSWG2vduGe">>,
                        {domain_PartyContactInfo, <<"hg_ct_helper">>},
                        <<"2019-08-13T11:19:01.249440Z">>,
                        {unblocked, {domain_Unblocked, <<>>, <<"2019-08-13T11:19:02.655869Z">>}},
                        {active, {domain_Active, <<"2019-08-13T11:19:02.891892Z">>}},
                        #{},
                        #{<<"1CSWG8j04wK">> =>
                        {domain_Contract, <<"1CSWG8j04wK">>, undefined,
                            {domain_PaymentInstitutionRef, 1},
                            <<"2019-08-13T11:19:01.387269Z">>, undefined, undefined,
                            {active, {domain_ContractActive}},
                            {domain_TermSetHierarchyRef, 1},
                            [],
                            [{domain_PayoutTool, <<"1CSWG8j04wL">>,
                                <<"2019-08-13T11:19:01.387269Z">>,
                                {domain_CurrencyRef, <<"RUB">>},
                                {russian_bank_account,
                                    {domain_RussianBankAccount, <<"4276300010908312893">>,
                                        <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}],
                            undefined, undefined,
                            {legal_entity,
                                {russian_legal_entity,
                                    {domain_RussianLegalEntity, <<"Hoofs & Horns OJSC">>,
                                        <<"1234509876">>, <<"1213456789012">>,
                                        <<"Nezahualcoyotl 109 Piso 8, Centro, 06082, MEXICO">>, <<"NaN">>,
                                        <<"Director">>, <<"Someone">>, <<"100$ banknote">>,
                                        {domain_RussianBankAccount, <<"4276300010908312893">>,
                                            <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}}}},
                        #{<<"1CSWG8j04wM">> =>
                        {domain_Shop, <<"1CSWG8j04wM">>, <<"2019-08-13T11:19:01.387269Z">>,
                            {blocked, {domain_Blocked, <<>>, <<"2019-08-13T11:19:03.015222Z">>}},
                            {active, {domain_Active, <<"2019-08-13T11:19:01.387269Z">>}},
                            {domain_ShopDetails, <<"Battle Ready Shop">>, undefined},
                            {url, <<>>},
                            {domain_CategoryRef, 1},
                            {domain_ShopAccount, {domain_CurrencyRef, <<"RUB">>}, 7, 6, 8},
                            <<"1CSWG8j04wK">>, <<"1CSWG8j04wL">>, undefined}},
                        #{}, 6}},
                role => server,
                service => 'PartyManagement',
                service_schema => {dmsl_payment_processing_thrift, 'PartyManagement'},
                status => ok,
                type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "SignalResult{change = MachineStateChange{aux_state = Content{data = Value{obj = #{}}}, ",
            "events = [Content{data = Value{arr = [Value{arr = [Value{i = 2}, Value{obj = #{Value{",
            "str = 'change'} => Value{str = 'created'}, Value{str = 'contact_info'} => Value{obj = #{Value{",
            "str = 'email'} => Value{str = 'create_customer'}}}, Value{str = 'created_at'} => Value{",
            "str = '2019-08-13T11:19:03.714218Z'}, Value{str = 'customer_id'} => Value{str = '1CSWGJ3N8Ns'}, ",
            "Value{str = 'metadata'} => Value{nl = Nil{}}, Value{str = 'owner_id'} => Value{str = '1CSWG2vduGe'}, ",
            "Value{str = 'shop_id'} => Value{str = '1CSWG8j04wM'}}}]}]}}]}, action = ComplexAction{}}"
        ]),
        format_msg(
            format_service_reply(
                #{args =>
                [{mg_stateproc_SignalArgs,
                    {init,
                        {mg_stateproc_InitSignal,
                            {bin,
                                <<131, 109, 0, 0, 0, 71, 11, 0, 1, 0, 0, 0, 11,
                                    49, 67, 83, 87, 71, 50, 118, 100, 117, 71,
                                    101, 11, 0, 2, 0, 0, 0, 11, 49, 67, 83, 87,
                                    71, 56, 106, 48, 52, 119, 77, 12, 0, 3, 11,
                                    0, 2, 0, 0, 0, 15, 99, 114, 101, 97, 116,
                                    101, 95, 99, 117, 115, 116, 111, 109, 101,
                                    114, 0, 12, 0, 4, 12, 0, 1, 0, 0, 0>>}}},
                    {mg_stateproc_Machine, <<"customer">>, <<"1CSWGJ3N8Ns">>, [],
                        {mg_stateproc_HistoryRange, undefined, undefined, forward},
                        {mg_stateproc_Content, undefined, {bin, <<>>}},
                        undefined,
                        {bin, <<>>}}}],
                    deadline => {{{2019, 8, 13}, {11, 19, 33}}, 606},
                    execution_start_time => 1565695143707, function => 'ProcessSignal',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CSWG2vduGe">>,
                        <<"user-identity.realm">> => <<"external">>},
                    result =>
                    {ok,
                        {mg_stateproc_SignalResult,
                            {mg_stateproc_MachineStateChange,
                                {mg_stateproc_Content, undefined, {obj, #{}}},
                                [{mg_stateproc_Content, undefined,
                                    {arr,
                                        [{arr,
                                            [{i, 2},
                                                {obj,
                                                    #{{str, <<"change">>} => {str, <<"created">>},
                                                        {str, <<"contact_info">>} =>
                                                        {obj, #{{str, <<"email">>} => {str, <<"create_customer">>}}},
                                                        {str, <<"created_at">>} =>
                                                        {str, <<"2019-08-13T11:19:03.714218Z">>},
                                                        {str, <<"customer_id">>} => {str, <<"1CSWGJ3N8Ns">>},
                                                        {str, <<"metadata">>} => {nl, {mg_msgpack_Nil}},
                                                        {str, <<"owner_id">>} => {str, <<"1CSWG2vduGe">>},
                                                        {str, <<"shop_id">>} => {str, <<"1CSWG8j04wM">>}}}]}]}}],
                                undefined, undefined},
                            {mg_stateproc_ComplexAction, undefined, undefined, undefined, undefined}}},
                    role => server, service => 'Processor',
                    service_schema => {mg_proto_state_processing_thrift, 'Processor'},
                    status => ok, type => call}
            )
        )
    ),
    ?_assertEqual(
        lists:flatten([
            "SignalResult{change = MachineStateChange{aux_state = Content{data = Value{obj = #{}}}, ",
            "events = [Content{data = Value{arr = [Value{arr = [Value{i = 2}, Value{obj = #{Value{",
            "str = 'change'} => Value{str = 'created'}, Value{str = 'contact_info'} => Value{obj = #{",
            "Value{str = 'email'} => Value{str = 'create_customer'}}}, Value{str = 'created_at'} => Value{",
            "str = '2019-08-13T11:19:03.714218Z'}, Value{str = 'customer_id'} => Value{str = '1CSWGJ3N8Ns'}, ",
            "Value{str = 'metadata'} => Value{str = <<...>>}, Value{str = 'owner_id'} => Value{str = '1CSWG2vduGe'}, ",
            "Value{str = 'shop_id'} => Value{str = '1CSWG8j04wM'}}}]}]}}]}, action = ComplexAction{}}"
        ]),
        format_msg(
            format_service_reply(
                #{args =>
                [{mg_stateproc_SignalArgs,
                    {init,
                        {mg_stateproc_InitSignal,
                            {bin,
                                <<131, 109, 0, 0, 0, 71, 11, 0, 1, 0, 0, 0, 11,
                                    49, 67, 83, 87, 71, 50, 118, 100, 117, 71,
                                    101, 11, 0, 2, 0, 0, 0, 11, 49, 67, 83, 87,
                                    71, 56, 106, 48, 52, 119, 77, 12, 0, 3, 11,
                                    0, 2, 0, 0, 0, 15, 99, 114, 101, 97, 116,
                                    101, 95, 99, 117, 115, 116, 111, 109, 101,
                                    114, 0, 12, 0, 4, 12, 0, 1, 0, 0, 0>>}}},
                    {mg_stateproc_Machine, <<"customer">>, <<"1CSWGJ3N8Ns">>, [],
                        {mg_stateproc_HistoryRange, undefined, undefined, forward},
                        {mg_stateproc_Content, undefined, {bin, <<>>}},
                        undefined,
                        {bin, <<>>}}}],
                    deadline => {{{2019, 8, 13}, {11, 19, 33}}, 606},
                    execution_start_time => 1565695143707, function => 'ProcessSignal',
                    metadata =>
                    #{<<"user-identity.id">> => <<"1CSWG2vduGe">>,
                        <<"user-identity.realm">> => <<"external">>},
                    result =>
                    {ok,
                        {mg_stateproc_SignalResult,
                            {mg_stateproc_MachineStateChange,
                                {mg_stateproc_Content, undefined, {obj, #{}}},
                                [{mg_stateproc_Content, undefined,
                                    {arr,
                                        [{arr,
                                            [{i, 2},
                                                {obj,
                                                    #{{str, <<"change">>} => {str, <<"created">>},
                                                        {str, <<"contact_info">>} =>
                                                        {obj, #{{str, <<"email">>} => {str, <<"create_customer">>}}},
                                                        {str, <<"created_at">>} =>
                                                        {str, <<"2019-08-13T11:19:03.714218Z">>},
                                                        {str, <<"customer_id">>} => {str, <<"1CSWGJ3N8Ns">>},
                                                        {str, <<"metadata">>} => {str, <<208, 174, 208, 189, 208, 208,
                                                            186, 208, 190, 208, 180>>},
                                                        {str, <<"owner_id">>} => {str, <<"1CSWG2vduGe">>},
                                                        {str, <<"shop_id">>} => {str, <<"1CSWG8j04wM">>}}}]}]}}],
                                undefined, undefined},
                            {mg_stateproc_ComplexAction, undefined, undefined, undefined, undefined}}},
                    role => server, service => 'Processor',
                    service_schema => {mg_proto_state_processing_thrift, 'Processor'},
                    status => ok, type => call}
            )
        )
    )
].


-spec exception_test_() -> _.
exception_test_() -> [
    ?_assertEqual(
        "CustomerNotFound{}",
        format_msg(
            format_service_reply(
                #{args => [<<"1Cfo5OJzx6O">>],
                    deadline => undefined,
                    execution_start_time => 1566386841317,
                    format_as_exception => true,
                    function => 'Get',
                    metadata => #{
                        <<"user-identity.id">> => <<"1Cfo5EMKo40">>,
                        <<"user-identity.realm">> => <<"external">>},
                    result => {payproc_CustomerNotFound},
                    role => client,
                    service => 'CustomerManagement',
                    service_schema => {dmsl_payment_processing_thrift, 'CustomerManagement'},
                    status => ok,
                    type => call}
            )
        )
    ),
    ?_assertEqual(
        "OperationNotPermitted{}",
        format_msg(
            format_service_reply(
                #{args => [
                    undefined,
                    <<"1Cfo9igJRS4">>,
                    {payproc_InvoicePaymentParams, {payment_resource, {payproc_PaymentResourcePayerParams,
                        {domain_DisposablePaymentResource, {bank_card, {domain_BankCard, <<"no_preauth">>,
                            visa, <<"424242">>, <<"4242">>, undefined, undefined, undefined, undefined, undefined}},
                            <<"SESSION42">>, {domain_ClientInfo, undefined, undefined}},
                        {domain_ContactInfo, undefined, undefined}}},
                        {instant, {payproc_InvoicePaymentParamsFlowInstant}}, true, undefined, undefined, undefined}],
                    deadline => undefined, execution_start_time => 1566386899959,
                    format_as_exception => true,
                    function => 'StartPayment',
                    metadata => #{
                        <<"user-identity.id">> => <<"1Cfo8k9mLtA">>,
                        <<"user-identity.realm">> => <<"external">>},
                    result => {payproc_OperationNotPermitted}, role => client, service => 'Invoicing',
                    service_schema => {dmsl_payment_processing_thrift, 'Invoicing'},
                    status => ok, type => call}
            )
        )
    )

].
-endif.
