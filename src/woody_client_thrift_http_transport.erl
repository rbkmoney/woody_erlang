-module(woody_client_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% API
-export([new       /3]).
-export([child_spec/1]).

%% Thrift transport callbacks
-export([read/2, write/2, flush/1, close/1]).


%% Types
-type options() :: list(tuple()).
-export_type([options/0]).

-type woody_transport() :: #{
    url          := woody:url(),
    woody_state  := woody_state:st(),
    options      := options(),
    write_buffer := binary(),
    read_buffer  := binary()
}.

-type error()              :: {error, {system, woody_error:system_error()}}.
-type header_parse_value() :: none | multiple | woody:http_header_val().

-define(DEFAULT_SEND_TIMEOUT, 1000). %% millisec

-define(ERROR_RESP_BODY   , <<"parse http response body error">>   ).
-define(ERROR_RESP_HEADER , <<"parse http response headers error">>).
-define(BAD_RESP_HEADER   , <<"reason unknown due to bad ", ?HEADER_PREFIX/binary, "-error- headers">>).

%%
%% API
%%
-spec new(woody:url(), options(), woody_state:st()) ->
    thrift_transport:t_transport() | no_return().
new(Url, Opts, WoodyState) ->
    {ok, Transport} = thrift_transport:new(?MODULE, #{
        url           => Url,
        options       => Opts,
        woody_state   => WoodyState,
        write_buffer  => <<>>,
        read_buffer   => <<>>
    }),
    Transport.

-spec child_spec(options()) ->
    supervisor:child_spec().
child_spec(Options) ->
    Name = proplists:get_value(pool, Options),
    hackney_pool:child_spec(Name, Options).

%%
%% Thrift transport callbacks
%%
-spec write(woody_transport(), binary()) ->
    {woody_transport(), ok}.
write(Transport = #{write_buffer := WBuffer}, Data) when
    is_binary(WBuffer), is_binary(Data)
->
    {Transport#{write_buffer => <<WBuffer/binary, Data/binary>>}, ok}.

-spec read(woody_transport(), pos_integer()) ->
    {woody_transport(), {ok, binary()}}.
read(Transport = #{read_buffer := RBuffer}, Len) when is_binary(RBuffer) ->
    Give = min(byte_size(RBuffer), Len),
    <<Data:Give/binary, RBuffer1/binary>> = RBuffer,
    Response = {ok, Data},
    Transport1 = Transport#{read_buffer => RBuffer1},
    {Transport1, Response}.

-spec flush(woody_transport()) ->
    {woody_transport(), ok | error()}.
flush(Transport = #{
    url           := Url,
    woody_state   := WoodyState,
    options       := Options,
    write_buffer  := WBuffer,
    read_buffer   := RBuffer
}) when is_binary(WBuffer), is_binary(RBuffer) ->
    case handle_result(
        send(Url, WBuffer, Options, WoodyState),
        WoodyState
    ) of
        {ok, Response} ->
            {Transport#{
                read_buffer  => Response,
                write_buffer => <<>>
            }, ok};
        Error ->
            {Transport#{read_buffer => <<>>, write_buffer => <<>>}, Error}
    end.

send(Url, Body, Options, WoodyState) ->
    Context = woody_state:get_context(WoodyState),
    case deadline_reached(Context) of
        true ->
            _ = log_event(?EV_INTERNAL_ERROR, WoodyState, #{status => error, reason => <<"Deadline reached">>}),
            {error, {system, {internal, resource_unavailable, <<"deadline reached">>}}};
        false ->
            Headers = make_woody_headers(Context),
            _ = log_event(?EV_CLIENT_SEND, WoodyState, #{url => Url}),
            hackney:request(post, Url, Headers, Body, set_timeouts(Options, Context))
    end.

set_timeouts(Options, Context) ->
    case woody_context:get_deadline(Context) of
        undefined ->
            Options;
        Deadline ->
            Timeout = woody_deadline:to_timeout(Deadline),
            SendTimeout = calc_send_timeout(Timeout),

            %% It is intentional, that application can override the timeout values
            %% calculated from the deadline (first option value in the list takes
            %% the precedence).
            Options ++ [
                {connect_timeout, SendTimeout},
                {send_timeout,    SendTimeout},
                {recv_timeout,    Timeout}
            ]
    end.

calc_send_timeout(Timeout) ->
    case Timeout div 5 of
        T when (T*2) > ?DEFAULT_SEND_TIMEOUT ->
            ?DEFAULT_SEND_TIMEOUT;
        T ->
            T
    end.

deadline_reached(Context) ->
    woody_deadline:reached(woody_context:get_deadline(Context)).

-spec close(woody_transport()) ->
    {woody_transport(), ok}.
close(Transport) ->
    {Transport#{}, ok}.

%%
%% Internal functions
%%
-spec handle_result(_, woody_state:st()) ->
    {ok, woody:http_body()} | error().
handle_result({ok, 200, Headers, Ref}, WoodyState) ->
    Meta = case check_error_reason(Headers, 200, WoodyState) of
        <<>>   -> #{};
        Reason -> #{reason => Reason}
    end,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, Meta#{status => ok, code => 200}),
    get_body(hackney:body(Ref), WoodyState);
handle_result({ok, Code, Headers, Ref}, WoodyState) ->
    {Class, Details} = check_error_headers(Code, Headers, WoodyState),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status=>error, code=>Code, reason=>Details}),
    %% Free the connection
    case hackney:skip_body(Ref) of
        ok ->
            ok;
        {error, Reason} ->
            _ = log_event(?EV_INTERNAL_ERROR, WoodyState, #{status => error, reason => woody_util:to_binary(Reason)})
    end,
    {error, {system, {external, Class, Details}}};
handle_result({error, {closed, _}}, WoodyState) ->
    Reason = <<"partial response">>,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Reason}),
    {error, {system, {external, result_unknown, Reason}}};
handle_result({error, Reason}, WoodyState) when
    Reason =:= timeout      ;
    Reason =:= econnaborted ;
    Reason =:= enetreset    ;
    Reason =:= econnreset   ;
    Reason =:= eshutdown    ;
    Reason =:= etimedout    ;
    Reason =:= closed
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => BinReason}),
    {error, {system, {external, result_unknown, BinReason}}};
