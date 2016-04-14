%%% @doc Type definitions for the rpc library
%%% @end
-module(rpc_t).


%% API
-export([get_protocol_handler/2]).

-type req_id() :: binary().
-type options() :: map().
-type handler() :: module().
-type url() :: binary().
-type role() :: client | server.

-type service() :: handler().
-type func() :: atom().

%% copy-paste from OTP supervsor
-type sup_ref()  :: (Name :: atom())
                  | {Name :: atom(), Node :: node()}
                  | {'global', Name :: atom()}
                  | {'via', Module :: module(), Name :: any()}
                  | pid().

-export_type([req_id/0, service/0, func/0, options/0, handler/0,
    url/0, role/0, sup_ref/0]).


%%
%% API
%%
-spec get_protocol_handler(role(), map()) -> rpc_thrift_client | rpc_thrift_http_handler | no_return().
get_protocol_handler(Role, Opts) when Role =:= client ; Role =:= server->
    Protocol = genlib_map:get(protocol, Opts, thrift),
    Transport = genlib_map:get(transport, Opts, http),
    case {Protocol, Transport, Role} of
        {thrift, http, client} -> rpc_thrift_client;
        {thrift, http, server} -> rpc_thrift_http_handler;
        {_, http, _} -> error({badarg, protocol_unsupported});
        {thrift, _, _} -> error({badarg, transport_unsupported})
    end.
