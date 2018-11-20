%%% @doc Internal utils
%%% @end

-module(woody_util).
-include("woody_defs.hrl").

-export([get_protocol_handler/2]).
-export([get_mod_opts/1]).
-export([to_binary/1]).
-export([get_rpc_reply_type/1]).
-export([get_req_headers_mode/1]).
-export([get_error_headers_mode/1]).

-export_type([headers_mode/0]).

-define(DEFAULT_HANDLER_OPTS, undefined).

-type headers_mode() :: normal | legacy.

%%
%% Internal API
%%
-spec get_protocol_handler(woody:role(), map()) ->
    woody_client_thrift | woody_server_thrift_http_handler | no_return().
get_protocol_handler(Role, Opts) ->
    Protocol  = genlib_map:get(protocol, Opts, thrift),
    Transport = genlib_map:get(transport, Opts, http),
    case {Role, Protocol, Transport} of
        {client, thrift, http} -> woody_client_thrift;
        {server, thrift, http} -> woody_server_thrift_http_handler;
        _                      -> error(badarg, [Role, Opts])
    end.

-spec get_mod_opts(woody:handler(_)) ->
    {module(), woody:options()}.
get_mod_opts(Handler = {_Mod, _Opts}) ->
    Handler;
get_mod_opts(Mod) ->
    {Mod, ?DEFAULT_HANDLER_OPTS}.

-spec to_binary(atom() | list() | binary()) ->
    binary().
to_binary(Reason) when is_list(Reason) ->
    to_binary(Reason, <<>>);
to_binary(Reason) ->
    to_binary([Reason]).

to_binary([], Reason) ->
    Reason;
to_binary([Part | T], Reason) ->
    BinPart = genlib:to_binary(Part),
    to_binary(T, <<Reason/binary, BinPart/binary>>).

-spec get_rpc_reply_type(_ThriftReplyType) ->
    woody:rpc_type().
get_rpc_reply_type(oneway_void) -> cast;
get_rpc_reply_type(_) -> call.

-spec get_req_headers_mode(cowboy_req:req()) ->
    {headers_mode(), cowboy_req:req()}.
get_req_headers_mode(Req) ->
    Mode = application:get_env(woody, server_headers_mode, auto),
    get_req_headers_mode(Mode, Req).

-spec get_error_headers_mode(woody:http_headers()) ->
    headers_mode().
get_error_headers_mode(Headers) ->
    get_error_headers_mode(application:get_env(woody, client_headers_mode, auto), Headers).

%%
%% Internals
%%


apply_mode_rules([], _Rules, Default) ->
    Default;
apply_mode_rules([Name | HeadersNamesTail] = _Headers, Rules, Default) ->
    case maps:get(Name, Rules, undefined) of
        undefined ->
            apply_mode_rules(HeadersNamesTail, Rules, Default);
        Mode ->
            Mode
    end.

-spec get_req_headers_mode(auto | headers_mode(), cowboy_req:req()) ->
    {headers_mode(), cowboy_req:req()}.
get_req_headers_mode(auto, Req) ->
    Rules = #{
        ?NORMAL_HEADER_RPC_ID => normal,
        ?NORMAL_HEADER_RPC_PARENT_ID => normal,
        ?NORMAL_HEADER_RPC_ROOT_ID => normal
    },
    Headers = cowboy_req:headers(Req),
    {apply_mode_rules(maps:keys(Headers), Rules, legacy), Req};
get_req_headers_mode(legacy = Mode, Req) ->
    {Mode, Req};
get_req_headers_mode(normal = Mode, Req) ->
    {Mode, Req};
get_req_headers_mode(Mode, _Req) ->
    erlang:error(badarg, [Mode]).

-spec get_error_headers_mode(auto | headers_mode(), woody:http_headers()) ->
    headers_mode().
get_error_headers_mode(auto, Headers) ->
    Rules = #{
        ?NORMAL_HEADER_E_CLASS => normal,
        ?NORMAL_HEADER_E_REASON => normal
    },
    apply_mode_rules(maps:keys(Headers), Rules, legacy);
get_error_headers_mode(legacy = Mode, _Headers) ->
    Mode;
get_error_headers_mode(normal = Mode, _Headers) ->
    Mode;
get_error_headers_mode(Mode, _Headers) ->
    erlang:error(badarg, [Mode]).
