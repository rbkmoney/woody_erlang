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

-type error()               :: {error, {system, woody_error:system_error()}}.
-type header_parse_value()  :: none | multiple | woody:http_header_val().
-type e_headers_parse_res() :: {woody:header_type(), {header_parse_value(), header_parse_value()}}.

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

-spec close(woody_transport()) ->
    {woody_transport(), ok}.
close(Transport) ->
    {Transport#{}, ok}.

%%
%% Internal functions
%%

%% Request

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

-spec make_woody_headers(woody_context:ctx()) ->
    woody:http_headers().

-ifdef(TEST).
-type client_type() :: new | old | default.

make_woody_headers(Context) ->
    ClientType = genlib_app:env(woody, client_type, default),
    RpcIdHeaders = case ClientType of
        new ->
            [add_rpc_id_header(H, Context) || H <- [
                {trace_id  , ?HEADER_RPC_ROOT_ID},
                {span_id   , ?HEADER_RPC_ID},
                {parent_id , ?HEADER_RPC_PARENT_ID}
            ]];
        old ->
            [add_rpc_id_header(H, Context) || H <- [
                {trace_id  , ?HEADER_RPC_ROOT_ID_OLD},
                {span_id   , ?HEADER_RPC_ID_OLD},
                {parent_id , ?HEADER_RPC_PARENT_ID_OLD}
            ]];
        default ->
            [add_rpc_id_header(H, Context) || H <- [
                {trace_id  , ?HEADER_RPC_ROOT_ID},
                {span_id   , ?HEADER_RPC_ID},
                {parent_id , ?HEADER_RPC_PARENT_ID},
                {trace_id  , ?HEADER_RPC_ROOT_ID_OLD},
                {span_id   , ?HEADER_RPC_ID_OLD},
                {parent_id , ?HEADER_RPC_PARENT_ID_OLD}
            ]]
    end,
    add_optional_headers(ClientType, Context, [
        {<<"content-type">> , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>       , ?CONTENT_TYPE_THRIFT}
    ] ++ RpcIdHeaders).

-spec add_optional_headers(client_type(), woody_context:ctx(), woody:http_headers()) ->
    woody:http_headers().
add_optional_headers(ClientType, Context, Headers) ->
    add_deadline_header(ClientType, Context, add_metadata_headers(ClientType, Context, Headers)).

-spec add_metadata_headers(client_type(), woody_context:ctx(), woody:http_headers()) ->
    woody:http_headers().
add_metadata_headers(ClientType, Context, Headers) ->
    maps:fold(
        fun(H, V, Acc) -> add_metadata_header(ClientType, H, V, Acc) end,
        Headers, woody_context:get_meta(Context)
    ).

-spec add_metadata_header(client_type(), woody:http_header_name(), woody:http_header_val(), woody:http_headers()) ->
    woody:http_headers() | no_return().
add_metadata_header(new, H, V, Headers) when is_binary(H) and is_binary(V) ->
    [{<< ?HEADER_META_PREFIX/binary, H/binary >>, V} | Headers];
add_metadata_header(old, H, V, Headers) when is_binary(H) and is_binary(V) ->
    [{<< ?HEADER_META_PREFIX_OLD/binary, H/binary >>, V} | Headers];
add_metadata_header(default, H, V, Headers) when is_binary(H) and is_binary(V) ->
    add_metadata_header(new, H, V, Headers) ++ add_metadata_header(old, H, V, Headers);
add_metadata_header(_, H, V, Headers) ->
    error(badarg, [H, V, Headers]).

add_deadline_header(ClientType, Context, Headers) ->
    do_add_deadline_header(ClientType, woody_context:get_deadline(Context), Headers).

do_add_deadline_header(_, undefined, Headers) ->
    Headers;
do_add_deadline_header(new, Deadline, Headers) ->
    [{?HEADER_DEADLINE, woody_deadline:to_binary(Deadline)} | Headers];
do_add_deadline_header(old, Deadline, Headers) ->
    [{?HEADER_DEADLINE_OLD, woody_deadline:to_binary(Deadline)} | Headers];
do_add_deadline_header(default, Deadline, Headers) ->
    do_add_deadline_header(new, Deadline, Headers) ++ do_add_deadline_header(old, Deadline, Headers).

-else.
make_woody_headers(Context) ->
    add_optional_headers(Context, [
        {<<"content-type">> , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>       , ?CONTENT_TYPE_THRIFT}
    ] ++ [add_rpc_id_header(H, Context) || H <- [
        {trace_id  , ?HEADER_RPC_ROOT_ID},
        {span_id   , ?HEADER_RPC_ID},
        {parent_id , ?HEADER_RPC_PARENT_ID},

        {trace_id  , ?HEADER_RPC_ROOT_ID_OLD},
        {span_id   , ?HEADER_RPC_ID_OLD},
        {parent_id , ?HEADER_RPC_PARENT_ID_OLD}
    ]]).

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
        {<< ?HEADER_META_PREFIX/binary, H/binary >>, V},
        {<< ?HEADER_META_PREFIX_OLD/binary, H/binary >>, V}
    | Headers];
