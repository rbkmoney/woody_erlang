%%% @doc Client API
%%% @end

-module(woody_client).

-include("woody_defs.hrl").

%% API
-export([child_spec/1]).
-export([call      /2]).
-export([call      /3]).

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
-spec child_spec(options()) ->
    supervisor:child_spec().
child_spec(Options) ->
    woody_client_behaviour:child_spec(Options).

-spec call(woody:request(), options()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, Options) ->
    Context = woody_context:new(),
    call(Request, Options, Context).

-spec call(woody:request(), options(), woody_context:ctx()) ->
    {ok, woody:result()}                      |
    {exception, woody_error:business_error()} |
    no_return().
call(Request, Options = #{event_handler := EvHandler}, Context) ->
    Child = woody_context:new_child(Context),
    WoodyState = woody_state:new(client, Child, EvHandler),
    case call_safe(Request, Options, WoodyState) of
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
-spec call_safe(woody:request(), options(), woody_state:st()) ->
    result().
call_safe(Request, Options, WoodyState) ->
        _ = woody_event_handler:handle_event(?EV_CLIENT_BEGIN, WoodyState, #{}),
    try woody_client_behaviour:call(Request, Options, WoodyState) of
        Resp = {ok, _} ->
            Resp;
        Error = {error, {Type, _}} when Type =:= system ; Type =:= business ->
            Error
    catch
        Class:Reason:StackTrace ->
            handle_client_error(Class, Reason, StackTrace, WoodyState)
    after
        _ = woody_event_handler:handle_event(?EV_CLIENT_END, WoodyState, #{})
    end.

-spec handle_client_error(woody_error:erlang_except(), _Error, _Stacktrace, woody_state:st()) ->
    {error, {system, {internal, result_unexpected, woody_error:details()}}}.
handle_client_error(Class, Error, StackTrace, WoodyState) ->
    Details = woody_error:format_details(Error),
    _ = woody_event_handler:handle_event(?EV_INTERNAL_ERROR, WoodyState, #{
        error    => woody_util:to_binary([?EV_CALL_SERVICE, " error"]),
        class    => Class,
        reason   => Details,
        stack    => StackTrace,
        final    => false
    }),
    {error, {system, {internal, result_unexpected, <<"client error: ", Details/binary>>}}}.
