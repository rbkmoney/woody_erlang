-module(woody_client_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% API
-export([new/2]).

-export([start_client_pool/2]).
-export([stop_client_pool/1]).

%% Thrift transport callbacks
-export([read/2, write/2, flush/1, close/1]).


%% Error types and defs
-define(CODE_400, bad_request).
-define(CODE_403, forbidden).
-define(CODE_408, request_timeout).
-define(CODE_413, body_too_large).
-define(CODE_429, too_many_requests).
-define(CODE_500, server_error).
-define(CODE_503, service_unavailable).

-type error_code() ::
    ?CODE_400 | ?CODE_403 | ?CODE_408 | ?CODE_413 | ?CODE_429 |
    ?CODE_500 | ?CODE_503 | {http_code, pos_integer()}.
-type error_transport(A) ::
    ?ERROR_TRANSPORT(A).
-type hackney_other_error() :: term().
-type error() ::
    error_transport(error_code())     |
    error_transport(partial_response) |
    error_transport(hackney_other_error()).

-export_type([error/0]).

-define(RETURN_ERROR(Error),
    {error, ?ERROR_TRANSPORT(Error)}
).

-type woody_transport() :: #{
    context       => woody_context:ctx(),
    options       => map(),
    write_buffer  => binary(),
    read_buffer   => binary()
}.


%%
%% API
%%
-spec new(woody_context:ctx(), woody_client:options()) ->
    thrift_transport:t_transport() | no_return().
new(Context, TransportOpts = #{url := _Url}) ->
    {ok, Transport} = thrift_transport:new(?MODULE, Context#{
        context       => Context,
        options       => TransportOpts,
        write_buffer  => <<>>,
        read_buffer   => <<>>
    }),
    Transport.

-spec start_client_pool(any(), pos_integer()) -> ok.
start_client_pool(Name, Size) ->
    Options = [{max_connections, Size}],
    hackney_pool:start_pool(Name, Options).

-spec stop_client_pool(any()) -> ok | {error, not_found | simple_one_for_one}.
stop_client_pool(Name) ->
    hackney_pool:stop_pool(Name).

%%
%% Thrift transport callbacks
%%
-spec write(woody_transport(), binary()) -> {woody_transport(), ok}.
write(Transport = #{write_buffer := WBuffer}, Data) when
    is_binary(WBuffer),
    is_binary(Data)
->
    {Transport#{write_buffer => <<WBuffer/binary, Data/binary>>}, ok}.

-spec read(woody_transport(), pos_integer()) -> {woody_transport(), {ok, binary()}}.
read(Transport = #{read_buffer := RBuffer}, Len) when
    is_binary(RBuffer)
->
    Give = min(byte_size(RBuffer), Len),
    <<Data:Give/binary, RBuffer1/binary>> = RBuffer,
    Response = {ok, Data},
    Transport1 = Transport#{read_buffer => RBuffer1},
    {Transport1, Response}.

-spec flush(woody_transport()) -> {woody_transport(), ok | {error, error()}}.
flush(Transport = #{
    context       := Context,
    options       := Options = #{url := Url},
    write_buffer  := WBuffer,
    read_buffer   := RBuffer
}) when
    is_binary(WBuffer),
    is_binary(RBuffer)
->
    Headers = add_metadata_headers(Context, [
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT},
        {?HEADER_NAME_RPC_ROOT_ID   , genlib:to_binary(woody_context:get_child_rpc_id(trace_id,  Transport))},
        {?HEADER_NAME_RPC_ID        , genlib:to_binary(woody_context:get_child_rpc_id(span_id,   Transport))},
        {?HEADER_NAME_RPC_PARENT_ID , genlib:to_binary(woody_context:get_child_rpc_id(parent_id, Transport))}
    ]),
    _ = woody_event_handler:handle_event(
        woody_context:get_ev_handler(Context),
        ?EV_CLIENT_SEND,
        woody_context:get_child_rpc_id(Transport),
        #{url => Url}),
    case send(Url, Headers, WBuffer, maps:without([url], Options), Context) of
        {ok, Response} ->
            {Transport#{
                read_buffer  => <<RBuffer/binary, Response/binary>>,
                write_buffer => <<>>
            }, ok};
        Error ->
            {Transport#{read_buffer => <<>>, write_buffer => <<>>}, Error}
    end.

-spec close(woody_transport()) -> {woody_transport(), ok}.
close(Transport) ->
    {Transport#{}, ok}.


%%
%% Internal functions
%%
send(Url, Headers, WBuffer, Options, Context) ->
    case hackney:request(post, Url, Headers, WBuffer, maps:to_list(Options)) of
        {ok, ResponseCode, _ResponseHeaders, Ref} ->
            _ = log_response(get_response_status(ResponseCode), Context,
                #{code => ResponseCode}),
            handle_response(ResponseCode, hackney:body(Ref));
        {error, {closed, _}} ->
            _ = log_response(error, Context, #{reason => partial_response}),
            ?RETURN_ERROR(partial_response);
        {error, Reason} ->
            _ = log_response(error, Context, #{reason => Reason}),
            ?RETURN_ERROR(Reason)
    end.

get_response_status(200) -> ok;
get_response_status(_)   -> error.

handle_response(200, {ok, Body}) ->
    {ok, Body};
handle_response(400, _) ->
    ?RETURN_ERROR(?CODE_400);
handle_response(403, _) ->
    ?RETURN_ERROR(?CODE_403);
handle_response(408, _) ->
    ?RETURN_ERROR(?CODE_408);
handle_response(413, _) ->
    ?RETURN_ERROR(?CODE_413);
handle_response(429, _) ->
    ?RETURN_ERROR(?CODE_429);
handle_response(500, _) ->
    ?RETURN_ERROR(?CODE_500);
handle_response(503, _) ->
    ?RETURN_ERROR(?CODE_503);
handle_response(Code, _) ->
    ?RETURN_ERROR({http_code, Code}).

add_metadata_headers(Context, Headers) ->
    maps:fold(
        fun add_metadata_header/3,
        Headers,
        woody_context:get_meta(Context)
    ).

add_metadata_header(H, V, Headers) when is_binary(H) and is_binary(V) ->
    [{<< ?HEADER_NAME_PREFIX/binary, H/binary >>, V} | Headers];
add_metadata_header(H, V, Headers) ->
    error(badarg, [H, V, Headers]).

log_response(Status, Context, Meta) ->
    woody_event_handler:handle_event(
        woody_context:get_ev_handler(Context),
        ?EV_CLIENT_RECEIVE,
        woody_context:get_child_rpc_id(Context),
        Meta#{status =>Status}).
