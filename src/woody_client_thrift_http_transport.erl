-module(woody_client_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("woody_defs.hrl").

%% API
-export([new/3]).

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

-define(LOG_RESPONSE(EventHandler, Status, RpcId, Meta),
    woody_event_handler:handle_event(EventHandler, ?EV_CLIENT_RECEIVE,
        RpcId, Meta#{status =>Status})
).

-type woody_transport() :: #{
    span_id       => woody_t:req_id(),
    trace_id      => woody_t:req_id(),
    parent_id     => woody_t:req_id(),
    url           => woody_t:url(),
    options       => map(),
    event_handler => woody_t:handler(),
    write_buffer  => binary(),
    read_buffer   => binary()
}.


%%
%% API
%%
-spec new(woody_t:rpc_id(), woody_client:options(), woody_t:handler()) ->
    thrift_transport:t_transport() | no_return().
new(RpcId, TransportOpts = #{url := Url}, EventHandler) ->
    TransportOpts1 = maps:remove(url, TransportOpts),
    _ = validate_options(TransportOpts1),
    {ok, Transport} = thrift_transport:new(?MODULE, RpcId#{
        url           => Url,
        options       => TransportOpts1,
        event_handler => EventHandler,
        write_buffer  => <<>>,
        read_buffer   => <<>>
    }),
    Transport.

validate_options(_Opts) ->
    # Shit gates are open
    ok.

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
    url           := Url,
    span_id       := SpanId,
    trace_id      := TraceId,
    parent_id     := ParentId,
    options       := Options,
    event_handler := EventHandler,
    write_buffer  := WBuffer,
    read_buffer   := RBuffer
}) when
    is_binary(WBuffer),
    is_binary(RBuffer)
->
    Headers = [
        {<<"content-type">>         , ?CONTENT_TYPE_THRIFT},
        {<<"accept">>               , ?CONTENT_TYPE_THRIFT},
        {?HEADER_NAME_RPC_ROOT_ID   , genlib:to_binary(TraceId)},
        {?HEADER_NAME_RPC_ID        , genlib:to_binary(SpanId)},
        {?HEADER_NAME_RPC_PARENT_ID , genlib:to_binary(ParentId)}
    ],
    RpcId = maps:with([span_id, trace_id, parent_id], Transport),
    woody_event_handler:handle_event(EventHandler, ?EV_CLIENT_SEND,
        RpcId, #{url => Url}),
    case send(Url, Headers, WBuffer, Options, RpcId, EventHandler) of
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
send(Url, Headers, WBuffer, Options, RpcId, EventHandler) ->
    case hackney:request(post, Url, Headers, WBuffer, maps:to_list(Options)) of
        {ok, ResponseCode, _ResponseHeaders, Ref} ->
            ?LOG_RESPONSE(EventHandler, get_response_status(ResponseCode),
                RpcId, #{code => ResponseCode}),
            handle_response(ResponseCode, hackney:body(Ref));
        {error, {closed, _}} ->
            ?LOG_RESPONSE(EventHandler, error,
                RpcId, #{reason => partial_response}),
            ?RETURN_ERROR(partial_response);
        {error, Reason} ->
            ?LOG_RESPONSE(EventHandler, error,
                RpcId, #{reason => Reason}),
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
