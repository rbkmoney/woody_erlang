-module(woody_event_formatter).

-export([
    format_call/4,
    format_reply/5
]).

%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 10).

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
            {"~s:~s(~p)", [Service, Function, Arguments]}
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
    {"~p", [Value]}.

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
            {"~p", [Value]}
    end;
format_reply(_Module, _Service, _Function, Kind, Result) ->
    {"~p", [{Kind, Result}]}.

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
format_thrift_value(string, << 131, _/binary >> = Value) ->
    %% BERT data always starts from 131
    %% so we can print'em as bytes safely
    format_non_printable_string(Value);
format_thrift_value(string, Value) when is_binary(Value) ->
    case is_printable(Value) of
        true ->
            {"'~s'", [Value]};
        false ->
            format_non_printable_string(Value)
    end;
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
    {"~p", [Value]}.

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
            {"~s{~p}", [ValueList]}
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
format_union(Module, Struct, {Type, UnionValue}) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    {value, UnionMeta} = lists:keysearch(Type, 4, StructMeta),
    {Format, Parameters} = format_argument(UnionMeta, UnionValue),
    {"~s{" ++ Format ++ "}", [Struct] ++ Parameters}.

format_non_printable_string(Value) ->
    case size(Value) =< ?MAX_BIN_SIZE of
        true ->
            {"~w", [Value]};
        false ->
            {"~s", ["<<...>>"]}
    end.

is_printable(Value) ->
    ValuePart =
        case size(Value)=< ?MAX_BIN_SIZE of
            true ->
                Value;
            false ->
                binary:part(Value, 0, ?MAX_BIN_SIZE)
        end,
    lists:all(
        fun(Byte) ->
            Byte > 31
        end,
        binary:bin_to_list(ValuePart)
    ).