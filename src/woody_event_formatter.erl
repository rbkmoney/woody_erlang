-module(woody_event_formatter).

-export([
    format_arg/2,
    format_struct/3,
    format_union/3,
    format_list/2
]).

%% Binaries under size below will log as-is.
-define(MAX_BIN_LENGTH, 10).

-spec format_arg(term(), term()) ->
    woody_event_handler:msg().
format_arg(ArgType, Arg) ->
    format_(ArgType, Arg, "~s = ", "").

format_({_Fid, _Required, _Type, _Name, undefined}, undefined, _FmtP, _FmtS) ->
    {"", []};
format_({_Fid, _Required, _Type, Name, Default}, undefined, FmtP, FmtS) ->
    {FmtP ++ "~p" ++ FmtS, [Name, Default]};
format_({_Fid, _Required, string, Name, _Default}, Value, FmtP, FmtS) ->
    {FmtP ++ "'~s'" ++ FmtS, [Name, Value]};
format_({_Fid, _Required, {struct, struct, {Module, Struct}}, Name, _Default}, Value, FmtP, FmtS) ->
    {StructFormat, StructParam} = format_struct(Module, Struct, Value),
    {FmtP ++ StructFormat ++ FmtS, [Name] ++ StructParam};
format_({_Fid, _Required, {struct, union, {Module, Struct}}, Name, _Default}, Value, FmtP, FmtS) ->
    {UnionFormat, UnionParam} = format_union(Module, Struct, Value),
    {FmtP ++ UnionFormat ++ FmtS, [Name] ++ UnionParam};
format_({_Fid, _Required, {enum, {_Module, _Struct}}, Name, _Default}, Value, FmtP, FmtS) ->
    {FmtP ++ "~s" ++ FmtS, [Name, Value]};
format_({_Fid, _Required, {list, {struct, union, {Module, Struct}}}, Name, _Default}, ValueList, FmtP, FmtS) ->
    {UnionFormat, UnionParam} = format_list_(Module, Struct, ValueList, fun format_union/3),
    {FmtP ++ UnionFormat ++ FmtS, [Name] ++ UnionParam};
format_({_Fid, _Required, {list, {struct, struct, {Module, Struct}}}, Name, _Default}, ValueList, FmtP, FmtS) ->
    {StructFormat, StructParam} = format_list_(Module, Struct, ValueList, fun format_struct/3),
    {FmtP ++ StructFormat ++ FmtS, [Name] ++ StructParam};
format_({_Fid, _Required, {map, string, {struct, struct, {Module, Struct}}}, Name, _Default}, ValueMap, FmtP, FmtS) ->
    MapData = maps:to_list(ValueMap),
    {Params, Values} =
        lists:foldr(
            fun({K, V}, {FmtAcc, ParamAcc}) ->
                {Fmt, Param} = format_struct(Module, Struct, V),
                {["~s => " ++ Fmt | FmtAcc], [K] ++ Param ++ ParamAcc}
            end,
            {[], []}, MapData
        ),
    {FmtP ++ "#{" ++ string:join(Params, ", ") ++ "}" ++ FmtS, [Name] ++ Values};
format_({_Fid, _Required, _Type, Name, _Default}, Value, FmtP, FmtS) ->
    %% All other types such as i32, i64, bool, etc.
    {FmtP ++ "~p" ++ FmtS, [Name, Value]};
format_(_Type, Value, _FmtP, _FmtS) ->
    %% All unknown types
    {"~p", [Value]}.

-spec format_struct(atom(), atom(), term()) ->
    woody_event_handler:msg().
format_struct(Module, Struct, StructValue) ->
    {struct, struct, StructMeta} = Module:struct_info(Struct),
    ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
    {Params, Values} = lists:foldr(
        fun format_struct_/2,
        {[], []},
        lists:zip(StructMeta, ValueList)
    ),
    {"~s{" ++ string:join(Params, ", ") ++ "}", [Struct | Values]}.

format_struct_({Type, Value}, {FAcc, PAcc} = Acc) ->
    case format_(Type, Value, "~s = ", "") of
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
    {Format, Parameters} = format_(UnionMeta, UnionValue, "~s = ", ""),
    {"~s{" ++ Format ++ "}", [Struct] ++ Parameters}.

-spec format_list(term(), [term()]) ->
    woody_event_handler:msg().
format_list(_, []) ->
    {"", []};
format_list({struct, struct, {Module, Struct}}, ValueList) ->
    format_list_(Module, Struct, ValueList, fun format_struct/3);
format_list({struct, union, {Module, Struct}}, ValueList) ->
    format_list_(Module, Struct, ValueList, fun format_union/3).

format_list_(Module, Struct, ValueList, FormatStructFun) ->
    {StructFormat, StructParam} =
        lists:foldr(
            fun(Value, {FmtAcc, ParamAcc}) ->
                {Fmt, Params} = FormatStructFun(Module, Struct, Value),
                {[Fmt | FmtAcc], Params ++ ParamAcc}
            end, {[], []}, ValueList),
    {"[" ++ string:join(StructFormat, ", ") ++ "]", StructParam}.

format_value({nl, _Null}) ->
    {"~s", ['Null']};
format_value({b, Boolean}) ->
    {"~s", [Boolean]};
format_value({bin, Bin}) when size(Bin) =< ?MAX_BIN_LENGTH ->
    {"~p", [Bin]};
format_value({bin, _Bin}) ->
    {"~s", ["<<...>>"]};
format_value({i, N}) ->
    {"~p", [N]};
format_value({flt, F}) ->
    {"~p", [F]};
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
    {"[" ++ string:join(Params, ", ") ++ "]", Values}.
