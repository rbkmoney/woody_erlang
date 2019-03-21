-module(woody_resolver_eunit).

-include_lib("eunit/include/eunit.hrl").
-include_lib("hackney/include/hackney_lib.hrl").

-define(
    RESPONSE(Scheme, Netloc, Path),
    #hackney_url{scheme = Scheme, netloc = Netloc, raw_path = Path}
).

resolve_ipv4_test() ->
    ok = inet_db:set_inet6(false),
    {ok, ?RESPONSE(http, <<"127.0.0.1:80">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://localhost/test">>),
    {ok, ?RESPONSE(http, <<"127.0.0.1:80">>, <<"/test?q=a">>)} =
        woody_resolver:resolve_url("http://localhost/test?q=a"),
    {ok, ?RESPONSE(https, <<"127.0.0.1:8080">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"https://localhost:8080/test">>),
    {ok, ?RESPONSE(https, <<"127.0.0.1:443">>, <<>>)} =
        woody_resolver:resolve_url(<<"https://localhost">>).

resolve_ipv6_test() ->
    ok = inet_db:set_inet6(true),
    {ok, ?RESPONSE(http, <<"[::1]:80">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"http://localhost/test">>),
    {ok, ?RESPONSE(http, <<"[::1]:80">>, <<"/test?q=a">>)} =
        woody_resolver:resolve_url("http://localhost/test?q=a"),
    {ok, ?RESPONSE(https, <<"[::1]:8080">>, <<"/test">>)} =
        woody_resolver:resolve_url(<<"https://localhost:8080/test">>),
    {ok, ?RESPONSE(https, <<"[::1]:443">>, <<>>)} =
        woody_resolver:resolve_url(<<"https://localhost">>).

resolve_errors_test() ->
    ?assertEqual({error, nxdomain}, woody_resolver:resolve_url(<<"http://nxdomainme">>)),
    ?assertEqual({error, unsupported_protocol}, woody_resolver:resolve_url(<<"ftp://localhost">>)).
