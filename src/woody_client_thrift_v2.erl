-module(woody_client_thrift_v2).

-behaviour(woody_client_behaviour).

-include_lib("thrift/include/thrift_constants.hrl").

-include("woody_defs.hrl").

%% woody_client_behaviour callback
-export([call/3]).
-export([child_spec/1]).

%% Types
-type options() :: #{
    url := woody:url(),
    event_handler := woody:ev_handlers(),
    transport_opts => transport_options(),
    resolver_opts => woody_resolver:options(),
    protocol => thrift,
    transport => http
}.

%% See hackney:request/5 for available options.
-type transport_options() :: map().

%% millisec
-define(DEFAULT_CONNECT_AND_SEND_TIMEOUT, 1000).
-define(DEFAULT_TRANSPORT_OPTIONS, #{
    connect_options => [
        % Turn TCP_NODELAY on.
        % We expect that Nagle's algorithm would not be very helpful for typical
        % Woody RPC workloads, negatively impacting perceived latency. So it's
        % better to turn it off.
        {nodelay, true}
    ]
}).

%%
%% API
%%
-spec child_spec(options()) -> supervisor:child_spec().
child_spec(Options) ->
    TransportOpts = get_transport_opts(Options),
    Name = maps:get(pool, TransportOpts, undefined),
    hackney_pool:child_spec(Name, maps:to_list(TransportOpts)).