add_metadata_header(H, V, Headers) ->
    error(badarg, [H, V, Headers]).

add_deadline_header(Context, Headers) ->
    do_add_deadline_header(woody_context:get_deadline(Context), Headers).

do_add_deadline_header(undefined, Headers) ->
    Headers;
do_add_deadline_header(Deadline, Headers) ->
    [
        {?HEADER_DEADLINE, woody_deadline:to_binary(Deadline)},
        {?HEADER_DEADLINE_OLD, woody_deadline:to_binary(Deadline)}
    | Headers].

-endif. %% TEST

add_rpc_id_header({Id, HeaderName}, Context) ->
    {HeaderName, woody_context:get_rpc_id(Id, Context)}.

%% Response

-spec handle_result(_, woody_state:st()) ->
    {ok, woody:http_body()} | error().
handle_result(Result, WoodyState) ->
    Result1 = case genlib_app:env(woody, trace_http_client) of
        true ->
            trace_http_reponse(Result, WoodyState);
        _ ->
            Result
    end,
    do_handle_result(Result1, WoodyState).

trace_http_reponse({ok, Code, Headers, Ref}, WoodyState) ->
    {Body, Meta} = case hackney:body(Ref) of
        E = {error, Error} ->
            {E, #{
                body_status => Error
            }};
        {ok, B} ->
            {{ok, B}, #{
                body => B,
                body_status => ok
            }}
    end,
    log_event(?EV_TRACE, WoodyState, Meta#{
        event   =>  <<"http response received">>,
        code    => Code,
        headers => Headers
    }),
    {ok, Code, Headers, Body};
trace_http_reponse(ErrorResult, _WoodyState) ->
    ErrorResult.

do_handle_result({ok, 200, Headers, Body}, WoodyState) ->
    Meta = case check_error_headers(200, Headers) of
        {no_error, <<>>} ->
            #{};
        {business_error, Details} ->
            #{reason => Details};
        {_, Details} ->
            _ = log_event(?EV_TRACE, WoodyState, #{event => Details, code => 200}),
            #{}
    end,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, Meta#{status => ok, code => 200}),
    handle_body(get, Body, WoodyState);
do_handle_result({ok, Code, Headers, Body}, WoodyState) ->
    {Class, Details} = check_error_headers(Code, Headers),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status=>error, code=>Code, reason=>Details}),
    %% Free the connection
    _ = handle_body(skip, Body, WoodyState),
    {error, {system, {external, Class, Details}}};
do_handle_result({error, {closed, _}}, WoodyState) ->
    Reason = <<"partial response">>,
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Reason}),
    {error, {system, {external, result_unknown, Reason}}};
do_handle_result({error, Reason}, WoodyState) when
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
do_handle_result({error, Reason}, WoodyState) when
    Reason =:= econnrefused    ;
    Reason =:= connect_timeout ;
    Reason =:= nxdomain        ;
    Reason =:= enetdown        ;
    Reason =:= enetunreach
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => BinReason}),
    {error, {system, {internal, resource_unavailable, BinReason}}};
do_handle_result(Error = {error, {system, _}}, _) ->
    Error;
