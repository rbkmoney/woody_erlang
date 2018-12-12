-module(woody_stream_handler).
-behavior(cowboy_stream).

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    req := cowboy_req:req(),
    ev_handler := woody:ev_handler(),
    next := any()
}.

%% private functions

trace_request(Req, Env) ->
    case maps:get(ev_handler, Env, undefined) of
        undefined ->
            undefined;
        EvHandler ->
            Config = woody_server_thrift_http_handler:config(),
            _ = woody_server_thrift_http_handler:trace_req(genlib_app:env(woody, trace_http_server),
                Req, EvHandler, Config),
            EvHandler
    end.

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    Env = maps:get(env, Opts, #{}),
    EvHandler = trace_request(Req, Env),
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next, req => Req, ev_handler => EvHandler}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::state().
data(StreamID, IsFin, Data, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands0, State#{next => Next}}.

-spec info(cowboy_stream:streamid(), any(), State)
    -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, {response, Code, Headers, Body} = Info, #{next := Next0, req := Req, ev_handler := EvHandler} = State) ->
    Env = genlib_app:env(woody, trace_http_server),
    woody_server_thrift_http_handler:trace_resp(Env, Req, Code, Headers, Body, EvHandler),
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}};
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #{next := Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).