-spec call(woody:request(), options(), woody_state:st()) -> woody_client:result().
call({Service = {_, ServiceName}, Function, Args}, Opts, WoodyState) ->
    WoodyContext = woody_state:get_context(WoodyState),
    WoodyState1 = woody_state:add_ev_meta(
        #{
            service => ServiceName,
            service_schema => Service,
            function => Function,
            type => woody_util:get_rpc_type(Service, Function),
            args => Args,
            deadline => woody_context:get_deadline(WoodyContext),
            metadata => woody_context:get_meta(WoodyContext)
        },
        WoodyState
    ),
    _ = log_event(?EV_CALL_SERVICE, WoodyState1, #{}),
    do_call(Service, Function, Args, Opts, WoodyState1).

%%
%% Internal functions
%%

-include_lib("hackney/include/hackney_lib.hrl").

-type http_headers() :: [{binary(), binary()}].
-type header_parse_value() :: none | woody:http_header_val().

-define(CODEC, thrift_strict_binary_codec).
-define(ERROR_RESP_BODY, <<"parse http response body error">>).
-define(ERROR_RESP_HEADER, <<"parse http response headers error">>).
-define(BAD_RESP_HEADER, <<"reason unknown due to bad ", ?HEADER_PREFIX/binary, "-error- headers">>).

-define(SERVER_VIOLATION_ERROR,
    {external, result_unexpected, <<
        "server violated thrift protocol: "
        "sent TApplicationException (unknown exception) with http code 200"
    >>}
).

-spec get_transport_opts(options()) -> woody_client_thrift_http_transport:transport_options().
get_transport_opts(Opts) ->
    maps:get(transport_opts, Opts, #{}).

-spec get_resolver_opts(options()) -> woody_resolver:options().
get_resolver_opts(Opts) ->
    maps:get(resolver_opts, Opts, #{}).

-spec do_call(woody:service(), woody:func(), woody:args(), options(), woody_state:st()) -> woody_client:result().
do_call(Service, Function, Args, Opts, WoodyState) ->
    Buffer = ?CODEC:new(),
    Result =
        case thrift_client_codec:write_function_call(Buffer, ?CODEC, Service, Function, Args, 0) of
            {ok, Buffer1} ->
                case send_call(Buffer1, Opts, WoodyState) of
                    {ok, Response} ->
                        handle_result(Service, Function, Response);
                    Error ->
                        Error
                end;
            Error ->
                Error
        end,
    log_result(Result, WoodyState),
    map_result(Result).

-spec handle_result(woody:service(), woody:func(), binary()) -> _Result.
handle_result(Service, Function, Response) ->
    Buffer = ?CODEC:new(Response),
    case thrift_client_codec:read_function_result(Buffer, ?CODEC, Service, Function, 0) of
        {ok, Result, Leftovers} ->
            Bytes = ?CODEC:close(Leftovers),
            case Result of
                ok when Bytes == <<>> ->
                    {ok, ok};
                {reply, Reply} when Bytes == <<>> ->
                    {ok, Reply};
                {exception, #'TApplicationException'{}} when Bytes == <<>> ->
                    {error, {system, ?SERVER_VIOLATION_ERROR}};
                {exception, Exception} when Bytes == <<>> ->
                    {error, {business, Exception}};
                _ ->
                    {error, {excess_response_body, Bytes, Result}}
            end;
        {error, _} = Error ->
            Error
    end.

%% erlfmt-ignore
-spec send_call(?CODEC:buffer(), options(), woody_state:st()) ->
    {ok, binary()} | {error, {system, _}}.

send_call(Buffer, #{url := Url} = Opts, WoodyState) ->
    Context = woody_state:get_context(WoodyState),
    TransportOpts = get_transport_opts(Opts),
    ResolverOpts = get_resolver_opts(Opts),
    case is_deadline_reached(Context) of
        true ->
            _ = log_event(?EV_INTERNAL_ERROR, WoodyState, #{status => error, reason => <<"Deadline reached">>}),
            {error, {system, {internal, resource_unavailable, <<"deadline reached">>}}};
        false ->
            _ = log_event(?EV_CLIENT_SEND, WoodyState, #{url => Url}),
            % MSPF-416: We resolve url host to an ip here to prevent
            % reusing keep-alive connections to dead hosts
            case woody_resolver:resolve_url(Url, WoodyState, ResolverOpts) of
                {ok, {OldUrl, NewUrl}} ->
                    Headers = add_host_header(OldUrl, make_woody_headers(Context)),
                    TransportOpts1 = set_defaults(TransportOpts),
                    TransportOpts2 = set_timeouts(TransportOpts1, Context),
                    Result = hackney:request(post, NewUrl, Headers, Buffer, maps:to_list(TransportOpts2)),
                    handle_response(Result, WoodyState);
                {error, Reason} ->
                    Error = {error, {resolve_failed, Reason}},
                    handle_response(Error, WoodyState)
            end
    end.

is_deadline_reached(Context) ->
    woody_deadline:is_reached(woody_context:get_deadline(Context)).

set_defaults(Options) ->
    maps:merge(?DEFAULT_TRANSPORT_OPTIONS, Options).

set_timeouts(Options, Context) ->
    case woody_context:get_deadline(Context) of
        undefined ->
            Options;
        Deadline ->
            Timeout = woody_deadline:to_unixtime_ms(Deadline) - woody_deadline:unow(),
            ConnectTimeout = SendTimeout = calc_timeouts(Timeout),
            %% It is intentional, that application can override the timeout values
            %% calculated from the deadline (first option value in the list takes
            %% the precedence).
            maps:merge(
                #{
                    connect_timeout => ConnectTimeout,
                    send_timeout => SendTimeout,
                    recv_timeout => Timeout
                },
                Options
            )
    end.

calc_timeouts(Timeout) ->
    %% It is assumed that connect and send timeouts each
    %% should take no more than 20% of the total request time
    %% and in any case no more, than DEFAULT_CONNECT_AND_SEND_TIMEOUT together.
    case max(0, Timeout) div 5 of
        T when (T * 2) > ?DEFAULT_CONNECT_AND_SEND_TIMEOUT ->
            ?DEFAULT_CONNECT_AND_SEND_TIMEOUT;
        T ->
            T
    end.

-spec make_woody_headers(woody_context:ctx()) -> http_headers().
make_woody_headers(Context) ->
    add_optional_headers(Context, [
        {<<"content-type">>, ?CONTENT_TYPE_THRIFT},
        {<<"accept">>, ?CONTENT_TYPE_THRIFT},
        {?HEADER_RPC_ROOT_ID, woody_context:get_rpc_id(trace_id, Context)},
        {?HEADER_RPC_ID, woody_context:get_rpc_id(span_id, Context)},
        {?HEADER_RPC_PARENT_ID, woody_context:get_rpc_id(parent_id, Context)}
    ]).

-spec add_optional_headers(woody_context:ctx(), http_headers()) -> http_headers().
add_optional_headers(Context, Headers) ->
    add_deadline_header(Context, add_metadata_headers(Context, Headers)).

-spec add_metadata_headers(woody_context:ctx(), http_headers()) -> http_headers().
add_metadata_headers(Context, Headers) ->
    maps:fold(fun add_metadata_header/3, Headers, woody_context:get_meta(Context)).

-spec add_metadata_header(woody:http_header_name(), woody:http_header_val(), http_headers()) ->
    http_headers() | no_return().
add_metadata_header(H, V, Headers) when is_binary(H) and is_binary(V) ->
    [{<<?HEADER_META_PREFIX/binary, H/binary>>, V} | Headers].

add_deadline_header(Context, Headers) ->
    do_add_deadline_header(woody_context:get_deadline(Context), Headers).

do_add_deadline_header(undefined, Headers) ->
    Headers;
do_add_deadline_header(Deadline, Headers) ->
    [{?HEADER_DEADLINE, woody_deadline:to_binary(Deadline)} | Headers].

add_host_header(#hackney_url{netloc = Netloc}, Headers) ->
    [{<<"Host">>, Netloc} | Headers].

-spec handle_response(_, woody_state:st()) -> {ok, woody:http_body()} | {error, {system, woody_error:system_error()}}.
handle_response({ok, 200, Headers, Ref}, WoodyState) ->
    Meta =
        case check_error_reason(Headers, 200, WoodyState) of
            <<>> -> #{};
            Reason -> #{reason => Reason}
        end,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, Meta#{status => ok, code => 200}),
    get_body(hackney:body(Ref), WoodyState);
handle_response({ok, Code, Headers, Ref}, WoodyState) ->
    {Class, Details} = check_error_headers(Code, Headers, WoodyState),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, code => Code, reason => Details}),
    %% Free the connection
    case hackney:skip_body(Ref) of
        ok ->
            ok;
        {error, Reason} ->
            _ = log_event(?EV_INTERNAL_ERROR, WoodyState, #{status => error, reason => woody_util:to_binary(Reason)})
    end,
    {error, {system, {external, Class, Details}}};
handle_response({error, {closed, _}}, WoodyState) ->
    Reason = <<"partial response">>,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Reason}),
    {error, {system, {external, result_unknown, Reason}}};
handle_response({error, Reason}, WoodyState) when
    Reason =:= timeout;
    Reason =:= econnaborted;
    Reason =:= enetreset;
    Reason =:= econnreset;
    Reason =:= eshutdown;
    Reason =:= etimedout;
    Reason =:= closed
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => BinReason}),
    {error, {system, {external, result_unknown, BinReason}}};
handle_response({error, Reason}, WoodyState) when
    Reason =:= econnrefused;
    Reason =:= connect_timeout;
    Reason =:= checkout_timeout;
    Reason =:= enetdown;
    Reason =:= enetunreach;
    Reason =:= ehostunreach;
    Reason =:= eacces;
    element(1, Reason) =:= resolve_failed
->
    BinReason = woody_error:format_details(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => BinReason}),
    {error, {system, {internal, resource_unavailable, BinReason}}};
handle_response(Error = {error, {system, _}}, _) ->
    Error;
handle_response({error, Reason}, WoodyState) ->
    Details = woody_error:format_details(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Details}),
    {error, {system, {internal, result_unexpected, Details}}}.

