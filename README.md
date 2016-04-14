# rpc

Erlang реализация [Библиотеки RPC вызовов для общения между микросервисами](http://52.29.202.218/scrapyard/rpc-lib/).

На текущий момент RPC реализован с помощью Thrift протокола поверх http.

## API

### Сервер

Получить _child_spec_ RPC сервера:

```erlang
1> EventHandler = my_event_handler.  %% реализует rpc_event_handler behaviour
2> Service = money_service.  %% имя модуля, описывающего thrift сервис
3> ThriftHandler = thrift_money_service_handler.  %% реализует rpc_thrift_handler behaviour
4> NetOpts = [].
5> Handlers = [{"/v1/thrift_money_service",{Service, ThriftHandler, NetOpts}}].
6> ServerSpec = rpc_server:child_spec(money_service_sup, #{
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
12> Client = rpc_client:new(<<"myUniqRequestID1">>, EventHandler).
13> {ok, Result, _NextClient} = rpc_client:call(Client, Request, #{url => Url}).
```

В случае, когда сервер бросает Exception, описанный в _.thrift_ файле сервиса,
`rpc_client:call/3` бросит это же исключение в виде: `throw:{Exception, NextClient}`, а в случае неудачи RPC вызова: `error:{rpc_failed, NextClient}`.

`rpc_client:call_safe/3` - аналогична `call/3`, но в случае исключений, не бросает их, а возвращает в виде tuple: `{Class, Error, NextClient}`.

```erlang
14> Args1 = [1000000, <<"usd">>].
15> Request1 = {Service, Function, Args1}.
16> Client1 = rpc_client:new(<<"myUniqRequestID2">>, EventHandler).
17> {throw, #take_it_easy{}, _NextClient1} = rpc_client:call_safe(Client1, Request1, #{url => Url}).
```

`rpc_client:call_async/5` позволяет сделать call асинхронно и обработать результат в callback функции. `rpc_client:call_async/5` требует также _sup_ref()_ для включения процесса, обрабатывающего RPC вызов, в supervision tree приложения.

```erlang
18> Callback = fun({ok, Res, _NextClient2}) -> io:format("Rpc succeeded: ~p~n", [Res]);
18>     ({throw, Error, _NextClient2}) -> io:format("Service exception: ~p~n", [Error]);
18>     ({error, rpc_failed, _NextClient2}) -> io:format("Rpc failed")
18> end.
19> Client2 = rpc_client:new(<<"myUniqRequestID3">>, EventHandler).
20> {ok, Pid, _NextClient2} = rpc_client:call_async(SupRef, Callback, Client2, Request, #{url => Url}).
```

Можно создать пул коннектов для thrift клиента: `rpc_thrift_client:start_pool/2` и затем использовать его при работе с `rpc_client`:

```erlang
21> Pool = my_client_pool.
22> ok = rpc_thrift_client:start_pool(Pool, 10).
23> Client3 = rpc_client:new(<<"myUniqRequestID3">>, EventHandler).
24> {ok, Result, _NextClient3} = rpc_client:call(Client, Request, #{url => Url, pool => Pool}).
```

Закрыть пул можно с помошью `rpc_thrift_client:stop_pool/1`.

### Важно!

В предыдущих примерах новый thrift клиент `Client` создаётся с помощью `rpc_client:new/2` перед каждым RPC вызовом. В реальном микросервисе, использующем эту библиотеку, в большинстве случаев RPC вызов будет результатом обработки внешнего RPC вызова к этому микросервису. В таком случае `Client` будет получен в рамках `ThriftHandler:handle_function/4` на стороне RPC сервера. Это значение `Client` надо использовать при первом call вызове `rpc_client` API (т.е. вызывать `rpc_client:new/2` не надо). Полученный в результате `NextClient` следует передать в следующий API вызов `rpc_client` и.т.д. Это необходимо, для корректного логирования _RPC ID_ библиотекой, которое позволяет построить полное дерево RPC вызовов между микросервисами в рамках обработки бизнес сценария.
