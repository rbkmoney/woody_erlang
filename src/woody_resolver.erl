-module(woody_resolver).

-include_lib("hackney/include/hackney_lib.hrl").
-include_lib("kernel/include/inet.hrl").

-export([resolve_url/1]).

-spec resolve_url(binary()) ->
    {ok, ResolvedUrl :: binary()} |
    {error, Reason :: atom()}.

resolve_url(Url) ->
    ParsedUrl = hackney_url:parse_url(Url),
    case inet_parse:address(ParsedUrl#hackney_url.host) of
        {ok, _} -> {ok, Url}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl)
    end.

do_resolve_url(ParsedUrl) ->
    case resolve_host(ParsedUrl#hackney_url.host) of
        {ok, ResolvedHost} ->
            {ok, reassemble_url(ParsedUrl, ResolvedHost)};
        {error, Reason} ->
            {error, Reason}
    end.

resolve_host(Host) ->
    case inet:gethostbyname(Host) of
        {ok, HostEnt} ->
            {ok, parse_hostent(HostEnt)};
        {error, _} ->
            {error, unable_to_resolve_host}
    end.

reassemble_url(ParsedUrl, {IpAddr, IpVer}) ->
    HostStr = inet:ntoa(IpAddr),
    %kind of a dirty method to make unparse_url work
    Netloc = encode_hackney_netloc(HostStr, ParsedUrl#hackney_url.port, IpVer),
    ResolvedUrl = ParsedUrl#hackney_url{netloc = Netloc, host = HostStr},
    hackney_url:unparse_url(ResolvedUrl).

encode_hackney_netloc(Host, Port, IpVer) ->
    BinHost = list_to_binary(Host),
    BinPort = integer_to_binary(Port),
    case IpVer of
         inet -> <<BinHost/binary, ":", BinPort/binary>>;
         inet6 -> <<"[", BinHost/binary, "]:", BinPort/binary>>
    end.

parse_hostent(HostEnt) ->
    {get_ip(HostEnt), get_ipver(HostEnt)}.

get_ip(HostEnt) ->
    AddrList = HostEnt#hostent.h_addr_list,
    lists:last(AddrList).

get_ipver(HostEnt) ->
    HostEnt#hostent.h_addrtype.