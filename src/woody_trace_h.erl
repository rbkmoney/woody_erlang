-module(woody_trace_h).
-behaviour(cowboy_stream).

-dialyzer(no_undefined_callbacks).

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    req := cowboy_req:req(),
    ev_handler := woody:ev_handler() | [woody:ev_handler()],
    next := any()
}.

-define(TRACER, trace_http_server).

%% private functions

trace_request(Req, EvHandler, ReadBodyOpts) ->
    woody_server_thrift_http_handler:trace_req(genlib_app:env(woody, ?TRACER), Req, EvHandler, ReadBodyOpts).

trace_response(Req, {response, Code, Headers, Body}, EvHandler) ->
    woody_server_thrift_http_handler:trace_resp(genlib_app:env(woody, ?TRACER), Req, Code, Headers, Body, EvHandler).

% We can't go without Env AND event handler, so we want to fail, reading opts are optional tho
extract_trace_options(Opts) ->
    Env = maps:get(env, Opts),
    {maps:get(event_handler, Env), maps:get(read_body_opts, Env, #{})}.

%% callbacks

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    {EvHandler, ReadBodyOpts} = extract_trace_options(Opts),
    _ = trace_request(Req, EvHandler, ReadBodyOpts),
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next, req => Req, ev_handler => EvHandler}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::state().
data(StreamID, IsFin, Data, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands0, State#{next => Next}}.

-spec info(cowboy_stream:streamid(), any(), State)
    -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, {response, _, _, _} = Info, #{next := Next0, req := Req, ev_handler := EvHandler} = State) ->
    _ = trace_response(Req, Info, EvHandler),
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}};
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #{next := Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

%% At this point we have both request (it's part actually) and response, so we might track them in one place
-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    {EvHandler, ReadBodyOpts} = extract_trace_options(Opts),
    _ = trace_request(PartialReq, EvHandler, ReadBodyOpts),
    _ = trace_response(PartialReq, Resp, EvHandler),
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).
