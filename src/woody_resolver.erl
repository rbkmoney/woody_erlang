-module(woody_resolver).

-include_lib("kernel/include/inet.hrl").

-record(woody_url, {
    scheme :: atom(),
    user_info :: string(),
    host :: string(),
    port :: integer(),
    path :: string(),
    query :: string()
}).

-type resolver_opts() :: #{
    ip_selector_fun := function()
}.

-export([resolve_url/1]).

-spec resolve_url(binary()) ->
    {ok, ResolvedUrl :: binary()} |
    {error, Reason :: atom()}.

resolve_url(Url) ->
    resolve_url(Url, #{
        ip_selector_fun => fun first_ip/1
    }).

-spec resolve_url(binary(), resolver_opts()) ->
    {ok, ResolvedUrl :: binary()} |
    {error, Reason :: atom()}.

resolve_url(Url, Opts) ->
    case parse_url(Url) of
        {ok, ParsedUrl} ->
            resolve_url(ParsedUrl, Url, Opts);
        {error, Reason} ->
            {error, Reason}
    end.

resolve_url(ParsedUrl = #woody_url{}, Url, Opts) ->
    case inet:parse_address(ParsedUrl#woody_url.host) of
        {ok, _} -> {ok, Url}; % url host is already an ip, move on
        {error, _} -> do_resolve_url(ParsedUrl, Opts)
    end.

parse_url(Url) ->
    case http_uri:parse(binary_to_list(Url)) of
        {ok, {Scheme, UserInfo, Host, Port, Path, Query}} ->
            {ok, #woody_url{
                scheme = Scheme,
                user_info = UserInfo,
                host = Host,
                port = Port,
                path = Path,
                query = Query
            }};
        {error, Reason} ->
            {error, Reason}
    end.

do_resolve_url(ParsedUrl, Opts) ->
    case resolve_host(ParsedUrl#woody_url.host, Opts) of
        {ok, ResolvedHost} ->
            {ok, reassemble_url(ParsedUrl, ResolvedHost)};
        {error, Reason} ->
            {error, Reason}
    end.

resolve_host(Host, Opts) ->
    case inet:gethostbyname(Host) of
        {ok, HostEnt} ->
            {ok, parse_hostent(HostEnt, Opts)};
        {error, Reason} ->
            {error, Reason}
    end.

reassemble_url(ParsedUrl, {IpAddr, IpVer}) ->
    BinScheme = encode_scheme(ParsedUrl#woody_url.scheme),
    BinUserInfo = encode_userinfo(ParsedUrl#woody_url.user_info),
    BinHost = list_to_binary(inet:ntoa(IpAddr)),
    BinPort = integer_to_binary(ParsedUrl#woody_url.port),
    BinPath = list_to_binary(ParsedUrl#woody_url.path),
    BinQuery = list_to_binary(ParsedUrl#woody_url.query),
    Netloc = case IpVer of
        inet -> <<BinHost/binary, ":", BinPort/binary>>;
        inet6 -> <<"[", BinHost/binary, "]:", BinPort/binary>>
    end,
    <<BinScheme/binary, BinUserInfo/binary, Netloc/binary,
        BinPath/binary, BinQuery/binary>>.

encode_scheme(Scheme) ->
    BinScheme = atom_to_binary(Scheme, utf8),
    <<BinScheme/binary, "://">>.

encode_userinfo([]) ->
    <<>>;
encode_userinfo(UserInfo) ->
    BinUserInfo = list_to_binary(UserInfo),
    <<BinUserInfo/binary, "@">>.

parse_hostent(HostEnt, Opts) ->
    {get_ip(HostEnt, Opts), get_ipver(HostEnt)}.

get_ip(HostEnt, #{ip_selector_fun := SelFun}) ->
    SelFun(HostEnt#hostent.h_addr_list).

get_ipver(HostEnt) ->
    HostEnt#hostent.h_addrtype.

first_ip([Ip | _]) ->
    Ip.