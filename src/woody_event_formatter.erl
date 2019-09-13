-module(woody_event_formatter).

-export([
    format_call/4,
    format_reply/5,
    to_string/1
]).

-define(MAX_PRINTABLE_LIST_LENGTH, 3).
%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 10).

-type opts():: #{}.

-spec format_call(atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments) ->
    case Module:function_info(Service, Function, params_type) of
        {struct, struct, ArgTypes} ->
            {ArgsFormat, ArgsArgs} =
                format_call_(ArgTypes, Arguments, {[], []}, #{}),
            {"~s:~s(" ++ string:join(ArgsFormat, ", ") ++ ")", [Service, Function] ++ ArgsArgs};
        _Other ->
            {"~s:~s(~p)", [Service, Function, Arguments]}
    end.

format_call_([], [], Result, _Opts) ->
    Result;
format_call_([Type | RestType], [Argument | RestArgument], {AccFmt, AccParam}, Opts) ->
    case format_argument(Type, Argument, Opts) of
        {"", []} -> format_call_(RestType, RestArgument, {AccFmt, AccParam}, Opts);
        {Fmt, Param} -> format_call_(RestType, RestArgument, {AccFmt ++ [Fmt],  AccParam ++ Param}, Opts)
    end.

format_argument({_Fid, _Required, _Type, _Name, undefined}, undefined, _Opts) ->
    {"", []};
format_argument({_Fid, _Required, Type, Name, Default}, undefined, Opts) ->
    {Format, Params} = format_thrift_value(Type, Default, Opts),
    {"~s = " ++ Format, [Name] ++ Params};
format_argument({_Fid, _Required, Type, Name, _Default}, Value, Opts) ->
    {Format, Params} = format_thrift_value(Type, Value, Opts),
    {"~s = " ++ Format, [Name] ++ Params};
format_argument(_Type, Value, _Opts) ->
    %% All unknown types
    {"~p", [Value]}.

-spec format_reply(atom(), atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_reply(Module, Service, Function, Value, FormatAsException) ->
    format_reply(Module, Service, Function, Value, FormatAsException, #{}).

-spec format_reply(atom(), atom(), atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_reply(Module, Service, Function, Value, FormatAsException, Opts) when is_tuple(Value) ->
    try
        case FormatAsException of
            false ->
                ReplyType = Module:function_info(Service, Function, reply_type),
                format_thrift_value(ReplyType, Value, Opts);
            true ->
                {struct, struct, ExceptionTypeList} = Module:function_info(Service, Function, exceptions),
                Exception = element(1, Value),
                ExceptionType = get_exception_type(Exception, ExceptionTypeList),
                format_thrift_value(ExceptionType, Value, Opts)
        end
    catch
        _:_ ->
            {"~p", [Value]}
    end;
format_reply(_Module, _Service, _Function, Kind, Result, _Opts) ->
    {"~p", [{Kind, Result}]}.

-spec format_thrift_value(term(), term(), opts()) ->
    woody_event_handler:msg().
format_thrift_value({struct, struct, {Module, Struct}}, Value, Opts) ->
    format_struct(Module, Struct, Value, Opts);
format_thrift_value({struct, union, {Module, Struct}}, Value, Opts) ->
    format_union(Module, Struct, Value, Opts);
format_thrift_value({struct, exception, {Module, Struct}}, Value, Opts) ->
    format_struct(Module, Struct, Value, Opts);
format_thrift_value({enum, {_Module, _Struct}}, Value, _Opts) ->
    {to_string(Value), []};
format_thrift_value(string, Value, _Opts) when is_binary(Value) ->
    case is_printable(Value) of
        true ->
            {"'" ++ to_string(Value) ++ "'", []}; %% TODO UTF-8(?)
        false ->
            format_non_printable_string(Value)
    end;
format_thrift_value(string, Value, _Opts) ->
    {"'" ++ to_string(Value) ++ "'", []};
format_thrift_value({list, Type}, ValueList, Opts) when length(ValueList) =< ?MAX_PRINTABLE_LIST_LENGTH ->
    {Format, Params} =
        lists:foldr(
            fun(Entry, {FA, FP}) ->
                {F, P} = format_thrift_value(Type, Entry, Opts),
                {[F | FA], P ++ FP}
            end,
            {[], []},
            ValueList
        ),
    {"[" ++ string:join(Format, ", ") ++ "]", Params};
format_thrift_value({list, Type}, ValueList, Opts) ->
    FirstEntry = hd(ValueList),
    {FirstFormat, FirstParams} = format_thrift_value(Type, FirstEntry, Opts),
    LastEntry = hd(lists:reverse(ValueList)),
    {LastFormat, LastParams} = format_thrift_value(Type, LastEntry, Opts),
    SkippedLength = length(ValueList) - 2,
    {
            "[" ++ FirstFormat ++ ", ...skipped ~b entry(-ies)..., " ++ LastFormat ++ "]",
            FirstParams ++ [SkippedLength] ++ LastParams
    };
format_thrift_value({set, Type}, SetofValues, Opts) ->
    {Format, Params} =
        ordsets:fold(
            fun(Element, {AccFmt, AccParams}) ->
                {Fmt, Param} = format_thrift_value(Type, Element, Opts),
                {[Fmt | AccFmt], Param ++ AccParams}
            end,
            {[], []},
            SetofValues
        ),
    {"{" ++ Format ++ "}", Params};
format_thrift_value({map, KeyType, ValueType}, Map, Opts) ->
    MapData = maps:to_list(Map),
    {Params, Values} =
        lists:foldr(
            fun({Key, Value}, {AccFmt, AccParam}) ->
                {KeyFmt, KeyParam} = format_thrift_value(KeyType, Key, Opts),
                {ValueFmt, ValueParam} = format_thrift_value(ValueType, Value, Opts),
                EntryFormat = KeyFmt ++ " => " ++ ValueFmt,
                {[EntryFormat | AccFmt], KeyParam ++ ValueParam ++ AccParam}
            end,
            {[], []}, MapData
        ),
    {"#{" ++ string:join(Params, ", ") ++ "}", Values};
format_thrift_value(bool, false, _Opts) ->
    {"false", []};
format_thrift_value(bool, true, _Opts) ->
    {"true", []};
format_thrift_value(_Type, Value, _Opts) when is_integer(Value) ->
    {integer_to_list(Value), []};
format_thrift_value(_Type, Value, _Opts) when is_float(Value) ->
    {float_to_list(Value), []}.

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

-spec format_struct(atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_struct(Module, Struct, StructValue, Opts) ->
    %% struct and exception have same structure
    {struct, _, StructMeta} = Module:struct_info(Struct),
    ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
    case length(StructMeta) == length(ValueList) of
        true ->
            {Params, Values} =
                format_struct_(StructMeta, ValueList, {[], []}, Opts),
            {"~s{" ++ string:join(Params, ", ") ++ "}", [Struct | Values]};
        false ->
            {"~p", [StructValue]}
    end.

format_struct_([], [], Acc, _Opts) ->
    Acc;
format_struct_([Type | RestTypes], [Value | RestValues], {FAcc, PAcc} = Acc, Opts) ->
    case format_argument(Type, Value, Opts) of
        {"", []} ->
            format_struct_(RestTypes, RestValues, Acc, Opts);
        {F, P} ->
            format_struct_(RestTypes, RestValues, {FAcc ++ [F], PAcc ++ P}, Opts)
    end.

-spec format_union(atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_union(Module, Struct, {Type, UnionValue}, Opts) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    {value, UnionMeta} = lists:keysearch(Type, 4, StructMeta),
    {Format, Parameters} = format_argument(UnionMeta, UnionValue, Opts),
    {"~s{" ++ Format ++ "}", [Struct] ++ Parameters}.

format_non_printable_string(Value) ->
    case size(Value) =< ?MAX_BIN_SIZE of
        true ->
            {"~w", [Value]};
        false ->
            {"<<...>>", []}
    end.

is_printable(<<>>) ->
    true;
is_printable(Value) ->
    %% Try to get slice of first ?MAX_BIN_SIZE from Value,
    %% assuming success means Value is printable string
    %% NOTE: Empty result means non-printable Value
    try
        <<>> =/= string:slice(Value, 0, ?MAX_BIN_SIZE)
    catch
        _:_ ->
            %% Completely wrong binary data drives to crash in string internals,
            %% mark such data as non-printable instead
            false
    end.

-spec to_string(list() | binary() | atom()) -> list().
%% NOTE: Must match to supported types for `~s`
to_string(Value) when is_list(Value) ->
    Value;
to_string(Value) when is_binary(Value) ->
    binary_to_list(Value);
to_string(Value) when is_atom(Value) ->
    atom_to_list(Value);
to_string(_) ->
    error(badarg).
