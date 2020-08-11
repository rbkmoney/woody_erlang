%%% @doc Internal utils
%%% @end

-module(woody_util).

-export([get_protocol_handler/2]).
-export([get_mod_opts/1]).
-export([to_binary/1]).
-export([get_rpc_reply_type/1]).

-define(DEFAULT_HANDLER_OPTS, undefined).

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

-spec get_mod_opts(woody:handler(woody:options())) ->
    {module(), woody:options()}.
get_mod_opts(Handler = {Mod, _Opts}) when is_atom(Mod) ->
    Handler;
get_mod_opts(Mod) when is_atom(Mod) ->
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
