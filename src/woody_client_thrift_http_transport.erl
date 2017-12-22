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
    case is_deadline_reached(Context) of
        true ->
            _ = log_internal_error([?EV_CLIENT_SEND, " error"], <<"Deadline reached">>, WoodyState),
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
            ConnectTimeout = SendTimeout = calc_timeouts(Timeout),

            %% It is intentional, that application can override the timeout values
            %% calculated from the deadline (first option value in the list takes
            %% the precedence).
            Options ++ [
                {connect_timeout, ConnectTimeout},
                {send_timeout,    SendTimeout},
                {recv_timeout,    Timeout}
            ]
    end.

-define(DEFAULT_CONNECT_AND_SEND_TIMEOUT, 1000). %% millisec

calc_timeouts(Timeout) ->
    %% It is assumed that connect and send timeouts each
    %% should take no more than 20% of the total request time
    %% and in any case no more, than DEFAULT_CONNECT_AND_SEND_TIMEOUT together.
    case Timeout div 5 of
        T when (T*2) > ?DEFAULT_CONNECT_AND_SEND_TIMEOUT ->
            ?DEFAULT_CONNECT_AND_SEND_TIMEOUT;
        T ->
            T
    end.

is_deadline_reached(Context) ->
    woody_deadline:is_reached(woody_context:get_deadline(Context)).

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
    Meta = case check_error_headers(200, Headers, WoodyState) of
        {business_error, <<>>} -> #{};
        {_, Reason}            -> #{reason => Reason}
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
            _ = log_internal_error("skip http response body error", Reason, WoodyState)
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
    Error = <<"parse http response body error">>,
    _ = log_internal_error(Error, Reason, WoodyState),
    {error, {system, {internal, result_unknown, Error}}}.

-spec check_error_headers(woody:http_code(), woody:http_headers(), woody_state:st()) ->
    {woody_error:class() | business_error, woody_error:details()}.
check_error_headers(Code, Headers, WoodyState) ->
    format_error(Code, get_error_headers(Headers), WoodyState).

get_error_headers(Headers) ->
    {
        case get_header_value(?HEADER_E_CLASS, Headers) of
            C when is_binary(C) -> genlib_string:to_lower(C);
            C -> C
        end,
        get_header_value(?HEADER_E_REASON, Headers)
    }.

format_error(Code, Headers = {Class, _}, WoodyState) ->
    Details = get_error_details(Code, Headers),
    _ = maybe_trace_event(Headers, Details, WoodyState),
    {get_error_class(Code, Class), Details}.

-spec get_error_class(woody:http_code(), header_parse_value()) ->
    woody_error:class() | business_error.
get_error_class(200, _) ->
    business_error;
get_error_class(502, <<"resource unavailable">>) ->
    resource_unavailable;
get_error_class(502, <<"result unknown">>) ->
    result_unknown;
get_error_class(502, _ErrorClass) ->
    result_unexpected;
get_error_class(503, _ErrorClass) ->
    resource_unavailable;
get_error_class(504, _ErrorClass) ->
    result_unknown;
get_error_class(_Code, _ErrorClass) ->
    result_unexpected.

maybe_trace_event({Class, Reason}, Event, WoodyState) when
    Class  =:= none     ;
    Class  =:= multiple ;
    Reason =:= none     ;
    Reason =:= multiple
->
    log_event(?EV_TRACE, WoodyState, #{event => Event});
maybe_trace_event(_Headers, _Event, _WoodyState) ->
    ok.

get_error_details(Code, {Class, Reason}) ->
    woody_util:to_binary(error_details(Code, Class, Reason)).

error_details(200, none, none) ->
    <<>>;
error_details(Code, none, none) ->
    [
        "response code: ", Code, ", no headers: ", ?HEADER_E_CLASS, ", ", ?HEADER_E_REASON
    ];
error_details(Code, none, multiple) ->
    [
        "response code: ", Code, ", no ", ?HEADER_E_CLASS, " header, ",
        "multiple ", ?HEADER_E_REASON, " headers."
    ];
error_details(Code, none, Reason) ->
    [
        "response code: ", Code, ", no ", ?HEADER_E_CLASS, " header, ",
        ?HEADER_E_REASON, ": ", Reason
    ];
error_details(Code, multiple, none) ->
    [
        "response code: ", Code, ", multiple ", ?HEADER_E_CLASS, " headers, ",
        "no ", ?HEADER_E_REASON, " header."
    ];
error_details(Code, multiple, multiple) ->
    [
        "response code: ", Code, ", multiple ", ?HEADER_E_CLASS, " headers, ",
        "multiple ", ?HEADER_E_REASON, " headers."
    ];
error_details(Code, multiple, Reason) ->
    [
        "response code: ", Code, ", multiple ", ?HEADER_E_CLASS, " headers, ",
        ?HEADER_E_REASON, ": ", Reason
    ];
error_details(Code, Class, none) ->
    [
        "response code: ", Code, ", ", ?HEADER_E_CLASS, ": ", Class,
        ", no headers: ", ?HEADER_E_REASON
    ];
error_details(Code, Class, multiple) ->
    [
        "response code: ", Code, ", ", ?HEADER_E_CLASS, ": ", Class,
        ", multiple ", ?HEADER_E_REASON, " headers."
    ];
error_details(Code, Class, Reason) when
    Code =:= 200 ;
    Code =:= 500 ;
    Code =:= 502 ;
    Code =:= 503 ;
    Code =:= 504 ;
    Code >= 400 andalso Code < 500
->
    woody_error_details(Code, Class, Reason);
error_details(Code, Class, Reason) ->
    default_error_details(Code, Class, Reason).

woody_error_details(200, <<"business error">>, Reason) ->
    Reason;
woody_error_details(Code, <<"result unexpected">>, Reason) when
    Code >= 400 andalso Code < 500
->
    Reason;
woody_error_details(500, <<"result unexpected">>, Reason) ->
    Reason;
woody_error_details(502, Class, Reason) when
     Class =:= <<"result unexpected">>    ;
     Class =:= <<"resource unavailable">> ;
     Class =:= <<"result unknown">>
->
    Reason;
woody_error_details(503, <<"resource unavailable">>, Reason) ->
    Reason;
woody_error_details(504, <<"result unknown">>, Reason) ->
    Reason;
woody_error_details(Code, Class, Reason) ->
    default_error_details(Code, Class, Reason).

default_error_details(Code, Class, Reason) ->
    [
        "response code: ", Code, ", ", ?HEADER_E_CLASS, ": ", Class, ", ",
        ?HEADER_E_REASON, ": ", Reason
    ].

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
    [
        {<< ?HEADER_META_PREFIX/binary, H/binary >>, V}
    | Headers];
add_metadata_header(H, V, Headers) ->
    error(badarg, [H, V, Headers]).

add_deadline_header(Context, Headers) ->
    do_add_deadline_header(woody_context:get_deadline(Context), Headers).

do_add_deadline_header(undefined, Headers) ->
    Headers;
do_add_deadline_header(Deadline, Headers) ->
    [
        {?HEADER_DEADLINE, woody_deadline:to_binary(Deadline)}
    | Headers].

log_internal_error(Error, Reason, WoodyState) ->
    log_event(?EV_INTERNAL_ERROR, WoodyState, #{error => Error, reason => woody_util:to_binary(Reason)}).

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
