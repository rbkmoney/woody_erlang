-module(woody_monitor).
-behaviour(cowboy_stream).

-dialyzer(no_undefined_callbacks).

%% callback exports

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    next := any(),
    woody_state := woody_state:st()
}.

-export([put_woody_state/2]).

-spec put_woody_state(woody_state:st(), cowboy_req:req()) -> any().
put_woody_state(WoodyState, #{pid := Pid, streamid := StreamID}) ->
    ct:log("Pid: ~p, StreamID: ~p", [Pid, StreamID]),
    Pid ! {{Pid, StreamID}, {woody_state, WoodyState}}. % cowboy-certified way to send messages to streams

%% callbacks

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next}}.

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
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #{next := Next}) ->
    % TODO log termination
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, _Opts) ->
    % TODO: Log smth
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, #{}).