do_handle_result({error, Reason}, WoodyState) ->
    Details = woody_error:format_details(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, WoodyState, #{status => error, reason => Details}),
    {error, {system, {internal, result_unexpected, Details}}}.

%% -spec get_body({ok, woody:http_body()} | {error, atom()}, woody_state:st()) ->
%%     {ok, woody:http_body()} | error().
handle_body(_, Ok = {ok, _}, _) ->
    Ok;
handle_body(_, {error, Reason}, WoodyState) ->
    Error = <<"parse http response body error">>,
    _ = log_internal_error(Error, Reason, WoodyState),
    {error, {system, {internal, result_unknown, Error}}};
handle_body(get, Ref, WoodyState) ->
    handle_body(get, hackney:body(Ref), WoodyState);
handle_body(skip, Ref, WoodyState) ->
  case hackney:skip_body(Ref) of
      ok ->
          ok;
      {error, Reason} ->
          _ = log_internal_error("skip http response body error", Reason, WoodyState),
          ok
  end.

-spec check_error_headers(woody:http_code(), woody:http_headers()) ->
    {woody_error:class() | business_error | no_error, woody_error:details()}.
check_error_headers(Code, Headers) ->
    format_error(Code, get_error_headers(Headers)).

-spec get_error_headers(woody:http_headers()) ->
    e_headers_parse_res().
get_error_headers(Headers) ->
    fallback_to_old_headers(get_error_headers(Headers, {?HEADER_E_CLASS, ?HEADER_E_REASON}), Headers).

get_error_headers(Headers, {HeaderClass, HeaderReason}) ->
    {
        case get_header_value(HeaderClass, Headers) of
            C when is_binary(C) -> genlib_string:to_lower(C);
            C -> C
        end,
        get_header_value(HeaderReason, Headers)
    }.
-spec fallback_to_old_headers({header_parse_value(), header_parse_value()}, woody:http_headers()) ->
    e_headers_parse_res().
fallback_to_old_headers({none, none}, Headers) ->
    {old, get_error_headers(Headers, {?HEADER_E_CLASS_OLD, ?HEADER_E_REASON_OLD})};
fallback_to_old_headers(Result, _) ->
    {new, Result}.

-spec format_error(woody:http_code(), e_headers_parse_res()) ->
    {woody_error:class() | business_error | no_error, woody_error:details()}.
format_error(Code, HeaderParseRes = {_, {Class, _}}) ->
    {get_error_class(Code, Class), get_error_details(HeaderParseRes, Code)}.

-spec get_error_class(woody:http_code(), header_parse_value()) ->
    woody_error:class() | no_error | business_error.
get_error_class(200, <<>>) ->
    no_error;
get_error_class(200, <<"business error">>) ->
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

-spec get_error_details(e_headers_parse_res(), woody:http_code()) ->
    woody_error:details().
get_error_details({new, HeaderValues}, Code) ->
    do_get_error_details(Code, HeaderValues, {?HEADER_E_CLASS, ?HEADER_E_REASON});
get_error_details({old, HeaderValues}, Code) ->
    do_get_error_details(Code, HeaderValues, {?HEADER_E_CLASS_OLD, ?HEADER_E_REASON_OLD}).

do_get_error_details(Code, HeaderValues, HeaderNames) ->
    woody_util:to_binary(error_details(Code, HeaderValues, HeaderNames)).

error_details(200, {none, none}, _) ->
    <<>>;
error_details(Code, {none, none}, _) ->
    [
        "response code: ", Code, ", no headers: " |
        lists:join(", ", [?HEADER_E_CLASS, ?HEADER_E_REASON, ?HEADER_E_CLASS_OLD, ?HEADER_E_REASON_OLD])
    ];
error_details(Code, {none, multiple}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", no ", HeaderClass, " header, ",
        "multiple ", HeaderReason, " headers."
    ];
error_details(Code, {none, Reason}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", no ", HeaderClass, " header, ",
        HeaderReason, ": ", Reason
    ];
error_details(Code, {multiple, none}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", multiple ", HeaderClass, " headers, ",
        "no ", HeaderReason, " header."
    ];
error_details(Code, {multiple, multiple}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", multiple ", HeaderClass, " headers, ",
        "multiple ", HeaderReason, " headers."
    ];
error_details(Code, {multiple, Reason}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", multiple ", HeaderClass, " headers, ",
        HeaderReason, ": ", Reason
    ];
error_details(Code, {Class, none}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", ", HeaderClass, ": ", Class,
        ", no headers: ", HeaderReason
    ];
error_details(Code, {Class, multiple}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", ", HeaderClass, ": ", Class,
        ", multiple ", HeaderReason, " headers."
    ];
error_details(Code, HeaderValues, HeaderNames) when
    Code =:= 200 ;
    Code =:= 500 ;
    Code =:= 502 ;
    Code =:= 503 ;
    Code =:= 504 ;
    Code >= 400 andalso Code < 500
->
    woody_error_details(Code, HeaderValues, HeaderNames);
error_details(Code, HeaderValues, HeaderNames) ->
    default_error_details(Code, HeaderValues, HeaderNames).

woody_error_details(200, {<<"business error">>, Reason}, _) ->
    Reason;
woody_error_details(Code, {<<"result unexpected">>, Reason}, _) when
    Code >= 400 andalso Code < 500
->
    Reason;
woody_error_details(500, {<<"result unexpected">>, Reason}, _) ->
    Reason;
woody_error_details(502, {Class, Reason}, _) when
     Class =:= <<"result unexpected">>    ;
     Class =:= <<"resource unavailable">> ;
     Class =:= <<"result unknown">>
->
    Reason;
woody_error_details(503, {<<"resource unavailable">>, Reason}, _) ->
    Reason;
woody_error_details(504, {<<"result unknown">>, Reason}, _) ->
    Reason;
woody_error_details(Code, HeaderValues, HeaderNames) ->
    default_error_details(Code, HeaderValues, HeaderNames).

default_error_details(Code, {Class, Reason}, {HeaderClass, HeaderReason}) ->
    [
        "response code: ", Code, ", ", HeaderClass, ": ", Class, ", ",
        HeaderReason, ": ", Reason
    ].

-spec get_header_value(woody:http_header_name(), woody:http_headers()) ->
    header_parse_value().
get_header_value(Name, Headers) ->
    case [V || {K, V} <- Headers, Name =:= genlib_string:to_lower(K)] of
        [Value] -> Value;
        []      -> none;
        _       -> multiple
    end.

log_internal_error(Error, Reason, WoodyState) ->
    log_event(?EV_INTERNAL_ERROR, WoodyState, #{error => Error, reason => woody_util:to_binary(Reason)}).

log_event(Event, WoodyState, ExtraMeta) ->
    woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
