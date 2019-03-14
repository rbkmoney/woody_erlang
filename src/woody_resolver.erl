-module(woody_resolver).

-include_lib("hackney/include/hackney_lib.hrl").
-include_lib("kernel/include/inet.hrl").

-export([resolve_url/1]).

-spec resolve_url(http_uri:uri()) ->
    {ok, ResolvedUrl :: http_uri:uri()} |
    {error, Reason :: atom()}.

resolve_url(Url) when is_binary(Url) ->
    resolve_url(binary_to_list(Url));
resolve_url(Url) when is_list(Url) ->
    ParsedUrl = hackney_url:parse_url(Url),
    ResolvedUrl = case inet_parse:address(ParsedUrl#hackney_url.host) of
        {ok, _} -> ParsedUrl;
        {error, _} -> resolve(ParsedUrl)
    end,
    hackney_url:unparse_url(ResolvedUrl).

resolve(ParsedUrl) ->
    {ok, HostEnt} = inet:gethostbyname(ParsedUrl#hackney_url.host),
    ResolvedHost = inet:ntoa(get_ip(HostEnt)),
    %kind of a dirty method to make unparse_url work
    Netloc = encode_hackney_netloc(ResolvedHost, ParsedUrl#hackney_url.port, get_ipver(HostEnt)),
    ParsedUrl#hackney_url{netloc = Netloc, host = ResolvedHost}.

encode_hackney_netloc(Host, Port, IpVer) ->
    BinHost = list_to_binary(Host),
    BinPort = integer_to_binary(Port),
    case IpVer of
         inet -> <<BinHost/binary, ":", BinPort/binary>>;
         inet6 -> <<"[", BinHost/binary, "]:", BinPort/binary>>
    end.

get_ip(HostEnt) ->
    AddrList = HostEnt#hostent.h_addr_list,
    lists:last(AddrList).

get_ipver(HostEnt) ->
    HostEnt#hostent.h_addrtype.
