-module(woody_resolver_eunit).

-include_lib("eunit/include/eunit.hrl").

resolve_ipv4_test() ->
    ?assertEqual(ok, inet_db:set_inet6(false)),
    ?assertEqual({ok, <<"http://127.0.0.1:80/test?q=a">>},
        woody_resolver:resolve_url(<<"http://localhost/test?q=a">>)),
    ?assertEqual({ok, <<"https://127.0.0.1:8080/test">>},
        woody_resolver:resolve_url(<<"https://localhost:8080/test">>)),
    ?assertEqual({ok, <<"https://127.0.0.1:443/">>},
        woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_ipv6_test() ->
    ?assertEqual(ok, inet_db:set_inet6(true)),
    ?assertEqual({ok, <<"http://[::1]:80/test">>},
        woody_resolver:resolve_url(<<"http://localhost/test">>)),
    ?assertEqual({ok, <<"http://[::1]:8080/test?q">>},
        woody_resolver:resolve_url(<<"http://localhost:8080/test?q">>)),
    ?assertEqual({ok, <<"https://[::1]:443/">>},
        woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_errors_test() ->
    ?assertEqual({error, nxdomain}, woody_resolver:resolve_url(<<"http://nxdomainme">>)),
    ?assertEqual({error, no_scheme}, woody_resolver:resolve_url(<<"localhost">>)).
