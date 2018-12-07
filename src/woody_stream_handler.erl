-module(woody_stream_handler).
-behaviour(cowboy_stream).

-include("woody_defs.hrl").

-ifdef(OTP_RELEASE).
-compile({nowarn_deprecated_function, [{erlang, get_stacktrace, 0}]}).
-endif.

-export([init/3]).
-export([data/4]).
-export([info/3]).
-export([terminate/3]).
-export([early_error/5]).

-export([request_process/3]).
-export([execute/3]).
-export([resume/5]).

-record(state, {
    next :: any(),
    ref = undefined :: ranch:ref(),
    pid = undefined :: pid(),
    expect = undefined :: undefined | continue,
    read_body_ref = undefined :: reference() | undefined,
    read_body_timer_ref = undefined :: reference() | undefined,
    read_body_length = 0 :: non_neg_integer() | infinity | auto,
    read_body_is_fin = nofin :: nofin | {fin, non_neg_integer()},
    read_body_buffer = <<>> :: binary(),
    body_length = 0 :: non_neg_integer(),
    req  :: cowboy_req:req(),
    ev_handler :: woody:ev_handler()
}).

-type state() :: #state{}.

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

%% cowboy_stream callbacks

%% @todo For shutting down children we need to have a timeout before we terminate
%% the stream like supervisors do. So here just send a message to yourself first,
%% and then decide what to do when receiving this message.

-spec init(cowboy_stream:streamid(), cowboy_req:req(), cowboy:opts())
    -> {[{spawn, pid(), timeout()}], state()}.
init(StreamID, Req=#{ref := Ref}, Opts) ->
    Env = maps:get(env, Opts, #{}),
    EvHandler = trace_request(Req, Env),
    Middlewares = maps:get(middlewares, Opts, [cowboy_router, cowboy_handler]),
    Shutdown = maps:get(shutdown_timeout, Opts, 5000),
    Pid = proc_lib:spawn_link(?MODULE, request_process, [Req, Env, Middlewares]),
    Expect = expect(Req),
    {Commands, Next} = cowboy_stream:init(StreamID, Req, Opts),
    {[{spawn, Pid, Shutdown}|Commands],
        #state{next=Next, ref=Ref, pid=Pid, expect=Expect, req=Req, ev_handler=EvHandler}}.

%% Ignore the expect header in HTTP/1.0.
expect(#{version := 'HTTP/1.0'}) ->
    undefined;
expect(Req) ->
    try cowboy_req:parse_header(<<"expect">>, Req) of
        Expect ->
            Expect
    catch _:_ ->
        undefined
    end.

%% If we receive data and stream is waiting for data:
%%   If we accumulated enough data or IsFin=fin, send it.
%%   If we are in auto mode, send it and update flow control.
%%   If not, buffer it.
%% If not, buffer it.
%%
%% We always reset the expect field when we receive data,
%% since the client started sending the request body before
%% we could send a 100 continue response.

-spec data(cowboy_stream:streamid(), cowboy_stream:fin(), cowboy_req:resp_body(), State)
    -> {cowboy_stream:commands(), State} when State::state().
%% Stream isn't waiting for data.
data(StreamID, IsFin, Data, State=#state{
        read_body_ref=undefined, read_body_buffer=Buffer, body_length=BodyLen}) ->
    do_data(StreamID, IsFin, Data, [], State#state{
        expect=undefined,
        read_body_is_fin=IsFin,
        read_body_buffer= << Buffer/binary, Data/binary >>,
        body_length=BodyLen + byte_size(Data)
    });
%% Stream is waiting for data using auto mode.
%%
%% There is no buffering done in auto mode.
data(StreamID, IsFin, Data, State=#state{pid=Pid, read_body_ref=Ref,
        read_body_length=auto, body_length=BodyLen}) ->
    send_request_body(Pid, Ref, IsFin, BodyLen, Data),
    do_data(StreamID, IsFin, Data, [{flow, byte_size(Data)}], State#state{
        read_body_ref=undefined,
        body_length=BodyLen
    });
%% Stream is waiting for data but we didn't receive enough to send yet.
data(StreamID, IsFin=nofin, Data, State=#state{
        read_body_length=ReadLen, read_body_buffer=Buffer, body_length=BodyLen})
        when byte_size(Data) + byte_size(Buffer) < ReadLen ->
    do_data(StreamID, IsFin, Data, [], State#state{
        expect=undefined,
        read_body_buffer= << Buffer/binary, Data/binary >>,
        body_length=BodyLen + byte_size(Data)
    });
%% Stream is waiting for data and we received enough to send.
data(StreamID, IsFin, Data, State=#state{pid=Pid, read_body_ref=Ref,
        read_body_timer_ref=TRef, read_body_buffer=Buffer, body_length=BodyLen0}) ->
    BodyLen = BodyLen0 + byte_size(Data),
    %% @todo Handle the infinity case where no TRef was defined.
    ok = erlang:cancel_timer(TRef, [{async, true}, {info, false}]),
    send_request_body(Pid, Ref, IsFin, BodyLen, <<Buffer/binary, Data/binary>>),
    do_data(StreamID, IsFin, Data, [], State#state{
        expect=undefined,
        read_body_ref=undefined,
        read_body_timer_ref=undefined,
        read_body_buffer= <<>>,
        body_length=BodyLen
    }).