-spec check_error_reason(http_headers(), woody:http_code(), woody_state:st()) -> woody_error:details().
check_error_reason(Headers, Code, WoodyState) ->
    do_check_error_reason(get_header_value(?HEADER_E_REASON, Headers), Code, WoodyState).

-spec do_check_error_reason(header_parse_value(), woody:http_code(), woody_state:st()) -> woody_error:details().
do_check_error_reason(none, 200, _WoodyState) ->
    <<>>;
do_check_error_reason(none, Code, WoodyState) ->
    _ = log_event(?EV_TRACE, WoodyState, #{event => woody_util:to_binary([?HEADER_E_REASON, " header missing"])}),
    woody_util:to_binary(["got response with http code ", Code, " and without ", ?HEADER_E_REASON, " header"]);
do_check_error_reason(Reason, _, _) ->
    Reason.

-spec check_error_headers(woody:http_code(), http_headers(), woody_state:st()) ->
    {woody_error:class(), woody_error:details()}.
check_error_headers(502, Headers, WoodyState) ->
    check_502_error_class(get_error_class_header_value(Headers), Headers, WoodyState);
check_error_headers(Code, Headers, WoodyState) ->
    {get_error_class(Code), check_error_reason(Headers, Code, WoodyState)}.

-spec get_error_class(woody:http_code()) -> woody_error:class().
get_error_class(503) ->
    resource_unavailable;
get_error_class(504) ->
    result_unknown;
get_error_class(_) ->
    result_unexpected.

-spec check_502_error_class(header_parse_value(), http_headers(), woody_state:st()) ->
    {woody_error:class(), woody_error:details()}.
check_502_error_class(none, Headers, WoodyState) ->
    _ = log_event(
        ?EV_TRACE,
        WoodyState,
        #{event => <<?HEADER_E_CLASS/binary, " header missing">>}
    ),
    {result_unexpected, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(<<"result unexpected">>, Headers, WoodyState) ->
    {result_unexpected, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(<<"resource unavailable">>, Headers, WoodyState) ->
    {resource_unavailable, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(<<"result unknown">>, Headers, WoodyState) ->
    {result_unknown, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(Bad, _, WoodyState) ->
    _ = log_internal_error(
        ?ERROR_RESP_HEADER,
        ["unknown ", ?HEADER_E_CLASS, " header value: ", Bad],
        WoodyState
    ),
    {result_unexpected, ?BAD_RESP_HEADER}.

-spec get_error_class_header_value(http_headers()) -> header_parse_value().
get_error_class_header_value(Headers) ->
    case get_header_value(?HEADER_E_CLASS, Headers) of
        None when None =:= none orelse None =:= multiple ->
            None;
        Value ->
            genlib_string:to_lower(Value)
    end.

-spec get_header_value(woody:http_header_name(), http_headers()) -> header_parse_value().
get_header_value(Name, Headers) ->
    case lists:dropwhile(fun({K, _}) -> Name /= genlib_string:to_lower(K) end, Headers) of
        [{_, Value} | _] -> Value;
        [] -> none
    end.

-spec get_body({ok, woody:http_body()} | {error, atom()}, woody_state:st()) ->
    {ok, woody:http_body()} | {error, {system, woody_error:system_error()}}.
get_body(B = {ok, _}, _) ->
    B;
get_body({error, Reason}, WoodyState) ->
    _ = log_internal_error(?ERROR_RESP_BODY, Reason, WoodyState),
    {error, {system, {internal, result_unknown, ?ERROR_RESP_BODY}}}.

log_result({ok, Result}, WoodyState) ->
    log_event(?EV_SERVICE_RESULT, WoodyState, #{status => ok, result => Result});
log_result({error, {business, ThriftExcept}}, WoodyState) ->
    log_event(?EV_SERVICE_RESULT, WoodyState, #{status => ok, class => business, result => ThriftExcept});
log_result({error, Result}, WoodyState) ->
    log_event(?EV_SERVICE_RESULT, WoodyState, #{status => error, class => system, result => Result}).

-spec map_result(woody_client:result() | {error, _ThriftError}) -> woody_client:result().
map_result(Res = {ok, _}) ->
    Res;
map_result(Res = {error, {Type, _}}) when Type =:= business orelse Type =:= system ->
    Res;
map_result({error, ThriftError}) ->
    BinError = woody_error:format_details(ThriftError),
    {error, {system, {internal, result_unexpected, <<"client thrift error: ", BinError/binary>>}}}.

log_internal_error(Error, Reason, WoodyState) ->
    log_event(?EV_INTERNAL_ERROR, WoodyState, #{error => Error, reason => woody_util:to_binary(Reason)}).

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
