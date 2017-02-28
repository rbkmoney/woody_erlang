-module(woody_client_behaviour).

-export([child_spec/1, find_pool/2, call/3]).

%% Behaviour definition
-callback call(woody:request(), woody_client:options(), woody_context:ctx()) ->  woody_client:result().

-spec child_spec(woody_client:options()) ->
	supervisor:child_spec().
child_spec(Options) ->
	Handler = woody_util:get_protocol_handler(client, Options),
	Handler:child_spec(Options).

-spec find_pool(any(), woody_client:options()) ->
    pid() | undefined.
find_pool(Name, Options) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:child_spec(Name).

-spec call(woody:request(), woody_client:options(), woody_context:ctx()) ->
    woody_client:result().
call(Request, Options, Context) ->
    Handler = woody_util:get_protocol_handler(client, Options),
    Handler:call(Request, Options, Context).