handle_result({error, Reason}, WoodyState) when
    Reason =:= econnrefused    ;
    Reason =:= connect_timeout ;
    Reason =:= nxdomain        ;
    Reason =:= enetdown        ;
    Reason =:= enetunreach
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => BinReason}),
    {error, {system, {internal, resource_unavailable, BinReason}}};
handle_result(Error = {error, {system, _}}, _) ->
    Error;
handle_result({error, Reason}, WoodyState) ->
    Details = woody_error:format_details(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Details}),
    {error, {system, {internal, result_unexpected, Details}}}.

-spec get_body({ok, woody:http_body()} | {error, atom()}, woody_state:st()) ->
    {ok, woody:http_body()} | error().
get_body(B = {ok, _}, _) ->
    B;
get_body({error, Reason}, WoodyState) ->
    _ = log_internal_error(?ERROR_RESP_BODY, Reason, WoodyState),
    {error, {system, {internal, result_unknown, ?ERROR_RESP_BODY}}}.

-spec check_error_headers(woody:http_code(), woody:http_headers(), woody_state:st()) ->
    {woody_error:class(), woody_error:details()}.
check_error_headers(502, Headers,  WoodyState) ->
    check_502_error_class(get_error_class_header_value(Headers), Headers, WoodyState);
check_error_headers(Code, Headers, WoodyState) ->
    {get_error_class(Code), check_error_reason(Headers, Code, WoodyState)}.

-spec get_error_class(woody:http_code()) ->
    woody_error:class().
get_error_class(503) ->
    resource_unavailable;
get_error_class(504) ->
    result_unknown;
get_error_class(_) ->
    result_unexpected.

-spec check_502_error_class(header_parse_value(), woody:http_headers(), woody_state:st()) ->
    {woody_error:class(), woody_error:details()}.
