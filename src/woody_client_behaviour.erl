-module(woody_client_behaviour).

-export([connection_pool_spec/1]).
-export([call                /3]).

%% Behaviour definition
-callback call(woody:request(), woody_client:options(), woody_context:ctx()) ->  woody_client:result().
-callback connection_pool_spec(woody_client:options()) -> supervisor:child_spec().

-spec connection_pool_spec(woody_client:options()) ->
    supervisor:child_spec().
connection_pool_spec(Options) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:connection_pool_spec(Options).

-spec call(woody:request(), woody_client:options(), woody_context:ctx()) ->
    woody_client:result().
call(Request, Options, Context) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:call(Request, Options, Context).
