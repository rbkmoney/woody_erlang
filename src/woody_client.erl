%%% @doc Client API
%%% @end

-module(woody_client).

-include("woody_defs.hrl").

%% API
-export([call/2, call/3]).

%% Types
-type options() :: #{
    protocol      => thrift,
    transport     => http,
    url           => woody:url(),
    event_handler => woody:ev_handler()
    %% Hint: for now hackney options can be passed thru this map as: key => value too
    %% and will be converted to hackney options list. See hackney:request/5 for more info.
    %% ToDo: disable this hack as soon as woody is coupled with nginx in µ container!
}.
-export_type([options/0]).

%% Internal API
-type result() ::
    {ok    , woody:result     ()} |
    {error , woody_error:error()}.
-export_type([result/0]).

%% Behaviour definition
-callback call(woody_context:ctx(), woody:request(), options()) ->  result().

%%
%% API
%%
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
    case call_safe(Request, Options, woody_util:enrich_context(Context, EvHandler)) of
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
    ProtocolHandler = woody_util:get_protocol_handler(client, Options),
    try ProtocolHandler:call(woody_context:new_child(Context), Request, Options) of
        Resp = {ok, _} ->
            Resp;
        Error = {error, {Type, _}} when Type =:= system ; Type =:= business ->
            Error;
        Other ->
            handle_client_error(Other, Context)
    catch
        _:Reason ->
            handle_client_error(Reason, Context)
    end.

-spec handle_client_error(_Error, woody_context:ctx()) ->
    {error, {system, {internal, result_unexpected, woody_error:details()}}}.
handle_client_error(Error, Context) ->
    Details = woody_error:format_details(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, #{
            role     => client,
            severity => error,
            error    => woody_util:to_binary([?EV_CALL_SERVICE, " error"]),
            reason   => Details,
            stack    => erlang:get_stacktrace()
        }, Context),
    {error, {system, {internal, result_unexpected, <<"client error">>}}}.