check_502_error_class(none, Headers, WoodyState) ->
    _ = log_event(?EV_TRACE, WoodyState, #{event => woody_util:to_binary([?HEADER_E_CLASS, " header missing"])}),
    {result_unexpected, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(multiple, _, WoodyState) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["multiple headers: ", ?HEADER_E_CLASS], WoodyState),
    {result_unexpected, ?BAD_RESP_HEADER};
check_502_error_class(<<"result unexpected">>, Headers, WoodyState) ->
    {result_unexpected, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(<<"resource unavailable">>, Headers, WoodyState) ->
    {resource_unavailable, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(<<"result unknown">>, Headers, WoodyState) ->
    {result_unknown, check_error_reason(Headers, 502, WoodyState)};
check_502_error_class(Bad, _, WoodyState) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["unknown ", ?HEADER_E_CLASS, " header value: ", Bad], WoodyState),
    {result_unexpected, ?BAD_RESP_HEADER}.

-spec check_error_reason(woody:http_headers(), woody:http_code(), woody_state:st()) ->
    woody_error:details().
check_error_reason(Headers, Code, WoodyState) ->
    do_check_error_reason(get_header_value(?HEADER_E_REASON, Headers), Code, WoodyState).

-spec do_check_error_reason(header_parse_value(), woody:http_code(), woody_state:st()) ->
    woody_error:details().
do_check_error_reason(none, 200, _WoodyState) ->
    <<>>;
do_check_error_reason(none, Code, WoodyState) ->
    _ = log_event(?EV_TRACE, WoodyState, #{event => woody_util:to_binary([?HEADER_E_REASON, " header missing"])}),
    woody_util:to_binary(["got response with http code ", Code, " and without ", ?HEADER_E_REASON, " header"]);
do_check_error_reason(multiple, _, WoodyState) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["multiple headers: ", ?HEADER_E_REASON], WoodyState),
    ?BAD_RESP_HEADER;
do_check_error_reason(Reason, _, _) ->
    Reason.

-spec get_error_class_header_value(woody:http_headers()) ->
    header_parse_value().
get_error_class_header_value(Headers) ->
    case get_header_value(?HEADER_E_CLASS, Headers) of
        None when None =:= none orelse None =:= multiple ->
            None;
        Value ->
            genlib_string:to_lower(Value)
    end.

-spec get_header_value(woody:http_header_name(), woody:http_headers()) ->
    header_parse_value().
get_header_value(Name, Headers) ->
    case [V || {K, V} <- Headers, Name =:= genlib_string:to_lower(K)] of
        [Value] -> Value;
        []      -> none;
        _       -> multiple
    end.

-spec make_woody_headers(woody_context:ctx()) ->
    woody:http_headers().
make_woody_headers(Context) ->
    add_optional_headers(Context, [
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT},
        {?HEADER_RPC_ROOT_ID   , woody_context:get_rpc_id(trace_id , Context)},
        {?HEADER_RPC_ID        , woody_context:get_rpc_id(span_id  , Context)},
        {?HEADER_RPC_PARENT_ID , woody_context:get_rpc_id(parent_id, Context)}
    ]).

-spec add_optional_headers(woody_context:ctx(), woody:http_headers()) ->
    woody:http_headers().
add_optional_headers(Context, Headers) ->
    add_deadline_header(Context, add_metadata_headers(Context, Headers)).

-spec add_metadata_headers(woody_context:ctx(), woody:http_headers()) ->
    woody:http_headers().
add_metadata_headers(Context, Headers) ->
    maps:fold(fun add_metadata_header/3, Headers, woody_context:get_meta(Context)).

-spec add_metadata_header(woody:http_header_name(), woody:http_header_val(), woody:http_headers()) ->
    woody:http_headers() | no_return().
add_metadata_header(H, V, Headers) when is_binary(H) and is_binary(V) ->
    [{<< ?HEADER_META_PREFIX/binary, H/binary >>, V} | Headers];
add_metadata_header(H, V, Headers) ->
    error(badarg, [H, V, Headers]).

add_deadline_header(Context, Headers) ->
    do_add_deadline_header(woody_context:get_deadline(Context), Headers).

do_add_deadline_header(undefined, Headers) ->
    Headers;
do_add_deadline_header(Deadline, Headers) ->
    [{?HEADER_DEADLINE, woody_deadline:to_binary(Deadline)} | Headers].

log_internal_error(Error, Reason, WoodyState) ->
    log_event(?EV_INTERNAL_ERROR, WoodyState, #{error => Error, reason => woody_util:to_binary(Reason)}).

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
