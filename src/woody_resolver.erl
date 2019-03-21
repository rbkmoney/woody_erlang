-module(woody_resolver).

-include_lib("kernel/include/inet.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-type url() :: binary() | parsed_url().
-type parsed_url() :: #hackney_url{}.

-type resolver_opts() :: #{
    ip_picker := {atom(), atom()},
    resolver_timeout => pos_integer(),
    resolver_retries => non_neg_integer()
}.

-export([resolve_url/1]).

-export([first_ip/1]).

-spec resolve_url(url()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.

resolve_url(Url) ->
    resolve_url(Url, #{
        ip_picker => {woody_resolver, first_ip}
    }).

-spec resolve_url(url(), resolver_opts()) ->
    {ok, ResolvedUrl :: parsed_url()} |
    {error, Reason :: atom()}.

resolve_url(ParsedUrl = #hackney_url{}, Opts) ->
    case inet:parse_address(ParsedUrl#hackney_url.host) of
        {ok, _} -> {ok, ParsedUrl}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl, Opts)
    end;
resolve_url(<<"https://", _Rest/binary>> = Url, Opts) ->
    resolve_url(parse_url(Url), Opts);
resolve_url(<<"http://", _Rest/binary>> = Url, Opts) ->
    resolve_url(parse_url(Url), Opts);
resolve_url(_Url, _Opts) ->
    {error, unsupported_protocol}.

parse_url(Url) ->
    hackney_url:parse_url(Url).

do_resolve_url(ParsedUrl, Opts) ->
    case resolve_host(ParsedUrl#hackney_url.host, Opts) of
        {ok, AddrInfo} ->
            {ok, replace_host(ParsedUrl, AddrInfo)};
        {error, Reason} ->
            {error, Reason}
    end.

resolve_host(Host, Opts) ->
    inet_db:set_timeout(maps:get(resolver_timeout, Opts, 2)),
    inet_db:set_retry(maps:get(resolver_retries, Opts, 3)),
    case inet:gethostbyname(Host) of
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

first_ip([Ip | _]) ->
    Ip.