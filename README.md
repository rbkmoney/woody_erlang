Woody [![wercker status](https://app.wercker.com/status/fd36dd241f6c38a784de7bcf7e3f4549/s "wercker status")](https://app.wercker.com/project/bykey/fd36dd241f6c38a784de7bcf7e3f4549)
======

Erlang реализация [Библиотеки RPC вызовов для общения между микросервисами](http://coredocs.rbkmoney.com/design/ms/platform/rpc-lib/)

версия требований: __ac4d40cc22d649d03369fcd52fb1230e51cdf52e__

## API

### Сервер
Получить _child_spec_ RPC сервера:

```erlang
1> EventHandler = my_event_handler.  %% | {my_event_handler, MyEventHandlerOpts :: term()}. woody_event_handler behaviour
2> Service = {
2>     my_money_thrift, %% имя модуля, сгенерированного из money.thrift файла
2>     money %% имя thrift сервиса, заданное в money.thift
2> }.
3> ThriftHandler = my_money_thrift_service_handler.  %% | {my_money_thrift_service_handler, MyHandlerOpts :: term()}. woody_server_thrift_handler behaviour
4> Handlers = [{"/v1/thrift_money_service",{Service, ThriftHandler}}].
5> ServerSpec = woody_server:child_spec(money_service_sup, #{
5>     handlers => Handlers,
5>     event_handler => EventHandler,
5>     ip => {127,0,0,1},
5>     port => 8022
5>      %% + optional woody_server_thrift_http_handler:net_opts()
5> }).
```

Теперь можно поднять RPC сервер в рамках supervision tree приложения. Например:

```erlang
6> {ok, _} = supervisor:start_child(MySup, ServerSpec).
```

### Клиент
Сделать синхронный RPC вызов:

```erlang
7> Url = <<"localhost:8022/v1/thrift_money_service">>.
8> Function = give_me_money.  %% thrift метод
9> Args = [100, <<"rub">>].
10> Request = {Service, Function, Args}.
11> ClientEventHandler = {my_event_handler, MyCustomOptions}.
12> Context1 = woody_context:new(<<"myUniqRequestID1">>).
13> Opts = #{url => Url, event_handler => ClientEventHandler}.
14> {ok, Result1} = woody_client:call(Request, Opts, Context1).
```

В случае вызова _thrift_ `oneway` функции (_thrift_ реализация _cast_) `woody_client:call/3` вернет `{ok, ok}`.

Если сервер бросает `Exception`, описанный в _.thrift_ файле сервиса (т.е. _Бизнес ошибку_ в [терминологии](http://coredocs.rbkmoney.com/design/ms/platform/overview/#_7) макросервис платформы), `woody_client:call/3` вернет это исключение в виде: `{exception, Exception}`.

В случае получения _Системной_ ошибки клиент выбрасывает _erlang:error_ типа `{woody_error, woody_error:system_error()}`.

`woody_context:new/0` - можно использовать для создания контекста корневого запроса с автоматически сгенерированным уникальным RPC ID.

Можно создать пул соединений для thrift клиента (например, для установления _keep alive_ соединений с сервером): `woody_client_thrift:start_pool/2` и затем использовать его при работе с `woody_client`:

```erlang
15> Pool = my_client_pool.
16> ok = woody_client_thrift:start_pool(Pool, 10).
17> Context2 = woody_context:new(<<"myUniqRequestID2">>).
18> {ok, Result2} = woody_client:call(Request, Opts, Context2).
```

Закрыть пул можно с помошью `woody_client_thrift:stop_pool/1`.

`Context` также позволяет аннотировать RPC запросы дополнительными мета данными в виде _key-value_. `Context` передается только в запросах и его расширение возможно только в режиме _append-only_ (т.е. на попытку переопределить уже существующую запись в `context meta`, библиотека вернет ошибку). Поскольку на транспортном уровне контекст передается в виде custom HTTP заголовков, синтаксис _key-value_ должен следовать ограничениям [RFC7230 ](https://tools.ietf.org/html/rfc7230#section-3.2.6). Размер ключа записи метаданных не должен превышать _53 байта_ (см. остальные требования к метаданным в [описании библиотеки](http://coredocs.rbkmoney.com/design/ms/platform/rpc-lib/#rpc_2)).

```erlang
19> Meta1 = #{<<"client1-name">> => <<"Vasya">>}.
20> Context3 = woody_context:new(<<"myUniqRequestID4">>, Meta1).
21> Meta1 = woody_context:get_meta(Context3).
22> Meta2 = #{<<"client2-name">> => <<"Masha">>}.
23> Context4 = woody_context:add_meta(Context4, Meta2).
24> <<"Masha">> = woody_context:get_meta(<<"client2-name">>, Context4).
25> FullMeta = maps:merge(Meta1, Meta2).
26> FullMeta = woody_context:get_meta(Context4).
```

### Woody Server Thrift Handler

```erlang
-module(my_money_thrift_service_handler).
-behaviour(woody_server_thrift_handler).

%% Auto-generated Thrift types from money.thrift
-include("my_money_thrift.hrl").

-export([handle_function/4]).

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().
handle_function(give_me_money, Sum = {Amount, Currency}, Context, _MyOpts) ->

    %% RpcId можно получить из Context, полученного handle_function,
    %% для использования при логировании.
    RpcId = woody_context:get_rpc_id(Context),

    case check_loan_limits(Sum, Context, 5) of
        {ok, ok} ->

            %% Логи рекомендуется тэгировать RpcId.
            lager:info("[~p] giving away ~p ~p", [RpcId, Amount, Currency]),
            RequestMoney = {my_wallet_service, get_money, Sum},

            %% Используется значение Context, полученное из родительского вызова
            Opts = #{url => wallet, event_handler => woody_event_handler_default},
            Meta = #{<<"approved">> => <<"true">>},
            woody_client:call(RequestMoney, Opts, woody_context:add_meta(Context, Meta));
        {ok, not_approved} ->
            lager:info("[~p] ~p ~p is too much", [RpcId, Amount, Currency]),

            %% Thrift исключения выбрасываются через woody_error:raise/2 с тэгом business.
            woody_error:raise(business, #take_it_easy{})
    end.

check_loan_limits(_Limits, _Context, 0) ->

    %% Системные ошибки выбрасываются с помощью woody_error:raise/2 с тэгом system.
    woody_error:raise(system, {external, result_unknown, <<"limit checking service">>});
check_loan_limits(Limits, Context, N) ->
    Wallet = <<"localhost:8022/v1/thrift_wallet_service">>,
    RequestLimits = {my_wallet_service, check_limits, Limits},

    %% Используется Context, полученный handle_function.
    %% woody_context:new() вызывать не надо.
    Opts = #{url => Wallet, event_handler => woody_event_handler_default},
    try woody_client:call(RequestLimits, Opts, Context) of
        {ok, ok} -> {ok, approved};
        {exception, #over_limits{}} -> {ok, not_approved}
    catch
        %% Transient error
        error:{woody_error, {external, result_unknown, Details}} ->
            lager:info("Received transient error ~p", [Details]),
            check_loan_limits(Limits, Context, N - 1)
    end.
```

### Woody Event Handler
Интерфейс для получения и логирования событий RPC библиотеки. Пример реализации _event handler_'а - [woody_event_handler_default.erl](src/woody_event_handler_default.erl).
