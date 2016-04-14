-module(rpc_thrift_http_transport).

-behaviour(thrift_transport).
-dialyzer(no_undefined_callbacks).

-include("rpc_thrift_http_headers.hrl").

%% API
-export([new/4]).

-export([start_client_pool/2]).
-export([stop_client_pool/1]).

%% Thrift transport callbacks
-export([read/2, write/2, flush/1, close/1]).

-type url() :: binary().
-export_type([url/0]).

-record(rpc_transport, {
    req_id :: rpc_t:req_id(),
    parent_req_id = undefined :: undefined | rpc_t:req_id(),
    url :: url(),
    options = #{} :: map(),
    write_buffer = <<>> :: binary(),
    read_buffer = <<>> :: binary()
}).
-type rpc_transport() :: #rpc_transport{}.

%%
%% API
%%
-spec new(boolean(), rpc_t:req_id(), rpc_t:req_id(), rpc_client:options()) ->
    thrift_transport:t_transport().
new(IsRoot, PaReqId, ReqId, TransportOpts = #{url := Url}) ->
    {ok, Transport} = thrift_transport:new(?MODULE, #rpc_transport{
        req_id = ReqId,
        parent_req_id = get_parent_id(IsRoot, PaReqId),
        url = Url,
        options = TransportOpts
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
write(Transport = #rpc_transport{write_buffer = WBuffer}, Data) when
    is_binary(WBuffer),
    is_binary(Data)
->
    {Transport#rpc_transport{write_buffer = <<WBuffer/binary, Data/binary>>}, ok}.

-spec read(rpc_transport(), pos_integer()) -> {rpc_transport(), {ok, binary()}}.
read(Transport = #rpc_transport{read_buffer = RBuffer}, Len) when
    is_binary(RBuffer)
->
    Give = min(byte_size(RBuffer), Len),
    <<Data:Give/binary, RBuffer1/binary>> = RBuffer,
    Response = {ok, Data},
    Transport1 = Transport#rpc_transport{read_buffer = RBuffer1},
    {Transport1, Response}.

-spec flush(rpc_transport()) -> {rpc_transport(), ok | {error, _Reason}}.
flush(Transport = #rpc_transport{
    url = Url,
    parent_req_id = RpcParentId,
    req_id = RpcId,
    options = Options,
    write_buffer = WBuffer,
    read_buffer = RBuffer
}) when
    is_binary(WBuffer),
    is_binary(RBuffer)
->
    Headers = [
        {<<"content-type">>, ?CONTENT_TYPE_THRIFT},
        {<<"accept">>, ?CONTENT_TYPE_THRIFT},
        {?HEADER_NAME_RPC_ID, genlib:to_binary(RpcId)}
    ],
    Headers1 = add_parent_id_header(RpcParentId, Headers),
    case send(Url, Headers1, WBuffer, Options) of
        {ok, Response} ->
            {Transport#rpc_transport{
                read_buffer = <<RBuffer/binary, Response/binary>>,
                write_buffer = <<>>
            }, ok};
        Error ->
            {Transport#rpc_transport{read_buffer = <<>>, write_buffer = <<>>}, Error}
    end.

-spec close(rpc_transport()) -> {rpc_transport(), ok}.
close(Transport) ->
    {Transport#rpc_transport{read_buffer = <<>>, write_buffer = <<>>}, ok}.

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

get_parent_id(true, _) ->
    undefined;
get_parent_id(false, PaReqId) ->
    PaReqId.

add_parent_id_header(undefined, Headers)->
    Headers;
add_parent_id_header(RpcParentId, Headers)->
    [{?HEADER_NAME_RPC_PARENT_ID, genlib:to_binary(RpcParentId)} | Headers].
