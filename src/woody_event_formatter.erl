-module(woody_event_formatter).

-export([
    format_call/4,
    format_reply/5
]).

%% Binaries under size below will log as-is.
-define(MAX_BIN_LENGTH, 10).

-spec format_call(atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments) ->
    case Module:function_info(Service, Function, params_type) of
        {struct, struct, ArgTypes} ->
            {ArgsFormat, ArgsArgs} =
                lists:foldr(
                    fun format_call_/2,
                    {[], []},
                    lists:zip(ArgTypes, Arguments)
                ),
            {"~s:~s(" ++ string:join(ArgsFormat, ", ") ++ ")", [Service, Function] ++ ArgsArgs};
        _Other ->
            {"~s:~s(~w)", [Service, Function, Arguments]}
    end.

format_call_({Type, Argument}, {AccFmt, AccParam}) ->
    case format_argument(Type, Argument) of
        {"", []} -> {AccFmt, AccParam};
        {Fmt, Param} -> {[Fmt | AccFmt], Param ++ AccParam}
    end.

format_argument({_Fid, _Required, _Type, _Name, undefined}, undefined) ->
    {"", []};
format_argument({_Fid, _Required, Type, Name, Default}, undefined) ->
    {Format, Params} = format_thrift_value(Type, Default),
    {"~s = " ++ Format, [Name] ++ Params};
format_argument({_Fid, _Required, Type, Name, _Default}, Value) ->
    {Format, Params} = format_thrift_value(Type, Value),
    {"~s = " ++ Format, [Name] ++ Params};
format_argument(_Type, Value) ->
    %% All unknown types
    {"~w", [Value]}.

