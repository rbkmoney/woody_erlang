Woody [![Build Status](http://ci.rbkmoney.com/buildStatus/icon?job=rbkmoney_private/woody_erlang/master)](http://ci.rbkmoney.com/job/rbkmoney_private/view/Erlang/job/woody_erlang/job/master/)
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
5>     %% optional:
5>     %% transport_opts => woody_server_thrift_http_handler:transport_opts()
5>     %% protocol_opts  => cowboy_protocol:opts()
5>     %% handler_limits => woody_server_thrift_http_handler:handler_limits()
5> }).
```
С помощью опциональных полей можно:
* `transport_opts` - задать дополнительные опции для обработчика входящих соединений
* `protocol_opts` - задать дополнительные опции для обработчика http протокола сервера cowboy
* `handler_limits` - поставить лимиты на _heap size_ процесса хэндлера (_beam_ убьет хэндлер при превышении лимита - см. [erlang:process_flag(max_heap_size, MaxHeapSize)](http://erlang.org/doc/man/erlang.html#process_flag-2)) и на максимальный размер памяти vm (см. [erlang:memory(total)](http://erlang.org/doc/man/erlang.html#memory-1)), при достижении которого woody server начнет отбрасывать входящие rpc вызовы с системной ошибкой `internal resourse unavailable`.

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

Можно создать пул соединений для thrift клиента (например, для установления _keep alive_ соединений с сервером). Для этого надо использовать
`woody_client:child_spec/2`. Для работы с определенным пулом в Options есть поле `transport_opts => [{pool, pool_name}, {timeout, 150000}, {max_connections, 100}]`.

```erlang
15> Opts1 = Opts#{transport_opts => [{pool, my_client_pool}]}.
16> supervisor:start_child(Sup, woody_client:child_spec(Opts1)).
17> Context2 = woody_context:new(<<"myUniqRequestID2">>).
18> {ok, Result2} = woody_client:call(Request, Opts1, Context2).
```

`Context` позволяет аннотировать RPC запросы дополнительными мета данными в виде _key-value_. `Context` передается только в запросах и изменение мета данных возможно только в режиме _append-only_ (т.е. на попытку переопределить уже существующую запись в `context meta`, библиотека вернет ошибку). Поскольку на транспортном уровне контекст передается в виде custom HTTP заголовков, синтаксис метаданных _key-value_ должен следовать ограничениям [RFC7230 ](https://tools.ietf.org/html/rfc7230#section-3.2.6). Размер ключа записи метаданных не должен превышать _53 байта_ (см. остальные требования к метаданным в [описании библиотеки](http://coredocs.rbkmoney.com/design/ms/platform/rpc-lib/#rpc_2)).

```erlang
19> Meta1 = #{<<"client1-name">> => <<"Vasya">>}.
20> Context3 = woody_context:new(<<"myUniqRequestID3">>, Meta1).
21> Meta1 = woody_context:get_meta(Context3).
22> Meta2 = #{<<"client2-name">> => <<"Masha">>}.
23> Context4 = woody_context:add_meta(Context4, Meta2).
24> <<"Masha">> = woody_context:get_meta(<<"client2-name">>, Context4).
25> FullMeta = maps:merge(Meta1, Meta2).
26> FullMeta = woody_context:get_meta(Context4).
```

`Context` также позволяет задать [deadline](http://coredocs.rbkmoney.com/design/ms/platform/rpc-lib/#deadline) на исполнение запроса. Значение _deadline_ вложенных запросов можно менять произвольным образом. Также таймауты на запрос, [вычисляемые по deadline](src/woody_client_thrift_http_transport.erl), можно явно переопределить из приложения через _transport_opts_ в `woody_client:options()`. Модуль [woody_deadline](src/woody_deadline.erl) содержит API для работы с deadline.

```erlang
27> Deadline = {{{2017, 12, 31}, {23, 59, 59}}, 350}.
28> Context5 = woody_context:set_deadline(Deadline, Context4).
29> Context6 = woody_context:new(<<"myUniqRequestID6">>, undefined, Deadline).
30> Deadline = woody_context:get_deadline(Context5).
31> Deadline = woody_context:get_deadline(Context6).
32> true     = woody_deadline:is_reached(Deadline).
```

#### Кеширующий клиент

Для кеширования на стороне клиента можно иcпользовать обертку `woody_caching_client`. Она содержит в себе обычный `woody_client`, но кеширует результаты вызовов.

Дополнительно, `woody_caching_client` способен объединять одинаковые выполняющиеся параллельно запросы. Для включения этой функции необходимо указать в опциях `joint_control => joint`.

Перед использованием необходимо запустить служебные процессы, см `woody_caching_client:child_spec/2`.

### Woody Server Thrift Handler

```erlang
-module(my_money_thrift_service_handler).
-behaviour(woody_server_thrift_handler).

%% Auto-generated Thrift types from money.thrift
-include("my_money_thrift.hrl").

-export([handle_function/4]).

-spec handle_function(woody:func(), woody:args(), woody_context:ctx(), woody:options()) ->
    {ok, woody:result()} | no_return().
handle_function(give_me_money, Sum = [Amount, Currency], Context, _MyOpts) ->

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
Интерфейс для получения и логирования событий RPC библиотеки. Также содержит вспомогательные функции для удобного форматирования событий. Пример реализации _event handler_'а - [woody_event_handler_default.erl](src/woody_event_handler_default.erl).

### Tracing
Можно динамически включать и выключать трассировку http запросов и ответов.

На сервере:
```erlang
application:set_env(woody, trace_http_server, true).
application:unset_env(woody, trace_http_server).
```
