-module(woody_resolver).

-include_lib("kernel/include/inet.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-type url() :: binary() | nonempty_string().
-type parsed_url() :: #hackney_url{}.

-type resolver_opts() :: #{
    ip_picker := {atom(), atom()},
    timeout := pos_integer() | infinity
}.

-export([resolve_url/1]).

-export([first_ip/1]).

-spec resolve_url(url()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.

resolve_url(Url) ->
    resolve_url(Url, #{
        ip_picker => {woody_resolver, first_ip},
        timeout => infinity
    }).

-spec resolve_url(url(), resolver_opts()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.

resolve_url(Url, Opts) when is_list(Url) ->
    resolve_url(list_to_binary(Url), Opts);
resolve_url(<<"https://", _Rest/binary>> = Url, Opts) ->
    resolve_parsed_url(parse_url(Url), Opts);
resolve_url(<<"http://", _Rest/binary>> = Url, Opts) ->
    resolve_parsed_url(parse_url(Url), Opts);
resolve_url(_Url, _Opts) ->
    {error, unsupported_protocol}.

parse_url(Url) ->
    hackney_url:parse_url(Url).

resolve_parsed_url(ParsedUrl = #hackney_url{}, Opts) ->
    case inet:parse_address(ParsedUrl#hackney_url.host) of
        {ok, _} -> {ok, ParsedUrl}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl, Opts)
    end.

do_resolve_url(ParsedUrl, Opts) ->
    case lookup_host(ParsedUrl#hackney_url.host, Opts) of
        {ok, AddrInfo} ->
            {ok, replace_host(ParsedUrl, AddrInfo)};
        {error, Reason} ->
            {error, Reason}
    end.

lookup_host(Host, #{timeout := Timeout} = Opts) ->
    case inet:gethostbyname(Host, get_preferred_ip_family(), Timeout) of
        {ok, HostEnt} ->
            {ok, parse_hostent(HostEnt, Opts)};
        {error, Reason} ->
            {error, Reason}
    end.

replace_host(ParsedUrl, {IpAddr, IpVer}) ->
    HostStr = inet:ntoa(IpAddr),
    Netloc = encode_netloc(HostStr, IpVer, ParsedUrl#hackney_url.port),
    ParsedUrl#hackney_url{netloc = Netloc, host = HostStr}.

encode_netloc(HostStr, IpVer, Port) ->
    BinHost = list_to_binary(HostStr),
    BinPort = integer_to_binary(Port),
    case IpVer of
        inet -> <<BinHost/binary, ":", BinPort/binary>>;
        inet6 -> <<"[", BinHost/binary, "]:", BinPort/binary>>
    end.

parse_hostent(HostEnt, Opts) ->
    {get_ip(HostEnt, Opts), get_ipver(HostEnt)}.

get_ip(HostEnt, #{ip_picker := {M, F}}) ->
    erlang:apply(M, F, [HostEnt#hostent.h_addr_list]).

get_ipver(HostEnt) ->
    HostEnt#hostent.h_addrtype.

get_preferred_ip_family() ->
    case inet_db:res_option(inet6) of
        true -> inet6;
        false -> inet
    end.

first_ip([Ip | _]) ->
    Ip.