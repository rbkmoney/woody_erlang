-module(woody_resolver_eunit).

-include_lib("eunit/include/eunit.hrl").

resolve_ipv4_test() ->
    ?assertEqual(ok, inet_db:set_inet6(false)),
    ?assertEqual(<<"http://127.0.0.1:80/">>, woody_resolver:resolve_url(<<"localhost">>)),
    ?assertEqual(<<"http://127.0.0.1:80/test">>, woody_resolver:resolve_url(<<"http://localhost/test">>)),
    ?assertEqual(<<"https://127.0.0.1:8080/test">>, woody_resolver:resolve_url(<<"https://localhost:8080/test">>)),
    ?assertEqual(<<"https://127.0.0.1:443/">>, woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_ipv6_test() ->
    ?assertEqual(ok, inet_db:set_inet6(true)),
    ?assertEqual(<<"http://[::1]:80/">>, woody_resolver:resolve_url(<<"localhost">>)),
    ?assertEqual(<<"http://[::1]:80/test">>, woody_resolver:resolve_url(<<"http://localhost/test">>)),
    ?assertEqual(<<"http://[::1]:8080/test?q">>, woody_resolver:resolve_url(<<"http://localhost:8080/test?q">>)),
    ?assertEqual(<<"https://[::1]:443/">>, woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_errors_test() ->
    ?assertError({badmatch, {error, nxdomain}}, woody_resolver:resolve_url(<<"ftp://localhost/test">>)).
