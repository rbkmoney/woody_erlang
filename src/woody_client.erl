%%% @doc Client API
%%% @end

-module(woody_client).

-include("woody_defs.hrl").

%% API
-export([connection_pool_spec/1]).
-export([call                /2]).
-export([call                /3]).

%% Types
-type options() :: #{
    url            := woody:url(),
    event_handler  := woody:ev_handler(),
    transport_opts => woody_client_thrift_http_transport:options(), %% See hackney:request/5 for available options.
    protocol       => thrift,
    transport      => http
}.
-export_type([options/0]).

%% Internal API
-type result() ::
    {ok    , woody:result     ()} |
    {error , woody_error:error()}.
-export_type([result/0]).


%%
%% API
%%
-spec connection_pool_spec(options()) ->
    supervisor:child_spec().
connection_pool_spec(Options) ->
    woody_client_behaviour:connection_pool_spec(Options).

-spec call(woody:request(), options()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, Options) ->
    call(Request, Options, woody_context:new()).

-spec call(woody:request(), options(), woody_context:ctx()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, Options = #{event_handler := EvHandler}, Context) ->
    case call_safe(Request, Options, woody_context:enrich(Context, EvHandler)) of
        Result = {ok, _} ->
            Result;
        {error, {business, Error}} ->
            {exception, Error};
        {error, {system, Error}} ->
            woody_error:raise(system, Error)
    end.

%%
%% Internal functions
%%
-spec call_safe(woody:request(), options(), woody_context:ctx()) ->
    result().
call_safe(Request, Options, Context) ->
    try woody_client_behaviour:call(Request, Options, woody_context:new_child(Context)) of
        Resp = {ok, _} ->
            Resp;
        Error = {error, {Type, _}} when Type =:= system ; Type =:= business ->
            Error
    catch
        Class:Reason ->
            handle_client_error(Class, Reason, Context)
    end.

-spec handle_client_error(woody_error:erlang_except(), _Error, woody_context:ctx()) ->
    {error, {system, {internal, result_unexpected, woody_error:details()}}}.
handle_client_error(Class, Error, Context) ->
    Details = woody_error:format_details(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, #{
            role     => client,
            error    => woody_util:to_binary([?EV_CALL_SERVICE, " error"]),
            class    => Class,
            reason   => Details,
            stack    => erlang:get_stacktrace()
        }, Context),
    {error, {system, {internal, result_unexpected, <<"client error">>}}}.
