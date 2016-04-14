-module(rpc_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("rpc_thrift_http_headers.hrl").

%% API
-export([new/2]).

-export([start_client_pool/2]).
-export([stop_client_pool/1]).

%% Thrift transport callbacks
-export([read/2, write/2, flush/1, close/1]).

-type url() :: binary().
-export_type([url/0]).

-type rpc_transport() :: #{
    req_id => rpc_t:req_id(),
    root_req_id => rpc_t:req_id(),
    parent_req_id => rpc_t:req_id(),
    url => url(),
    options => map(),
    write_buffer => binary(),
    read_buffer => binary()
}.


%%
%% API
%%
-spec new(rpc_t:rpc_id(), rpc_client:options()) ->
    thrift_transport:t_transport().
new(RpcId, TransportOpts = #{url := Url}) ->
    {ok, Transport} = thrift_transport:new(?MODULE, RpcId#{
        url => Url,
        options => TransportOpts,
        write_buffer => <<>>,
        read_buffer => <<>>
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
-spec write(rpc_transport(), binary()) -> {rpc_transport(), ok}.
write(Transport = #{write_buffer := WBuffer}, Data) when
    is_binary(WBuffer),
    is_binary(Data)
->
    {Transport#{write_buffer => <<WBuffer/binary, Data/binary>>}, ok}.

-spec read(rpc_transport(), pos_integer()) -> {rpc_transport(), {ok, binary()}}.
read(Transport = #{read_buffer := RBuffer}, Len) when
    is_binary(RBuffer)
->
    Give = min(byte_size(RBuffer), Len),
    <<Data:Give/binary, RBuffer1/binary>> = RBuffer,
    Response = {ok, Data},
    Transport1 = Transport#{read_buffer => RBuffer1},
    {Transport1, Response}.

-spec flush(rpc_transport()) -> {rpc_transport(), ok | {error, _Reason}}.
flush(Transport = #{
    url := Url,
    req_id := ReqId,
    root_req_id := RootReqId,
    parent_req_id := PaReqId,
    options := Options,
    write_buffer := WBuffer,
    read_buffer := RBuffer
}) when
    is_binary(WBuffer),
    is_binary(RBuffer)
->
    Headers = [
        {<<"content-type">>, ?CONTENT_TYPE_THRIFT},
        {<<"accept">>, ?CONTENT_TYPE_THRIFT},
        {?HEADER_NAME_RPC_ROOT_ID, genlib:to_binary(RootReqId)},
        {?HEADER_NAME_RPC_ID, genlib:to_binary(ReqId)},
        {?HEADER_NAME_RPC_PARENT_ID, genlib:to_binary(PaReqId)}
    ],
    case send(Url, Headers, WBuffer, Options) of
        {ok, Response} ->
            {Transport#{
                read_buffer => <<RBuffer/binary, Response/binary>>,
                write_buffer => <<>>
            }, ok};
        Error ->
            {Transport#{read_buffer => <<>>, write_buffer => <<>>}, Error}
    end.

-spec close(rpc_transport()) -> {rpc_transport(), ok}.
close(Transport) ->
    {Transport#{}, ok}.

%%
%% Internal functions
%%
send(Url, Headers, WBuffer, Options) ->
    case hackney:request(post, Url, Headers, WBuffer, maps:to_list(Options)) of
        {ok, ResponseStatus, _ResponseHeaders, Ref} ->
            handle_response(ResponseStatus, hackney:body(Ref));
        {error, {closed, _}} ->
            {error, partial_response};
        {error, Reason} ->
            {error, Reason}
    end.

handle_response(200, {ok, Body}) ->
    {ok, Body};
handle_response(StatusCode, Body) ->
    {error, {StatusCode, Body}}.
