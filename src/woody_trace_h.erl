-module(woody_trace_h).

-include("woody_defs.hrl").

-dialyzer(no_undefined_callbacks).

-export([env/1]).

-behaviour(cowboy_stream).

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-type state() :: #{
    req := cowboy_req:req(),
    opts := woody:ev_handler(),
    next := any()
}.

-define(TRACER, trace_http_server).

-type options() :: #{
    event_handler := woody:ev_handlers()
}.

-spec env(options()) -> cowboy_middleware:env().
env(Opts = #{}) ->
    EvHandler = maps:get(event_handler, Opts),
    #{?MODULE => EvHandler}.

extract_trace_options(#{env := Env}) ->
    maps:get(?MODULE, Env).

%% private functions

trace_request(Req, EvHandler) ->
    trace_req(genlib_app:env(woody, ?TRACER), Req, EvHandler).

trace_response(Req, {response, Code, Headers, Body}, EvHandler) ->
    trace_resp(genlib_app:env(woody, ?TRACER), Req, Code, Headers, Body, EvHandler).

-spec trace_req(true, cowboy_req:req(), woody:ev_handlers()) -> cowboy_req:req().
trace_req(true, Req, EvHandler) ->
    Url = unicode:characters_to_binary(cowboy_req:uri(Req)),
    Headers = cowboy_req:headers(Req),
    % TODO
    % No body here since with Cowboy 2 we can consume it only once.
    % Ideally we would need to embed tracing directly into handler itself.
    Meta = #{
        role => server,
        event => <<"http request received">>,
        url => Url,
        headers => Headers
    },
    _ = woody_event_handler:handle_event(EvHandler, ?EV_TRACE, undefined, Meta),
    Req;
trace_req(_, Req, _) ->
    Req.

-spec trace_resp(
    true,
    cowboy_req:req(),
    woody:http_code(),
    woody:http_headers(),
    woody:http_body(),
    woody:ev_handlers()
) -> cowboy_req:req().
trace_resp(true, Req, Code, Headers, Body, EvHandler) ->
    _ = woody_event_handler:handle_event(EvHandler, ?EV_TRACE, undefined, #{
        role => server,
        event => <<"http response send">>,
        code => Code,
        headers => Headers,
        body => Body
    }),
    Req;
trace_resp(_, Req, _, _, _, _) ->
    Req.

%% callbacks

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts()) -> {cowboy_stream:commands(), state()}.
init(StreamID, Req, Opts) ->
    TraceOpts = extract_trace_options(Opts),
    _ = trace_request(Req, TraceOpts),
    {Commands0, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {Commands0, #{next => Next, req => Req, opts => TraceOpts}}.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State) ->
    {cowboy_stream:commands(), State}
when
    State :: state().
data(StreamID, IsFin, Data, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands0, State#{next => Next}}.

-spec info(cowboy_stream:streamid(), any(), State) -> {cowboy_stream:commands(), State} when State :: state().
info(StreamID, {response, _, _, _} = Info, #{next := Next0, req := Req, opts := TraceOpts} = State) ->
    _ = trace_response(Req, Info, TraceOpts),
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}};
info(StreamID, Info, #{next := Next0} = State) ->
    {Commands0, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands0, State#{next => Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> any().
terminate(StreamID, Reason, #{next := Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

%% At this point we have both request (it's part actually) and response, so we might track them in one place
-spec early_error(
    cowboy_stream:streamid(),
    cowboy_stream:reason(),
    cowboy_stream:partial_req(),
    Resp,
    cowboy:opts()
) -> Resp when
    Resp :: cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    TraceOpts = extract_trace_options(Opts),
    _ = trace_request(PartialReq, TraceOpts),
    _ = trace_response(PartialReq, Resp, TraceOpts),
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).
