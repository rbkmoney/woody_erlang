-module(woody_resolver).

-include("woody_defs.hrl").

-include_lib("kernel/include/inet.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-type url() :: binary() | nonempty_string().
-type parsed_url() :: #hackney_url{}.

-type resolver_opts() :: #{
    ip_picker := {module(), atom()},
    timeout := timeout()
}.

-export([resolve_url/2]).
-export([resolve_url/3]).

%%

-spec resolve_url(url(), woody_state:st()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.
resolve_url(Url, WoodyState) ->
    resolve_url(Url, WoodyState, #{
        ip_picker => {erlang, hd},
        timeout => infinity
    }).

-spec resolve_url(url(), woody_state:st(), resolver_opts()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.
resolve_url(Url, WoodyState, Opts) when is_list(Url) ->
    resolve_url(list_to_binary(Url), WoodyState, Opts);
resolve_url(<<"https://", _Rest/binary>> = Url, WoodyState, Opts) ->
    resolve_parsed_url(parse_url(Url), WoodyState, Opts);
resolve_url(<<"http://", _Rest/binary>> = Url, WoodyState, Opts) ->
    resolve_parsed_url(parse_url(Url), WoodyState, Opts);
resolve_url(_Url, _WoodyState, _Opts) ->
    {error, unsupported_url_scheme}.

%%

parse_url(Url) ->
    hackney_url:parse_url(Url).

resolve_parsed_url(ParsedUrl = #hackney_url{}, WoodyState, Opts) ->
    case inet:parse_address(ParsedUrl#hackney_url.host) of
        {ok, _} -> {ok, ParsedUrl}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl, WoodyState, Opts)
    end.

do_resolve_url(ParsedUrl, WoodyState, Opts) ->
    _ = log_event(?EV_CLIENT_RESOLVE_BEGIN, WoodyState, #{host => ParsedUrl#hackney_url.host}),
    case lookup_host(ParsedUrl#hackney_url.host, Opts) of
        {ok, {IpAddr, _} = AddrInfo} ->
            _ = log_event(?EV_CLIENT_RESOLVE_RESULT, WoodyState, #{
                status => ok,
                host => ParsedUrl#hackney_url.host,
                address => inet:ntoa(IpAddr)
            }),
            {ok, replace_host(ParsedUrl, AddrInfo)};
        {error, Reason} ->
            _ = log_event(?EV_CLIENT_RESOLVE_RESULT, WoodyState, #{
                status => error,
                host => ParsedUrl#hackney_url.host,
                reason => Reason
            }),
            {error, Reason}
    end.

lookup_host(Host, #{timeout := Timeout} = Opts) ->
    case inet:gethostbyname(Host, get_preferred_ip_family(), Timeout) of
        {ok, HostEnt} ->
            {ok, parse_hostent(HostEnt, Opts)};
        {error, Reason} ->
            {error, Reason}
    end.

replace_host(ParsedUrl, {IpAddr, IpFamily}) ->
    HostStr = inet:ntoa(IpAddr),
    Netloc = encode_netloc(HostStr, IpFamily, ParsedUrl#hackney_url.port),
    ParsedUrl#hackney_url{netloc = Netloc, host = HostStr}.

encode_netloc(HostStr, IpFamily, Port) ->
    BinHost = list_to_binary(HostStr),
    BinPort = integer_to_binary(Port),
    case IpFamily of
        inet -> <<BinHost/binary, ":", BinPort/binary>>;
        inet6 -> <<"[", BinHost/binary, "]:", BinPort/binary>>
    end.

parse_hostent(HostEnt, Opts) ->
    {get_ip(HostEnt, Opts), get_ip_family(HostEnt)}.

get_ip(HostEnt, #{ip_picker := {M, F}}) ->
    erlang:apply(M, F, [HostEnt#hostent.h_addr_list]).

get_ip_family(HostEnt) ->
    HostEnt#hostent.h_addrtype.

get_preferred_ip_family() ->
    case inet_db:res_option(inet6) of
        true -> inet6;
        false -> inet
    end.

%%

log_event(Event, WoodyState, ExtraMeta) ->
        woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
