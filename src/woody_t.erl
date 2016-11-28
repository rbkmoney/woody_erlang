%%% @doc Type definitions for the rpc library
%%% @end
-module(woody_t).


%% API
-export([get_protocol_handler/2]).

-type req_id()    :: binary().
-type span_id()   :: req_id().
-type trace_id()  :: req_id().
-type parent_id() :: req_id().

-type rpc_id() :: #{
    span_id   => span_id(),
    trace_id  => trace_id(),
    parent_id => parent_id()
}.

-type dapper_id() :: span_id | trace_id | parent_id.

-export_type([dapper_id/0, span_id/0, parent_id/0, trace_id/0]).
-export_type([req_id/0, rpc_id/0]).

-type options() :: map().
-type handler() :: module().
-type url()     :: binary().
-type role()    :: client | server.

-type service_name() :: atom().
-type service()      :: {handler(), service_name()}.
-type func()         :: atom().

%% copy-paste from OTP supervsor
-type sup_ref()  :: (Name :: atom())
                  | {Name :: atom(), Node :: node()}
                  | {'global', Name :: atom()}
                  | {'via', Module :: module(), Name :: any()}
                  | pid().

-export_type([service/0, service_name/0, func/0, options/0,
    handler/0, url/0, role/0, sup_ref/0]).


%%
%% API
%%
-spec get_protocol_handler(role(), map()) ->
    woody_client_thrift | woody_server_thrift_http_handler | no_return().
get_protocol_handler(Role, Opts) when Role =:= client ; Role =:= server->
    Protocol  = genlib_map:get(protocol, Opts, thrift),
    Transport = genlib_map:get(transport, Opts, http),
    case {Protocol, Transport, Role} of
        {thrift, http, client} -> woody_client_thrift;
        {thrift, http, server} -> woody_server_thrift_http_handler;
        {_, http, _}           -> error({badarg, protocol_unsupported});
        {thrift, _, _}         -> error({badarg, transport_unsupported})
    end.
