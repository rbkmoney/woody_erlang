-module(woody_client_behaviour).

-export([child_spec/1]).
-export([call      /3]).

%% Behaviour definition
-callback call(woody:request(), woody_client:options(), woody:rpc_ctx()) ->  woody_client:result().
-callback child_spec(woody_client:options()) -> supervisor:child_spec().

-spec child_spec(woody_client:options()) ->
    supervisor:child_spec().
child_spec(Options) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:child_spec(Options).

-spec call(woody:request(), woody_client:options(), woody:rpc_ctx()) ->
    woody_client:result().
call(Request, Options, Context) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:call(Request, Options, Context).
