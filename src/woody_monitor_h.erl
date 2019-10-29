-module(woody_monitor_h).
-behaviour(cowboy_stream).

-include("woody_defs.hrl").

%% callback exports

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    next := any(),
    woody_state => woody_state:st(),
    event_to_emit => woody_event_handler:event()
}.

-export([put_woody_state/2]).
-export([handle_event/2]).

-spec put_woody_state(woody_state:st(), cowboy_req:req()) -> ok.
put_woody_state(WoodyState, Req) ->
    cowboy_req:cast({woody_state, WoodyState}, Req).

-spec handle_event(woody_event_handler:event(), cowboy_req:req()) -> ok.
handle_event(Event, Req) ->
    cowboy_req:cast({woody_event, Event}, Req).

%% callbacks

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next, event_to_emit => ?EV_SERVER_RECEIVE}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::state().
data(StreamID, IsFin, Data, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands0, State#{next => Next}}.

-spec info(cowboy_stream:streamid(), any(), State)
    -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, {woody_state, WoodyState} = Info, #{next := Next0} = State) ->
    {Commands, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands, State#{next => Next, woody_state => WoodyState}};
% Handler emited server receive, so monitor should emit service result
info(StreamID, {woody_event, ?EV_SERVER_RECEIVE} = Info, #{next := Next0} = State) ->
    {Commands, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands, State#{next => Next, event_to_emit => ?EV_SERVICE_HANDLER_RESULT}};
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(
    StreamID,
    {socket_error, _, HumanReadable} = Reason,
    #{woody_state := WoodyState, next := Next, event_to_emit:= Event}
) ->
    woody_event_handler:handle_event(Event,
        WoodyState,
        #{status => error, reason => woody_util:to_binary(HumanReadable)}
    ),
    cowboy_stream:terminate(StreamID, Reason, Next);
terminate(StreamID, Reason, #{next := Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    % We can't really do anything about it
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).
