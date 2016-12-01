%%% @doc Client API
%%% @end

-module(woody_util).

-export([get_protocol_handler/2]).

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