do_data(StreamID, IsFin, Data, Commands1, State=#state{next=Next0}) ->
    {Commands2, Next} = cowboy_stream:data(StreamID, IsFin, Data, Next0),
    {Commands1 ++ Commands2, State#state{next=Next}}.

-spec info(cowboy_stream:streamid(), any(), State)
    -> {cowboy_stream:commands(), State} when State::state().
info(StreamID, Info={'EXIT', Pid, normal}, State=#state{pid=Pid}) ->
    do_info(StreamID, Info, [stop], State);
info(StreamID, Info={'EXIT', Pid, {{request_error, Reason, _HumanReadable}, _}},
        State=#state{pid=Pid}) ->
    Status = case Reason of
        timeout -> 408;
        payload_too_large -> 413;
        _ -> 400
    end,
    %% @todo Headers? Details in body? Log the crash? More stuff in debug only?
    do_info(StreamID, Info, [
        {error_response, Status, #{<<"content-length">> => <<"0">>}, <<>>},
        stop
    ], State);
info(StreamID, Exit={'EXIT', Pid, {Reason, Stacktrace}}, State=#state{ref=Ref, pid=Pid}) ->
    Commands0 = [{internal_error, Exit, 'Stream process crashed.'}],
    Commands = case Reason of
        normal -> Commands0;
        shutdown -> Commands0;
        {shutdown, _} -> Commands0;
        _ -> [{log, error,
                "Ranch listener ~p, connection process ~p, stream ~p "
                "had its request process ~p exit with reason "
                "~999999p and stacktrace ~999999p~n",
                [Ref, self(), StreamID, Pid, Reason, Stacktrace]}
            |Commands0]
    end,
    do_info(StreamID, Exit, [
        {error_response, 500, #{<<"content-length">> => <<"0">>}, <<>>}
    |Commands], State);
%% Request body, auto mode, no body buffered.
info(StreamID, Info={read_body, Ref, auto, infinity}, State=#state{read_body_buffer= <<>>}) ->
    do_info(StreamID, Info, [], State#state{
        read_body_ref=Ref,
        read_body_length=auto
    });
%% Request body, auto mode, body buffered or complete.
info(StreamID, Info={read_body, Ref, auto, infinity}, State=#state{pid=Pid,
        read_body_is_fin=IsFin, read_body_buffer=Buffer, body_length=BodyLen}) ->
    send_request_body(Pid, Ref, IsFin, BodyLen, Buffer),
    do_info(StreamID, Info, [{flow, byte_size(Buffer)}],
        State#state{read_body_buffer= <<>>});
%% Request body, body buffered large enough or complete.
%%
%% We do not send a 100 continue response if the client
%% already started sending the body.
info(StreamID, Info={read_body, Ref, Length, _}, State=#state{pid=Pid,
        read_body_is_fin=IsFin, read_body_buffer=Buffer, body_length=BodyLen})
        when IsFin =:= fin; byte_size(Buffer) >= Length ->
    send_request_body(Pid, Ref, IsFin, BodyLen, Buffer),
    do_info(StreamID, Info, [], State#state{read_body_buffer= <<>>});
%% Request body, not enough to send yet.
info(StreamID, Info={read_body, Ref, Length, Period}, State=#state{expect=Expect}) ->
    Commands = case Expect of
        continue -> [{inform, 100, #{}}, {flow, Length}];
        undefined -> [{flow, Length}]
    end,
    %% @todo Handle the case where Period =:= infinity.
    TRef = erlang:send_after(Period, self(), {{self(), StreamID}, {read_body_timeout, Ref}}),
    do_info(StreamID, Info, Commands, State#state{
        read_body_ref=Ref,
        read_body_timer_ref=TRef,
        read_body_length=Length
    });
%% Request body reading timeout; send what we got.
info(StreamID, Info={read_body_timeout, Ref}, State=#state{pid=Pid, read_body_ref=Ref,
        read_body_is_fin=IsFin, read_body_buffer=Buffer, body_length=BodyLen}) ->
    send_request_body(Pid, Ref, IsFin, BodyLen, Buffer),
    do_info(StreamID, Info, [], State#state{
        read_body_ref=undefined,
        read_body_timer_ref=undefined,
        read_body_buffer= <<>>
    });
info(StreamID, Info={read_body_timeout, _}, State) ->
    do_info(StreamID, Info, [], State);
%% Response.
%%
%% We reset the expect field when a 100 continue response
%% is sent or when any final response is sent.
info(StreamID, Inform={inform, Status, _}, State0) ->
    State = case cow_http:status_to_integer(Status) of
        100 -> State0#state{expect=undefined};
        _ -> State0
    end,
    do_info(StreamID, Inform, [Inform], State);
info(StreamID, Response={response, _, _, _}, State) ->
    do_info(StreamID, Response, [Response], State#state{expect=undefined});
info(StreamID, Headers={headers, _, _}, State) ->
    do_info(StreamID, Headers, [Headers], State#state{expect=undefined});
info(StreamID, Data={data, _, _}, State) ->
    do_info(StreamID, Data, [Data], State);
info(StreamID, Trailers={trailers, _}, State) ->
    do_info(StreamID, Trailers, [Trailers], State);
info(StreamID, Push={push, _, _, _, _, _, _, _}, State) ->
    do_info(StreamID, Push, [Push], State);
info(StreamID, SwitchProtocol={switch_protocol, _, _, _}, State) ->
    do_info(StreamID, SwitchProtocol, [SwitchProtocol], State#state{expect=undefined});
%% Unknown message, either stray or meant for a handler down the line.
info(StreamID, Info, State) ->
    do_info(StreamID, Info, [], State).


do_info(StreamID, {response, Code, Headers, Body} = Info, Commands1,
        State0=#state{next=Next0, req=Req, ev_handler=EvHandler}) when EvHandler =/= undefined ->
    Env = genlib_app:env(woody, trace_http_server),
    woody_server_thrift_http_handler:trace_resp(Env, Req, Code, Headers, Body, EvHandler),
    {Commands2, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands1 ++ Commands2, State0#state{next=Next}};

do_info(StreamID, Info, Commands1, State0=#state{next=Next0}) ->
    {Commands2, Next} = cowboy_stream:info(StreamID, Info, Next0),
    {Commands1 ++ Commands2, State0#state{next=Next}}.

-spec terminate(cowboy_stream:streamid(), cowboy_stream:reason(), state()) -> ok.
terminate(StreamID, Reason, #state{next=Next}) ->
    cowboy_stream:terminate(StreamID, Reason, Next).

-spec early_error(cowboy_stream:streamid(), cowboy_stream:reason(),
    cowboy_stream:partial_req(), Resp, cowboy:opts()) -> Resp
    when Resp::cowboy_stream:resp_command().
early_error(StreamID, Reason, PartialReq, Resp, Opts) ->
    cowboy_stream:early_error(StreamID, Reason, PartialReq, Resp, Opts).

send_request_body(Pid, Ref, nofin, _, Data) ->
    Pid ! {request_body, Ref, nofin, Data},
    ok;
send_request_body(Pid, Ref, fin, BodyLen, Data) ->
    Pid ! {request_body, Ref, fin, BodyLen, Data},
    ok.

%% Request process.

%% We catch all exceptions in order to add the stacktrace to
%% the exit reason as it is not propagated by proc_lib otherwise
%% and therefore not present in the 'EXIT' message. We want
%% the stacktrace in order to simplify debugging of errors.
%%
%% This + the behavior in proc_lib means that we will get a
%% {Reason, Stacktrace} tuple for every exceptions, instead of
%% just for errors and throws.
%%
%% @todo Better spec.
-spec request_process(_, _, _) -> _.
request_process(Req, Env, Middlewares) ->
    OTP = erlang:system_info(otp_release),
    try
        execute(Req, Env, Middlewares)
    catch
        exit:Reason ->
            Stacktrace = erlang:get_stacktrace(),
            erlang:raise(exit, {Reason, Stacktrace}, Stacktrace);
        %% OTP 19 does not propagate any exception stacktraces,
        %% we therefore add it for every class of exception.
        _:Reason when OTP =:= "19" ->
            Stacktrace = erlang:get_stacktrace(),
            erlang:raise(exit, {Reason, Stacktrace}, Stacktrace);
        %% @todo I don't think this clause is necessary.
        Class:Reason ->
            erlang:raise(Class, Reason, erlang:get_stacktrace())
    end.

%% @todo
%-spec execute(cowboy_req:req(), #state{}, cowboy_middleware:env(), [module()])
%      -> ok.
-spec execute(_, _, _) -> _.
execute(_, _, []) ->
    ok; %% @todo Maybe error reason should differ here and there.
execute(Req, Env, [Middleware|Tail]) ->
    case Middleware:execute(Req, Env) of
        {ok, Req2, Env2} ->
            execute(Req2, Env2, Tail);
        {suspend, Module, Function, Args} ->
            proc_lib:hibernate(?MODULE, resume, [Env, Tail, Module, Function, Args]);
        {stop, _Req2} ->
            ok %% @todo Maybe error reason should differ here and there.
    end.

-spec resume(cowboy_middleware:env(), [module()],
    module(), module(), [any()]) -> ok.
resume(Env, Tail, Module, Function, Args) ->
    case apply(Module, Function, Args) of
        {ok, Req2, Env2} ->
            execute(Req2, Env2, Tail);
        {suspend, Module2, Function2, Args2} ->
            proc_lib:hibernate(?MODULE, resume, [Env, Tail, Module2, Function2, Args2]);
        {stop, _Req2} ->
            ok %% @todo Maybe error reason should differ here and there.
    end.
