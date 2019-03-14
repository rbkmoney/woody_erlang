-module(woody_resolver_eunit).

-include_lib("eunit/include/eunit.hrl").

resolve_ipv4_test() ->
    ?assertEqual(ok, inet_db:set_inet6(false)),
    ?assertEqual({ok, <<"http://127.0.0.1:80/test">>}, woody_resolver:resolve_url(<<"localhost/test">>)),
    ?assertEqual({ok, <<"http://127.0.0.1:80/test">>}, woody_resolver:resolve_url(<<"http://localhost/test">>)),
    ?assertEqual({ok, <<"https://127.0.0.1:8080/test">>}, woody_resolver:resolve_url(<<"https://localhost:8080/test">>)),
    ?assertEqual({ok, <<"https://127.0.0.1:443/">>}, woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_ipv6_test() ->
    ?assertEqual(ok, inet_db:set_inet6(true)),
    ?assertEqual({ok, <<"http://[::1]:80/test">>}, woody_resolver:resolve_url(<<"localhost/test">>)),
    ?assertEqual({ok, <<"http://[::1]:80/test">>}, woody_resolver:resolve_url(<<"http://localhost/test">>)),
    ?assertEqual({ok, <<"http://[::1]:8080/test?q">>}, woody_resolver:resolve_url(<<"http://localhost:8080/test?q">>)),
    ?assertEqual({ok, <<"https://[::1]:443/">>}, woody_resolver:resolve_url(<<"https://localhost">>)).

resolve_errors_test() ->
    ?assertEqual({error, unable_to_resolve_host}, woody_resolver:resolve_url(<<"http://nxdomainme">>)),
    %% hackney_url:parse_url just assumes any unrecognized url scheme to be http and ends up resolving something like
    %% http://ftp://localhost (hostname being ftp), which in turn nxdomains
    %% A fix for this would be to match for <<"http(s)://", _Rest/binary>> in resolve_url, but since I'm not certain
    %% about us relying on this logic in production (in tests we do by using 0.0.0.0/.., for example) I decided against it
    ?assertEqual({error, unable_to_resolve_host}, woody_resolver:resolve_url(<<"ftp://localhost">>)).
