-module(woody_client_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% API
-export([new              /3]).
-export([start_client_pool/2]).
-export([stop_client_pool /1]).
-export([child_spec       /2]).

%% Thrift transport callbacks
-export([read/2, write/2, flush/1, close/1]).


%% Types
-type options() :: list(tuple()).
-export_type([options/0]).

-type woody_transport() :: #{
    url          := woody:url(),
    context      := woody_context:ctx(),
    options      := options(),
    write_buffer := binary(),
    read_buffer  := binary()
}.

-type error()              :: {error, {system, woody_error:system_error()}}.
-type header_parse_value() :: none | multiple | woody:http_header_val().

-define(ERROR_RESP_BODY   , <<"parse http response body error">>   ).
-define(ERROR_RESP_HEADER , <<"parse http response headers error">>).
-define(BAD_RESP_HEADER   , <<"reason unknown due to bad ", ?HEADER_PREFIX/binary, "-error- headers">>).

%%
%% API
%%
-spec new(woody:url(), options(), woody_context:ctx()) ->
    thrift_transport:t_transport() | no_return().
new(Url, Opts, Context) ->
    {ok, Transport} = thrift_transport:new(?MODULE, #{
        url           => Url,
        options       => Opts,
        context       => Context,
        write_buffer  => <<>>,
        read_buffer   => <<>>
    }),
    Transport.

-spec child_spec(any(), options()) ->
    supervisor:child_spec().
child_spec(Name, Options) ->
    hackney_pool:child_spec(Name, Options).

-spec start_client_pool(any(), options()) ->
    ok.
start_client_pool(Name, Options) ->
    hackney_pool:start_pool(Name, Options).

-spec stop_client_pool(any()) ->
    ok | {error, not_found | simple_one_for_one}.
