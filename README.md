Woody [![wercker status](https://app.wercker.com/status/fd36dd241f6c38a784de7bcf7e3f4549/s "wercker status")](https://app.wercker.com/project/bykey/fd36dd241f6c38a784de7bcf7e3f4549)
======

Erlang реализация [Библиотеки RPC вызовов для общения между микросервисами](http://52.29.202.218/scrapyard/rpc-lib).

На текущий момент RPC реализован с помощью Thrift протокола поверх http.

## API

### Сервер

Получить _child_spec_ RPC сервера:

```erlang
1> EventHandler = my_event_handler.  %% реализует woody_event_handler behaviour
2> Service = my_money_service.  %% реализует thrift_service behaviour (генерируется из .thrift файла)
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
12> Client = woody_client:new(<<"myUniqRequestID1">>, EventHandler).
13> {{ok, Result}, _NextClient} = woody_client:call(Client, Request, #{url => Url}).
```

В случае вызова _thrift_ `oneway` функции (_thrift_ реализация _cast_), `woody_client:call/3` вернет `{ok, NextClient}`.

Если сервер бросает `Exception`, описанный в _.thrift_ файле сервиса, `woody_client:call/3` бросит это же исключение в виде: `throw:{{exception, Exception}, NextClient}`, а в случае ошибки RPC вызова: `error:{Reason, NextClient}`.

`woody_client:call_safe/3` - аналогична `call/3`, но в случае исключений, не бросает их, а возвращает в виде tuple: `{{exception | error, Error}, NextClient}` либо `{{error, Error, Stacktace}, NextClient}`.

```erlang
14> Args1 = [1000000, <<"usd">>].
15> Request1 = {Service, Function, Args1}.
16> Client1 = woody_client:new(<<"myUniqRequestID2">>, EventHandler).
17> {{exception, #take_it_easy{}}, _NextClient1} = woody_client:call_safe(Client1, Request1, #{url => Url}).
```

`woody_client:call_async/5` позволяет сделать call асинхронно и обработать результат в callback функции. `woody_client:call_async/5` требует также _sup_ref()_ для включения процесса, обрабатывающего RPC вызов, в supervision tree приложения.

```erlang
18> Callback = fun({{ok, Res}, _NextClient2}) -> io:format("Rpc succeeded: ~p~n", [Res]);
18>     ({{exception, Error}, _NextClient2}) -> io:format("Service exception: ~p~n", [Error]);
18>     ({{error, _} _NextClient2}) -> io:format("Rpc failed")
18>     ({{error, _, _} _NextClient2}) -> io:format("Rpc failed")
18> end.
19> Client2 = woody_client:new(<<"myUniqRequestID3">>, EventHandler).
20> {ok, Pid, _NextClient2} = woody_client:call_async(SupRef, Callback, Client2, Request, #{url => Url}).
```

Можно создать пул соединений для thrift клиента: `woody_client_thrift:start_pool/2` и затем использовать его при работе с `woody_client`:

```erlang
21> Pool = my_client_pool.
22> ok = woody_client_thrift:start_pool(Pool, 10).
23> Client3 = woody_client:new(<<"myUniqRequestID3">>, EventHandler).
24> {{ok, Result}, _NextClient3} = woody_client:call(Client, Request, #{url => Url, pool => Pool}).
```

Закрыть пул можно с помошью `woody_client_thrift:stop_pool/1`.

### Woody Server Thrift Handler

```erlang
-module(my_money_service).
-behaviour(woody_server_thrift_handler).

%% Auto-generated Thrift types for my_money_service
-include("my_money_types.hrl").

-export([handle_function/5, handle_error/5]).

-spec handle_function(woody_t:func(), woody_server_thrift_handler:args(),
    woody_t:rpc_id(), woody_client:client(), woody_server_thrift_handler:handler_opts())
->
    {ok, woody_server_thrift_handler:result()} |  no_return().
handle_function(give_me_money, Sum = {Amount, Currency}, RpcId, Client, _Opts) ->
    Wallet = <<"localhost:8022/v1/thrift_wallet_service">>,
    RequestLimits = {my_wallet_service, check_limits, Sum},

    %% Используется Client, полученный handle_function,
    %% woody_client:new/2 вызывать не надо.
    case woody_client:call(Client, RequestLimits, #{url => Wallet}) of
        {{ok, ok}, Client1} ->

            %% Логи следует тэгировать RpcId, полученным handle_function.
            lager:info("[~p] giving away ~p ~p",
                [my_event_handler:format_id(RpcId), Amount, Currency]),
            RequestMoney = {my_wallet_service, get_money, Sum},

            %% Используется новое значение Client1, полученное из предыдущего вызова
            %% woody_client:call/3 (call_safe/3, call_async/5).
            {{ok, Money}, _Client2} = woody_client:call_safe(Client1, RequestMoney,
                #{url => Wallet}),
            {ok, Money};
        {{ok, error}, _Client1} ->
            lager:info("[~p] ~p ~p is too much",
                [my_event_handler:format_id(RpcId), Amount, Currency]),
            throw(#take_it_easy{})
    end.

-spec handle_error(woody_t:func(), woody_server_thrift_handler:error_reason(),
    woody_t:rpc_id(), woody_client:client(), woody_server_thrift_handler:handler_opts())
-> _.
handle_error(give_me_money, Error, RpcId, _Client, _Opts) ->
    lager:info("[~p] got error from thrift: ~p",
        [my_event_handler:format_id(RpcId), Error]).
```

Показанное в этом наивном примере реализации `my_money_service` использование `Client` и `RpcId` необходимо для корректного логирования _RPC ID_ библиотекой, которое позволяет построить полное дерево RPC вызовов между микросервисами в рамках обработки бизнес сценария.