-spec format_reply(atom(), atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_reply(Module, Service, Function, Value, FormatAsException) when is_tuple(Value) ->
    try
        case FormatAsException of
            false ->
                ReplyType = Module:function_info(Service, Function, reply_type),
                format_thrift_value(ReplyType, Value);
            true ->
                {struct, struct, ExceptionTypeList} = Module:function_info(Service, Function, exceptions),
                Exception = element(1, Value),
                ExceptionType = get_exception_type(Exception, ExceptionTypeList),
                format_thrift_value(ExceptionType, Value)
        end
    catch
        _:_ ->
            {"~w", [Value]}
    end;
format_reply(_Module, _Service, _Function, Kind, Result) ->
    {"~w", [{Kind, Result}]}.

-spec format_thrift_value(term(), term()) ->
    woody_event_handler:msg().
format_thrift_value({struct, struct, {Module, Struct}}, Value) ->
    format_struct(Module, Struct, Value);
format_thrift_value({struct, union, {Module, Struct}}, Value) ->
    format_union(Module, Struct, Value);
format_thrift_value({struct, exception, {Module, Struct}}, Value) ->
    format_struct(Module, Struct, Value);
format_thrift_value({enum, {_Module, _Struct}}, Value) ->
    {"~s", [Value]};
format_thrift_value(string, Value) ->
    {"'~s'", [Value]};
format_thrift_value({list, Type}, ValueList) ->
    {Format, Params} =
        lists:foldr(
            fun(Entry, {FA, FP}) ->
                {F, P} = format_thrift_value(Type, Entry),
                {[F | FA], P ++ FP}
            end,
            {[], []},
            ValueList
        ),
    {"[" ++ string:join(Format, ", ") ++ "]", Params};
format_thrift_value({set, Type}, SetofValues) ->
    {Format, Params} =
        ordsets:fold(
            fun(Element, {AccFmt, AccParams}) ->
                {Fmt, Param} = format_thrift_value(Type, Element),
                {[Fmt | AccFmt], Param ++ AccParams}
            end,
            {[], []},
            SetofValues
        ),
    {"{" ++ Format ++ "}", Params};
format_thrift_value({map, KeyType, ValueType}, Map) ->
    MapData = maps:to_list(Map),
    {Params, Values} =
        lists:foldr(
            fun({Key, Value}, {AccFmt, AccParam}) ->
                {KeyFmt, KeyParam} = format_thrift_value(KeyType, Key),
                {ValueFmt, ValueParam} = format_thrift_value(ValueType, Value),
                EntryFormat = KeyFmt ++ " => " ++ ValueFmt,
                {[EntryFormat | AccFmt], KeyParam ++ ValueParam ++ AccParam}
            end,
            {[], []}, MapData
        ),
    {"#{" ++ string:join(Params, ", ") ++ "}", Values};
format_thrift_value(_Type, Value) ->
    %% bool, double, i8, i16, i32, i64 formats here
    {"~w", [Value]}.

get_exception_type(ExceptionRecord, ExceptionTypeList) ->
    [ExceptionType] =
        lists:filtermap(
            fun ({_, _, Type = {struct, exception, {Module, Exception}}, _, _}) ->
                case Module:record_name(Exception) of
                    ExceptionRecord -> {true, Type};
                    _ -> false
                end
            end,
            ExceptionTypeList
        ),
    ExceptionType.

-spec format_struct(atom(), atom(), term()) ->
    woody_event_handler:msg().
format_struct(Module, Struct, StructValue) ->
    %% struct and exception have same structure
    {struct, _, StructMeta} = Module:struct_info(Struct),
    ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
    case length(StructMeta) == length(ValueList) of
        true ->
            {Params, Values} = lists:foldr(
                fun format_struct_/2,
                {[], []},
                lists:zip(StructMeta, ValueList)
            ),
            {"~s{" ++ string:join(Params, ", ") ++ "}", [Struct | Values]};
        false ->
            {"~s{~w}", [ValueList]}
    end.

format_struct_({Type, Value}, {FAcc, PAcc} = Acc) ->
    case format_argument(Type, Value) of
        {"", []} ->
            Acc;
        {F, P} ->
            {[F | FAcc], P ++ PAcc}
    end.

-spec format_union(atom(), atom(), term()) ->
    woody_event_handler:msg().
%% Filter and map Values direct to its value
format_union(_Module, 'Value', Value) ->
    format_value(Value);

format_union(Module, Struct, {Type, UnionValue}) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    {value, UnionMeta} = lists:keysearch(Type, 4, StructMeta),
    {Format, Parameters} = format_argument(UnionMeta, UnionValue),
    {"~s{" ++ Format ++ "}", [Struct] ++ Parameters}.

format_value({nl, _Null}) ->
    {"~s", ['Null']};
format_value({b, Boolean}) ->
    {"~s", [Boolean]};
format_value({bin, Bin}) when size(Bin) =< ?MAX_BIN_LENGTH ->
    {"~w", [Bin]};
format_value({bin, _Bin}) ->
    {"~s", ["<<...>>"]};
format_value({i, N}) ->
    {"~w", [N]};
format_value({flt, F}) ->
    {"~w", [F]};
format_value({str, S}) ->
    {"'~s'", [S]};
format_value({obj, S}) ->
    ObjData = maps:to_list(S),
    {Params, Values} =
        lists:foldr(
            fun({K, V}, {FmtAcc, ParamAcc}) ->
                {KeyFmt, KeyParam} = format_value(K),
                {ValueFmt, ValueParam} = format_value(V),
                {[KeyFmt ++ " => " ++ ValueFmt | FmtAcc], KeyParam ++ ValueParam ++ ParamAcc}
            end,
            {[], []}, ObjData
        ),
    {"#{" ++ string:join(Params, ", ") ++ "}", Values};
format_value({arr, List}) ->
    {Params, Values} =
        lists:foldr(
            fun(Entry, {FmtAcc, ParamAcc}) ->
                {Fmt, Param} = format_value(Entry),
                {[Fmt | FmtAcc], Param ++ ParamAcc}
            end,
            {[], []}, List
        ),
    {"[" ++ string:join(Params, ", ") ++ "]", Values};
format_value(O) ->
    {"~w", [O]}.