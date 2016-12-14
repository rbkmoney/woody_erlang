%%% @doc Internal utils
%%% @end

-module(woody_util).

-export([get_protocol_handler/2]).
-export([get_mod_opts/1]).
-export([to_binary/1]).

-define(DEFAULT_HANDLER_OPTS, undefined).

%% Types
-type role() :: client | server.

%%
%% Internal API
%%
-spec get_protocol_handler(role(), map()) ->
    woody_client_thrift | woody_server_thrift_http_handler | no_return().
get_protocol_handler(Role, Opts) ->
    Protocol  = genlib_map:get(protocol, Opts, thrift),
    Transport = genlib_map:get(transport, Opts, http),
    case {Protocol, Transport, Role} of
        {thrift, http, client} -> woody_client_thrift;
        {thrift, http, server} -> woody_server_thrift_http_handler;
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
