Woody [![wercker status](https://app.wercker.com/status/fd36dd241f6c38a784de7bcf7e3f4549/s "wercker status")](https://app.wercker.com/project/bykey/fd36dd241f6c38a784de7bcf7e3f4549)
======

Erlang реализация [Библиотеки RPC вызовов для общения между микросервисами](http://52.29.202.218/design/ms/platform/rpc-lib).

На текущий момент RPC реализован с помощью Thrift протокола поверх http.

## API

### Сервер

Получить _child_spec_ RPC сервера:

```erlang
1> EventHandler = my_event_handler.  %% реализует woody_event_handler behaviour
2> Service = {
2>     my_money_thrift, %% имя модуля, сгенерированного из money.thrift файла
2>     money %% имя thrift сервиса, заданное в money.thift
2> }.
3> ThriftHandler = my_money_thrift_service_handler.  %% реализует woody_server_thrift_handler behaviour
4> Opts = [].
5> Handlers = [{"/v1/thrift_money_service",{Service, ThriftHandler, Opts}}].
6> ServerSpec = woody_server:child_spec(money_service_sup, #{
6>     handlers => Handlers,
6>     event_handler => EventHandler,
6>     ip => {127,0,0,1},
6>     port => 8022,
6>     net_opts => []
6> }).
```

Теперь можно поднять RPC сервер в рамках supervision tree приложения. Например:

```erlang
7> {ok, _} = supervisor:start_child(MySup, ServerSpec).
```

### Клиент

Сделать синхронный RPC вызов:

```erlang
8> Url = <<"localhost:8022/v1/thrift_money_service">>.
9> Function = give_me_money.  %% thrift метод
10> Args = [100, <<"rub">>].
11> Request = {Service, Function, Args}.
12> Context = woody_client:new_context(<<"myUniqRequestID1">>, EventHandler).
13> {Result, _NextContext} = woody_client:call(Context, Request, #{url => Url}).
```

В случае вызова _thrift_ `oneway` функции (_thrift_ реализация _cast_) `woody_client:call/3` вернет `{ok, NextContext}`.

Если сервер бросает `Exception`, описанный в _.thrift_ файле сервиса, `woody_client:call/3` бросит это же исключение в виде: `throw:{{exception, Exception}, NextContext}`, а в случае ошибки RPC вызова: `error:{Reason, NextContext}`.

`woody_client:call_safe/3` - аналогична `call/3`, но в случае исключений, не бросает их, а возвращает в виде tuple: `{{exception | error, Error}, NextContext}` либо `{{error, Error, Stacktace}, NextContext}`.

```erlang
14> Args1 = [1000000, <<"usd">>].
15> Request1 = {Service, Function, Args1}.
16> Context1 = woody_client:new_context(<<"myUniqRequestID2">>, EventHandler).
17> {{exception, #take_it_easy{}}, _NextContext1} = woody_client:call_safe(Context1, Request1, #{url => Url}).
```

`woody_client:call_async/5` позволяет сделать call асинхронно и обработать результат в callback функции. `woody_client:call_async/5` требует также _sup_ref()_ для включения процесса, обрабатывающего RPC вызов, в supervision tree приложения.

```erlang
18> Callback = fun({Res, _NextContext2}) -> io:format("Rpc succeeded: ~p~n", [Res]);
18>     ({{exception, Error}, _NextContext2}) -> io:format("Service exception: ~p~n", [Error]);
18>     ({{error, _}, _NextContext2}) -> io:format("Rpc failed")
18> end.
19> Context2 = woody_client:new_context(<<"myUniqRequestID3">>, EventHandler).
20> {ok, Pid, _NextContext2} = woody_client:call_async(SupRef, Callback, Context2, Request, #{url => Url}).
```

Можно создать пул соединений для thrift клиента (например, для установления _keep alive_ соединений с сервером): `woody_client_thrift:start_pool/2` и затем использовать его при работе с `woody_client`:

```erlang
21> Pool = my_client_pool.
22> ok = woody_client_thrift:start_pool(Pool, 10).
23> Context3 = woody_client:new_context(<<"myUniqRequestID3">>, EventHandler).
24> {Result, _NextContext3} = woody_client:call(Context, Request, #{url => Url, pool => Pool}).
```

Закрыть пул можно с помошью `woody_client_thrift:stop_pool/1`.

### Woody Server Thrift Handler

```erlang
-module(my_money_thrift_service_handler).
-behaviour(woody_server_thrift_handler).

%% Auto-generated Thrift types from money.thrift
-include("my_money_thrift.hrl").

-export([handle_function/4]).

-spec handle_function(woody_t:func(), woody_server_thrift_handler:args(),
    woody_client:context(), woody_server_thrift_handler:handler_opts())
->
    {woody_server_thrift_handler:result(), woody_client:context()} | no_return().
handle_function(give_me_money, Sum = {Amount, Currency}, Context, _Opts) ->
    Wallet = <<"localhost:8022/v1/thrift_wallet_service">>,
    RequestLimits = {my_wallet_service, check_limits, Sum},

    %% RpcId можно получить из Context, полученного handle_function,
    %% для использования при логировании.
    RpcId = woody_client:get_rpc_id(Context),

    %% Используется Context, полученный handle_function.
    %% woody_client:new/2 вызывать не надо.
    case woody_client:call_safe(Context, RequestLimits, #{url => Wallet}) of
        {ok, Context1} ->

            %% Логи следует тэгировать RpcId.
            lager:info("[~p] giving away ~p ~p",
                [RpcId, Amount, Currency]),
            RequestMoney = {my_wallet_service, get_money, Sum},

            %% Используется новое значение Context1, полученное из предыдущего вызова
            %% woody_client:call_safe/3 (call/3, call_async/5).
            %% handle_function/4 должна возвращать текущий Context
            %% вместе с результатом обработки запроса. Таким образом,
            %% тут можно просто вернуть результат дочернего call.
            woody_client:call(Context1, RequestMoney, #{url => Wallet});
        {{exception, #over_limits{}}, Context1} ->
            lager:info("[~p] ~p ~p is too much",
                [RpcId, Amount, Currency]),
            %% Текущий контекст должен выбрасываться и вместе с thrift исключением.
            throw({#take_it_easy{}, Context1})
    end.
```

Показанное в этом наивном примере реализации сервиса `my_money` использование `Context` и `RpcId` необходимо для корректного логирования _RPC ID_ библиотекой, которое позволяет построить полное дерево RPC вызовов между микросервисами в рамках обработки бизнес сценария.

### Woody Event Handler

Интерфейс для получения и логирования событий RPC библиотеки.

```erlang
-module(my_event_handler).
-behaviour(woody_event_handler).

-export([handle_event/3]).

-spec handle_event(
    woody_event_handler:event_type(),
    woody_t:rpc_id(),
    woody_event_handler:event_meta_type()
) -> _.
handle_event(Event, RpcId, Meta) ->
    lager:info("[~p] woody event ~p: ~p", [RpcId, Event, Meta]).
```