stop_client_pool(Name) ->
    hackney_pool:stop_pool(Name).

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
    context       := Context,
    options       := Options,
    write_buffer  := WBuffer,
    read_buffer   := RBuffer
}) when is_binary(WBuffer), is_binary(RBuffer) ->
    Headers = add_metadata_headers(Context, [
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT},
        {?HEADER_RPC_ROOT_ID   , woody_context:get_rpc_id(trace_id , Context)},
        {?HEADER_RPC_ID        , woody_context:get_rpc_id(span_id  , Context)},
        {?HEADER_RPC_PARENT_ID , woody_context:get_rpc_id(parent_id, Context)}
    ]),
    _ = log_event(?EV_CLIENT_SEND, Context, #{url => Url}),
    case handle_result(hackney:request(post, Url, Headers, WBuffer, Options), Context) of
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
-spec handle_result(_, woody_context:ctx()) ->
    {ok, woody:http_body()} | error().
handle_result({ok, 200, Headers, Ref}, Context) ->
    Meta = case check_error_reason(Headers, 200, Context) of
        <<>>   -> #{};
        Reason -> #{reason => Reason}
    end,
    _ = log_event(?EV_CLIENT_RECEIVE, Context, Meta#{status => ok, code => 200}),
    get_body(hackney:body(Ref), Context);
handle_result({ok, Code, Headers, Ref}, Context) ->
    {Class, Details} = check_error_headers(Code, Headers, Context),
    _ = log_event(?EV_CLIENT_RECEIVE, Context, #{status=>error, code=>Code, reason=>Details}),
    %% Free the connection
    case hackney:skip_body(Ref) of
        ok ->
            ok;
        {error, Reason} ->
            _ = log_event(?EV_INTERNAL_ERROR, Context, #{status => error, reason => woody_util:to_binary(Reason)})
    end,
    {error, {system, {external, Class, Details}}};
handle_result({error, {closed, _}}, Context) ->
    Reason = <<"partial response">>,
    _ = log_event(?EV_CLIENT_RECEIVE, Context, #{status => error, reason => Reason}),
    {error, {system, {external, result_unknown, Reason}}};
handle_result({error, Reason}, Context) when
    Reason =:= timeout      ;
    Reason =:= econnaborted ;
    Reason =:= enetreset    ;
    Reason =:= econnreset
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, Context, #{status => error, reason => BinReason}),
    {error, {system, {external, result_unknown, BinReason}}};
handle_result({error, Reason}, Context) when
    Reason =:= econnrefused    ;
    Reason =:= connect_timeout ;
    Reason =:= nxdomain
->
    BinReason = woody_util:to_binary(Reason),
    _ = log_event(?EV_CLIENT_RECEIVE, Context, #{status => error, reason => BinReason}),
    {error, {system, {external, resource_unavailable, BinReason}}};
handle_result({error, Reason}, Context) ->
    _ = log_event(?EV_CLIENT_RECEIVE, Context, #{status => error, reason => woody_error:format_details(Reason)}),
    {error, {system, {internal, result_unexpected, <<"http request send error">>}}}.

-spec get_body({ok, woody:http_body()} | {error, atom()}, woody_context:ctx()) ->
    {ok, woody:http_body()} | error().
get_body(B = {ok, _}, _) ->
    B;
get_body({error, Reason}, Context) ->
    _ = log_internal_error(?ERROR_RESP_BODY, Reason, Context),
    {error, {system, {internal, result_unknown, ?ERROR_RESP_BODY}}}.

-spec check_error_headers(woody:http_code(), woody:http_headers(), woody_context:ctx()) ->
    {woody_error:class(), woody_error:details()}.
check_error_headers(502, Headers,  Context) ->
    check_502_error_class(get_error_class_header_value(Headers), Headers, Context);
check_error_headers(Code, Headers, Context) ->
    {get_error_class(Code), check_error_reason(Headers, Code, Context)}.

-spec get_error_class(woody:http_code()) ->
    woody_error:class().
get_error_class(503) ->
    resource_unavailable;
get_error_class(504) ->
    result_unknown;
get_error_class(_) ->
    result_unexpected.

-spec check_502_error_class(header_parse_value(), woody:http_headers(), woody_context:ctx()) ->
    {woody_error:class(), woody_error:details()}.
check_502_error_class(none, Headers, Context) ->
    _ = log_event(?EV_TRACE, Context, #{role => client,
            event => woody_util:to_binary([?HEADER_E_CLASS, " header missing"])}),
    {result_unexpected, check_error_reason(Headers, 502, Context)};
check_502_error_class(multiple, _, Context) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["multiple headers: ", ?HEADER_E_CLASS], Context),
    {result_unexpected, ?BAD_RESP_HEADER};
check_502_error_class(<<"result unexpected">>, Headers, Context) ->
    {result_unexpected, check_error_reason(Headers, 502, Context)};
check_502_error_class(<<"resource unavailable">>, Headers, Context) ->
    {resource_unavailable, check_error_reason(Headers, 502, Context)};
check_502_error_class(<<"result unknown">>, Headers, Context) ->
    {result_unknown, check_error_reason(Headers, 502, Context)};
check_502_error_class(Bad, _, Context) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["unknown ", ?HEADER_E_CLASS, " header value: ", Bad], Context),
    {result_unexpected, ?BAD_RESP_HEADER}.

-spec check_error_reason(woody:http_headers(), woody:http_code(), woody_context:ctx()) ->
    woody_error:details().
check_error_reason(Headers, Code, Context) ->
    do_check_error_reason(get_header_value(?HEADER_E_REASON, Headers), Code, Context).

-spec do_check_error_reason(header_parse_value(), woody:http_code(), woody_context:ctx()) ->
    woody_error:details().
do_check_error_reason(none, 200, _Context) ->
    <<>>;
do_check_error_reason(none, Code, Context) ->
    _ = log_event(?EV_TRACE, Context, #{role => client,
            event => woody_util:to_binary([?HEADER_E_REASON, " header missing"])}),
    woody_util:to_binary(["http code: ", Code]);
do_check_error_reason(multiple, _, Context) ->
    _ = log_internal_error(?ERROR_RESP_HEADER, ["multiple headers: ", ?HEADER_E_REASON], Context),
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

log_internal_error(Error, Reason, Context) ->
    log_event(?EV_INTERNAL_ERROR, Context, #{error => Error, reason => woody_util:to_binary(Reason), role => client}).

log_event(Event, Context, Meta) ->
    woody_event_handler:handle_event(Event, Meta, Context).
