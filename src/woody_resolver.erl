-module(woody_resolver).

-include("woody_defs.hrl").

-include_lib("kernel/include/inet.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-type url() :: woody:url().
-type parsed_url() :: #hackney_url{}.

-type resolve_result() :: {Old::parsed_url(), New::parsed_url()}.

-type options() :: #{
    ip_picker => ip_picker(),
    timeout => timeout()
}.

-type ip_picker() :: {module(), atom()} | predefined_ip_picker().
-type predefined_ip_picker() ::
    random |
    first.

-export_type([options/0]).
-export_type([ip_picker/0]).
-export_type([predefined_ip_picker/0]).

-export([resolve_url/2]).
-export([resolve_url/3]).

-define(DEFAULT_RESOLVE_TIMEOUT, infinity).
-define(DEFAULT_IP_PICKER, first).

%%

-spec resolve_url(url(), woody_state:st()) ->
    {ok, resolve_result()}    |
    {error, Reason :: atom()}.
resolve_url(Url, WoodyState) ->
    resolve_url(Url, WoodyState, #{}).

-spec resolve_url(url(), woody_state:st(), options()) ->
    {ok, resolve_result()}    |
    {error, Reason :: atom()}.
resolve_url(Url, WoodyState, Opts) when is_list(Url) ->
    resolve_url(unicode:characters_to_binary(Url), WoodyState, Opts);
resolve_url(<<"https://", _Rest/binary>> = Url, WoodyState, Opts) ->
    resolve_parsed_url(parse_url(Url), WoodyState, Opts);
resolve_url(<<"http://", _Rest/binary>> = Url, WoodyState, Opts) ->
    resolve_parsed_url(parse_url(Url), WoodyState, Opts);
resolve_url(Url, _WoodyState, _Opts) ->
    {error, {unsupported_url_scheme, Url}}.

%%

parse_url(Url) ->
    hackney_url:parse_url(Url).

resolve_parsed_url(ParsedUrl = #hackney_url{}, WoodyState, Opts) ->
    case inet:parse_address(ParsedUrl#hackney_url.host) of
        {ok, _} -> {ok, {ParsedUrl, ParsedUrl}}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl, WoodyState, Opts)
    end.

do_resolve_url(ParsedUrl, WoodyState, Opts) ->
    UnresolvedHost = ParsedUrl#hackney_url.host,
    _ = log_event(?EV_CLIENT_RESOLVE_BEGIN, WoodyState, #{host => UnresolvedHost}),
    case lookup_host(UnresolvedHost, Opts) of
        {ok, {IpAddr, _} = AddrInfo} ->
            _ = log_event(?EV_CLIENT_RESOLVE_RESULT, WoodyState, #{
                status => ok,
                host => UnresolvedHost,
                address => inet:ntoa(IpAddr)
            }),
            {ok, {ParsedUrl, replace_host(ParsedUrl, AddrInfo)}};
        {error, Reason} ->
            _ = log_event(?EV_CLIENT_RESOLVE_RESULT, WoodyState, #{
                status => error,
                host => UnresolvedHost,
                reason => Reason
            }),
            {error, Reason}
    end.

lookup_host(Host, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_RESOLVE_TIMEOUT),
    Deadline = woody_deadline:from_timeout(Timeout),
    IPFamilies = get_ip_family_preference(),
    lookup_host(Host, Opts, Deadline, IPFamilies).

lookup_host(Host, Opts, Deadline, [IPFamily | IPFamilies]) ->
    try
        Timeout = woody_deadline:to_timeout(Deadline),
        case inet:gethostbyname(Host, IPFamily, Timeout) of
            {ok, HostEnt} ->
                {ok, parse_hostent(HostEnt, Opts)};
            {error, nxdomain} ->
                lookup_host(Host, Opts, Deadline, IPFamilies);
            {error, Reason} ->
                {error, Reason}
        end
    catch
        error:deadline_reached ->
            {error, timeout}
    end;
lookup_host(_Host, _Opts, _Deadline, []) ->
    {error, nxdomain}.

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

get_ip(HostEnt, Opts) ->
    Picker = maps:get(ip_picker, Opts, ?DEFAULT_IP_PICKER),
    apply_ip_picker(Picker, HostEnt#hostent.h_addr_list).

apply_ip_picker(first, [Head | _Tail]) ->
    Head;
apply_ip_picker(random, AddrList) ->
    lists:nth(rand:uniform(length(AddrList)), AddrList);
apply_ip_picker({M, F}, AddrList) ->
    erlang:apply(M, F, [AddrList]).

get_ip_family(HostEnt) ->
    HostEnt#hostent.h_addrtype.

-spec get_ip_family_preference() ->
    [inet:address_family()].
get_ip_family_preference() ->
    case inet_db:res_option(inet6) of
        true -> [inet6, inet];
        false -> [inet, inet6]
    end.

%%

log_event(Event, WoodyState, ExtraMeta) ->
        woody_event_handler:handle_event(Event, WoodyState, ExtraMeta).
