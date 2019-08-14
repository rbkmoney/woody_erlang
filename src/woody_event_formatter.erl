-module(woody_event_formatter).

-export([
    format_arg/2
]).

%% Binaries under size below will log as-is.
-define(MAX_BIN_LENGTH, 10).

-spec format_arg(term(), term()) ->
    woody_event_handler:msg().

format_arg(ArgType, Arg) ->
    format_(ArgType, Arg).

format_({_Fid, _Required, _Type, _Name, undefined}, undefined) ->
    {"", []};
format_({_Fid, _Required, _Type, Name, Default}, undefined) ->
    {"~s = ~p", [Name, Default]};
format_({_Fid, _Required, string, Name, _Default}, Value) ->
    {"~s = '~s'", [Name, Value]};
format_({_Fid, _Required, {struct, struct, {Module, Struct}}, Name, _Default}, Value) ->
    {StructFormat, StructParam} = format_struct(Module, Struct, Value),
    {"~s = " ++ StructFormat, [Name] ++ StructParam};
format_({_Fid, _Required, {struct, union, {Module, Struct}}, Name, _Default}, Value) ->
    {UnionFormat, UnionParam} = format_union(Module, Struct, Value),
    {"~s = " ++ UnionFormat, [Name] ++ UnionParam};
format_({_Fid, _Required, {struct, enum, {Module, Struct}}, Name, _Default}, Value) ->
    {"~s = ~s", [Name, format_enum(Module, Struct, Value)]};
format_({_Fid, _Required, {list, {struct, union, {Module, Struct}}}, Name, _Default}, ValueList) ->
    FormattedValueList =
        lists:foldr(
            fun(Value, FormattedAcc) ->
                [format_union(Module, Struct, Value) | FormattedAcc]
            end, [], ValueList),
    FormattedValue = string:join(FormattedValueList, ", "),
    {"~s = [~s]", [Name, FormattedValue]};
format_({_Fid, _Required, {list, {struct, struct, {Module, Struct}}}, Name, _Default}, ValueList) ->
    FormattedValueList =
        lists:foldr(
            fun(Value, FormattedAcc) ->
                [format_struct(Module, Struct, Value) | FormattedAcc]
            end, [], ValueList),
    FormattedValue = string:join(FormattedValueList, ", "),
    {"~s = [~s]", [Name, FormattedValue]};
format_({_Fid, _Required, {map, string, {struct, struct,{Module,Struct}}}, Name, _Default}, ValueMap) ->
    MapData = maps:to_list(ValueMap),
    Result =
        lists:foldr(
            fun({K, V}, Acc1) ->
                [io_lib:format("~s => ~s", [K, format_struct(Module, Struct, V)]) | Acc1]
            end,
            [], MapData
        ),
    FormattedResult = lists:flatten("#{",[string:join(Result, ", "), "}"]),
    {"~s = ~s", [Name, FormattedResult]};
format_({_Fid, _Required, _Type, Name, _Default}, Value) ->
    %% All other types such as i32, i64, bool, etc.
    {"~s = ~p", [Name, Value]};
format_(_Type, Value) ->
    %% All unknown types
    {"~p", [Value]}.

format_struct(Module, Struct, StructValue) ->
    {struct, struct, StructMeta} = Module:struct_info(Struct),
    case StructMeta of
        [] -> {"~s", [Struct]};
        StructMeta ->
            ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
            {Params, Values} = lists:foldr(
                fun({Type, Value}, {FAcc, PAcc} = Acc) ->
                    case format_(Type, Value) of
                        {"", []} ->
                            Acc;
                        {F, P} ->
                            {[F | FAcc], P ++ PAcc}
                    end
                end,
                {[],[]},
                lists:zip(StructMeta, ValueList)
            ),
            {"~s{" ++ string:join(Params, ", ") ++ "}", [Struct | Values]}
    end.

%% Filter and map Values direct to its value
format_union(_Module, 'Value', Value) ->
    format_value(Value);

format_union(Module, Struct, {Type, UnionValue}) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    case lists:keysearch(Type, 4, StructMeta) of
        {value, {_, _, {struct, struct, {M, S}}, _, _}} ->
            format_struct(M, S, UnionValue);
%%            case M:struct_info(S) of
%%                {struct, struct, []} -> atom_to_list(S);
%%                {struct, struct, UnionMeta} ->
%%                    ValueList = tl(tuple_to_list(UnionValue)), %% Remove record name
%%                    FormattedArgs = format_(UnionMeta, ValueList),
%%                    lists:flatten([atom_to_list(S), "{", string:join(lists:reverse(FormattedArgs), ", "), "}"])
%%            end;
        {value, {_, _, {list, {struct, union, {M, S}}}, Name, _}} ->
            {FormatParams, FormatValues} =
                lists:foldr(
                    fun(Value, {AF, AP}) ->
                        {F, P} = format_union(M, S, Value),
                        {[F | AF], P ++ AP}
                    end, {[],[]}, UnionValue),
            {"~s = [" ++ string:join(FormatParams, ", ") ++ "]", [Name, FormatValues]};
        {value, {_, _, {struct, union, {M, S}}, _, _}} ->
            format_union(M, S, UnionValue);
        {value, {_, _, string, Name, _}} when is_binary(UnionValue) ->
            {"~s{~s = '~s'}", [Struct, Name, UnionValue]};
        {value, {_, _, _Type, Name, _}} ->
            {"~s{~s = ~p}", [Struct, Name, UnionValue]}
    end.

format_enum(Module, Struct, {Type, EnumValue}) ->
    {struct, enum, StructMeta} = Module:struct_info(Struct),
    {value, {_, _, {struct, struct, {M, S}}, Name, _}} = lists:keysearch(Type, 4, StructMeta),
    {enum, EnumInfo} = M:enum_info(S),
    {value, {Value, _}} = lists:keysearch(EnumValue, 2, EnumInfo),
    io_lib:format("~s{~s = ~s}",[Struct,Name,Value]).

format_value({nl, _Null}) ->
    {"~s", ['Null']};
format_value({bin, Bin}) when size(Bin) =< ?MAX_BIN_LENGTH ->
    {"~p", [Bin]};
format_value({bin, _Bin}) ->
    {"~s", ["<<...>>"]};
format_value({i, N}) ->
    {"~p", [N]};
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
