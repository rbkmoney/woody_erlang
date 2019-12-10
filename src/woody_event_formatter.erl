-module(woody_event_formatter).

-export([
    format_call/4,
    format_call/5,
    format_reply/5,
    format_exception/5,
    to_string/1
]).

-define(MAX_PRINTABLE_LIST_LENGTH, 3).
%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 10).

-type opts():: #{
    max_depth  => integer(),
    max_length => integer(),
    max_pritable_string_length => non_neg_integer()
}.

-export_type([opts/0]).

-spec format_call(atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments) ->
    ConfigOpts = genlib_app:env(woody, event_formatter_options, #{}),
    format_call(Module, Service, Function, Arguments, ConfigOpts).

-spec format_call(atom(), atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments, Opts) ->
    case Module:function_info(Service, Function, params_type) of
        {struct, struct, ArgTypes} ->
            Opts1 = normalize_options(Opts),
            ServiceName = to_string(Service),
            ServiceLength = length(ServiceName),
            FunctionName = to_string(Function),
            FunctionLength = length(FunctionName),
            NewCL = ServiceLength + FunctionLength + 3,
            {Result, _} =
                format_call_(ArgTypes, Arguments, "", 0, NewCL, Opts1, false),
            {"~s:~s(~ts)", [ServiceName, FunctionName, Result]};
        _Other ->
            {"~s:~s(~tp)", [Service, Function, Arguments]}
    end.

format_call_([], [], Result, _CurDepth, CL, _Opts, _AddDelimiter) ->
    {Result, CL};
format_call_(_, ArgumentList, Result, _CurDepth, CL, #{max_length := ML}, AddDelimiter) when ML >= 0, CL > ML ->
    HasMoreArguments = AddDelimiter and ArgumentList =/= [],
    Delimiter = maybe_add_delimiter(HasMoreArguments),
    DelimiterLen = length(Delimiter),
    MoreArguments = maybe_add_more_marker(HasMoreArguments),
    MoreArgumentsLen = length(MoreArguments),
    {[Result | [Delimiter, MoreArguments]], CL + DelimiterLen + MoreArgumentsLen};
format_call_([Type | RestType], [Argument | RestArgs], Acc, CurDepth, CL, Opts, AddDelimiter) ->
    Delimiter = maybe_add_delimiter(AddDelimiter),
    DelimiterLen = length(Delimiter),
    case format_argument(Type, Argument, CurDepth, CL + DelimiterLen, Opts) of
        {undefined, NewCL} ->
            format_call_(
                RestType,
                RestArgs,
                Acc,
                CurDepth,
                NewCL,
                Opts,
                AddDelimiter
            );
        {Result, NewCL} ->
            format_call_(
                RestType,
                RestArgs,
                [Acc | [Delimiter, Result]],
                CurDepth,
                NewCL + DelimiterLen,
                Opts,
                true
            )
    end.

format_argument({_Fid, _Required, _Type, _Name, undefined}, undefined, _CurDepth, CL, _Opts) ->
    {undefined, CL};
format_argument({Fid, Required, Type, Name, Default}, undefined, CurDepth, CL, Opts) ->
    format_argument({Fid, Required, Type, Name, Default}, Default, CurDepth, CL, Opts);
format_argument({_Fid, _Required, Type, Name, _Default}, Value, CurDepth, CL, Opts) ->
    NameStr = to_string(Name),
    NameStrLen = length(NameStr),
    {Format, NewCL} = format_thrift_value(Type, Value, CurDepth, CL + NameStrLen + 3, Opts),
    {[NameStr, " = ", Format], NewCL}.

-spec format_reply(atom(), atom(), atom(), term(), woody:options()) ->
    woody_event_handler:msg().
format_reply(Module, Service, Function, Value, Opts) ->
    ReplyType = Module:function_info(Service, Function, reply_type),
    format(ReplyType, Value, normalize_options(Opts)).

-spec format_exception(atom(), atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_exception(Module, Service, Function, Value, Opts) when is_tuple(Value) ->
    {struct, struct, ExceptionTypeList} = Module:function_info(Service, Function, exceptions),
    Exception = element(1, Value),
    ReplyType = get_exception_type(Exception, ExceptionTypeList),
    format(ReplyType, Value, normalize_options(Opts));
format_exception(_Module, _Service, _Function, Value, Opts) ->
    #{max_length := ML} = normalize_options(Opts),
    {"~ts", [io_lib:format("~0tp", [Value], [{chars_limit, ML}])]}.

format(ReplyType, Value, #{max_length := ML} = Opts) ->
    try
        {ReplyFmt, _} = format_thrift_value(ReplyType, Value, 0, 0, Opts),
        {"~ts", [ReplyFmt]}
    catch
        E:R:S ->
            WarningDetails = genlib_format:format_exception({E, R, S}),
            logger:warning("EVENT FORMATTER ERROR: ~tp", [WarningDetails]),
            {"~ts", [io_lib:format("~0tp", [Value], [{chars_limit, ML}])]}
    end.

-spec format_thrift_value(term(), term(), non_neg_integer(), non_neg_integer(), opts()) ->
    {iolist(), non_neg_integer()}.
format_thrift_value({struct, struct, []}, Value, _CurDepth, CL, Opts) ->
    %% {struct,struct,[]} === thrift's void
    %% so just return Value
    #{max_length := ML} = normalize_options(Opts),
    ValueString = io_lib:format("~0tp", [Value], [{chars_limit, ML}]),
    Length = length(ValueString),
    {ValueString, CL + Length};
format_thrift_value({struct, struct, {Module, Struct}}, Value, CurDepth, CL, Opts) ->
    format_struct(Module, Struct, Value, CurDepth + 1, CL, Opts);
format_thrift_value({struct, union, {Module, Struct}}, Value, CurDepth, CL, Opts) ->
    format_union(Module, Struct, Value, CurDepth + 1, CL, Opts);
format_thrift_value({struct, exception, {Module, Struct}}, Value, CurDepth, CL, Opts) ->
    format_struct(Module, Struct, Value, CurDepth + 1, CL, Opts);
format_thrift_value({enum, {_Module, _Struct}}, Value, _CurDepth, CL, _Opts) ->
    ValueString = to_string(Value),
    Length = length(ValueString),
    {ValueString, CL + Length};
format_thrift_value(string, Value, _CurDepth, CL, Opts) when is_binary(Value) ->
    case is_printable(Value, Opts) of
        true ->
            ValueString = value_to_string(Value),
            Length = length(ValueString),
            {["'", ValueString, "'"], CL + Length + 2}; %% 2 = length("''")
        false ->
            Fmt = format_non_printable_string(Value),
            Length = length(Fmt),
            {Fmt, CL + Length}
    end;
format_thrift_value(string, Value, _CurDepth, CL, _Opts) ->
    ValueString = value_to_string(Value),
    Length = length(ValueString),
    {["'", ValueString, "'"], CL + Length + 2}; %% 2 = length("''")
format_thrift_value({list, _}, _, CurDepth, CL, #{max_depth := MD})
    when MD >= 0, CurDepth >= MD ->
    {"[...]", CL + 5}; %% 5 = length("[...]")
format_thrift_value({list, Type}, ValueList, CurDepth, CL, Opts) ->
    {Format, CL1} = format_thrift_list(Type, ValueList, CurDepth + 1, CL + 2, Opts),
    {["[", Format, "]"], CL1};
format_thrift_value({set, _}, _, CurDepth, CL, #{max_depth := MD})
    when MD >= 0, CurDepth >= MD ->
    {"{...}", CL + 5}; %% 5 = length("{...}")
format_thrift_value({set, Type}, SetofValues, CurDepth, CL, Opts) ->
    {Format, CL1} = format_thrift_set(Type, SetofValues, CurDepth + 1, CL + 2, Opts),
    {["{", Format, "}"], CL1};
format_thrift_value({map, _}, _, CurDepth, CL, #{max_depth := MD})
    when MD >= 0, CurDepth >= MD ->
    {"#{...}", CL + 6}; %% 6 = length("#{...}")
format_thrift_value({map, KeyType, ValueType}, Map, CurDepth, CL, Opts) ->
    {Params, CL1} =
        format_map(KeyType, ValueType, Map, "", CurDepth + 1, CL + 3, Opts, false),
    {["#{", Params, "}"], CL1};
format_thrift_value(bool, false, _CurDepth, CL, _Opts) ->
    {"false", CL + 5};
format_thrift_value(bool, true, _CurDepth, CL, _Opts) ->
    {"true", CL + 4};
format_thrift_value(_Type, Value, _CurDepth, CL, _Opts) when is_integer(Value) ->
    ValueStr = integer_to_list(Value),
    Length = length(ValueStr),
    {ValueStr, CL + Length};
format_thrift_value(_Type, Value, _CurDepth, CL, _Opts) when is_float(Value) ->
    ValueStr = float_to_list(Value),
    Length = length(ValueStr),
    {ValueStr, CL + Length}.

format_thrift_list(Type, ValueList, CurDepth, CL, Opts) when length(ValueList) =< ?MAX_PRINTABLE_LIST_LENGTH ->
    format_list(Type, ValueList, "", CurDepth, CL, Opts, false);
format_thrift_list(Type, OriginalValueList, CurDepth, CL, #{max_length := ML} = Opts) ->
    FirstEntry = hd(OriginalValueList),
    LastEntry = lists:last(OriginalValueList),
    {FirstEntryFmt, FirstEntryCL} =
        format_thrift_value(Type, FirstEntry, CurDepth, CL, Opts),
    case FirstEntryCL < ML orelse ML < 0 of
        true ->
            SkippedLength = length(OriginalValueList) - 2,
            SkippedMsg = io_lib:format("...~b more...", [SkippedLength]),
            SkippedMsgLength = length(SkippedMsg),
            case FirstEntryCL + SkippedMsgLength + 2 < ML orelse ML < 0 of
                true ->
                    {LastEntryFmt, LastEntryCL} =
                        format_thrift_value(Type, LastEntry, CurDepth, FirstEntryCL + SkippedMsgLength + 4, Opts),
                    format_list_result(
                        LastEntryCL < ML orelse ML < 0,
                        [FirstEntryFmt, ", ", SkippedMsg, ", ", LastEntryFmt],
                        LastEntryCL,
                        [FirstEntryFmt, ", ..."],
                        FirstEntryCL + 5
                    );
                false ->
                    {[FirstEntryFmt, ", ..."], FirstEntryCL + 5}
            end;
        false ->
            {[FirstEntryFmt, ", ..."], FirstEntryCL + 5}
    end.

format_list_result(true, Fmt, CL, _, _) ->
    {Fmt, CL};
format_list_result(false, _, _, Fmt, CL) ->
    {Fmt, CL + 5}.

format_thrift_set(Type, SetofValues, CurDepth, CL, Opts) ->
    %% Actually ordsets is a list so leave this implementation as-is
    ValueList = ordsets:to_list(SetofValues),
    format_list(Type, ValueList, "", CurDepth, CL, Opts, false).

get_exception_type(ExceptionRecord, ExceptionTypeList) ->
    Result =
        lists:filtermap(
            fun ({_, _, Type = {struct, exception, {Module, Exception}}, _, _}) ->
                case Module:record_name(Exception) of
                    ExceptionRecord -> {true, Type};
                    _ -> false
                end
            end,
            ExceptionTypeList
        ),
    case Result of
        [ExceptionType] ->
            ExceptionType;
        [] ->
            undefined
    end.

-spec format_struct(atom(), atom(), term(), non_neg_integer(), non_neg_integer(), opts()) ->
    {iolist(), non_neg_integer()}.
format_struct(_Module, Struct, _StructValue, CurDepth, CL, #{max_depth := MD})
    when MD >= 0, CurDepth > MD ->
    {[to_string(Struct), "{...}"], CL + 5}; %% 5 = length("{...}")
format_struct(Module, Struct, StructValue, CurDepth, CL, Opts = #{max_length := ML}) ->
    %% struct and exception have same structure
    {struct, _, StructMeta} = Module:struct_info(Struct),
    ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
    case length(StructMeta) == length(ValueList) of
        true ->
            StructName = to_string(Struct),
            StructNameLength = length(StructName),
            {Params, NewCL} =
                format_struct_(
                    StructMeta,
                    ValueList,
                    "",
                    CurDepth + 1,
                    CL + StructNameLength + 2,
                    Opts,
                    false
                ),
            {[StructName, "{", Params, "}"], NewCL};
        false ->
            Length = get_length(ML, CL),
            Params = io_lib:format("~p", [StructValue], [{chars_limit, Length}]),
            {Params, CL + Length}
    end.

format_struct_([], [], Acc, _CurDepth, CL, _Opts, _AddDelimiter) ->
    {Acc, CL};
format_struct_(_Types, _Values, Result, _CurDepth, CL, #{max_length := ML}, AddDelimiter)
    when ML >= 0, CL > ML->
    Delimiter = maybe_add_delimiter(AddDelimiter),
    DelimiterLen = length(Delimiter),
    {[Result, Delimiter, "..."], CL + 3 + DelimiterLen};
format_struct_([Type | RestTypes], [Value | RestValues], Acc, CurDepth, CL, Opts, AddDelimiter) ->
    case format_argument(Type, Value, CurDepth, CL, Opts) of
        {undefined, CL} ->
            format_struct_(
                RestTypes,
                RestValues,
                Acc,
                CurDepth,
                CL,
                Opts,
                AddDelimiter
            );
        {F, CL1} ->
            Delimiter = maybe_add_delimiter(AddDelimiter),
            DelimiterLen = length(Delimiter),
            format_struct_(
                RestTypes,
                RestValues,
                [Acc | [Delimiter, F]],
                CurDepth, CL1 + DelimiterLen,
                Opts,
                true
            )
    end.

-spec format_union(atom(), atom(), term(), non_neg_integer(), non_neg_integer(), opts()) ->
    {iolist(), non_neg_integer()}.
format_union(_Module, Struct, _StructValue, CurDepth, CL, #{max_depth := MD})
    when MD >= 0, CurDepth > MD ->
    {[to_string(Struct), "{...}"], CL + 5}; %% 5 = length("{...}"
format_union(Module, Struct, {Type, UnionValue}, CurDepth, CL, Opts) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    {value, UnionMeta} = lists:keysearch(Type, 4, StructMeta),
    StructName = to_string(Struct),
    StructNameLen = length(StructName),
    {Argument, CL1} = format_argument(
        UnionMeta,
        UnionValue,
        CurDepth,
        CL + StructNameLen + 2,
        Opts
    ), %% 2 = length("{}")
    {[StructName, "{", Argument, "}"], CL1}.

format_non_printable_string(Value) ->
    Size = byte_size(Value),
    ["<<", integer_to_list(Size), " bytes>>"].

is_printable(<<>>, _Opts) ->
    true;
is_printable(Value, #{max_pritable_string_length := MPSL}) ->
    %% Try to get slice of first ?MAX_BIN_SIZE from Value,
    %% assuming success means Value is printable string
    %% NOTE: Empty result means non-printable Value
    try
        <<>> =/= string:slice(Value, 0, MPSL)
    catch
        _:_ ->
            %% Completely wrong binary data drives to crash in string internals,
            %% mark such data as non-printable instead
            false
    end.

-spec value_to_string(list() | binary() | atom()) -> list().
value_to_string(S) ->
    [maybe_escape(C) || C <- to_string(S)].

maybe_escape($') ->
    [$\\, $'];
maybe_escape(C) ->
    C.

-spec to_string(list() | binary() | atom()) -> list().
%% NOTE: Must match to supported types for `~s`
to_string(Value) when is_list(Value) ->
    Value;
to_string(Value) when is_binary(Value) ->
    unicode:characters_to_list(Value);
to_string(Value) when is_atom(Value) ->
    atom_to_list(Value);
to_string(_) ->
    error(badarg).

normalize_options(Opts) ->
    maps:merge(#{
        max_depth => -1,
        max_length => -1,
        max_pritable_string_length => ?MAX_BIN_SIZE
    }, Opts).

maybe_add_delimiter(false) ->
    "";
maybe_add_delimiter(true) ->
    ", ".

maybe_add_more_marker(false) ->
    "";
maybe_add_more_marker(true) ->
    "...".

get_length(ML, CL) when ML > CL ->
    ML - CL;
get_length(_ML, _CL) ->
    0.

format_list(_Type, [], Result, _CurDepth, CL, _Opts, _IsFirst) ->
    {Result, CL};
format_list(Type, [Entry | ValueList], AccFmt, CurDepth, CL, Opts, IsFirst) ->
    #{max_length := ML} = Opts,
    Delimiter = maybe_add_delimiter(IsFirst),
    DelimiterLen = length(Delimiter),
    {Fmt, CL1} = format_thrift_value(Type, Entry, CurDepth, CL + DelimiterLen, Opts),
    Result = [AccFmt | [Delimiter, Fmt]],
    case CL1 of
        CL1 when ML < 0 ->
            format_list(Type, ValueList, Result, CurDepth, CL1, Opts, true);
        CL1 when CL1 =< ML ->
            format_list(Type, ValueList, Result, CurDepth, CL1, Opts, true);
        CL1 ->
            MaybeAddMoreMarker = length(ValueList) =/= 0,
            stop_format(Result, CL1, MaybeAddMoreMarker)
    end.

format_map(_KeyType, _ValueType, E, Result, _CurDepth, CL, _Opts, _AddDelimiter) when map_size(E) =:= 0 ->
    {Result, CL};
format_map(KeyType, ValueType, Map, AccFmt, CurDepth, CL, Opts, AddDelimiter) ->
    MapIterator = maps:iterator(Map),
    format_map_(KeyType, ValueType, maps:next(MapIterator), AccFmt, CurDepth, CL, Opts, AddDelimiter).

format_map_(KeyType, ValueType, {Key, Value, MapIterator}, AccFmt, CurDepth, CL, Opts, AddDelimiter) ->
    {KeyFmt, CL1} = format_thrift_value(KeyType, Key, CurDepth, CL, Opts),
    {ValueFmt, CL2} = format_thrift_value(ValueType, Value, CurDepth, CL1, Opts),
    #{max_length := ML} = Opts,
    MapStr = " => ",
    MapStrLen = 4,
    Delimiter = maybe_add_delimiter(AddDelimiter),
    DelimiterLen = length(Delimiter),
    NewCL = CL2 + MapStrLen + DelimiterLen,
    Result = [AccFmt | [Delimiter, KeyFmt, MapStr, ValueFmt]],
    Next = maps:next(MapIterator),
    case NewCL of
        NewCL when ML < 0 ->
            format_map_(KeyType, ValueType, Next, Result, CurDepth, NewCL, Opts, true);
        NewCL when NewCL =< ML ->
            format_map_(KeyType, ValueType, Next, Result, CurDepth, NewCL, Opts, true);
        NewCL ->
            MaybeAddMoreMarker = Next =/= none,
            stop_format(Result, NewCL, MaybeAddMoreMarker)
    end;
format_map_(_, _, _, AccFmt, _, CL, _, _) ->
    {AccFmt, CL}.

stop_format(Result, CL1, MaybeAddMoreMarker) ->
    Delimiter1 = maybe_add_delimiter(MaybeAddMoreMarker),
    DelimiterLen1 = length(Delimiter1),
    MoreMarker = maybe_add_more_marker(MaybeAddMoreMarker),
    MoreMarkerLen = length(MoreMarker),
    {
        [Result | [Delimiter1, MoreMarker]],
        CL1 + MoreMarkerLen + DelimiterLen1
    }.

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-spec test() -> _.

-define(ARGS, [undefined, <<"1CR1Xziml7o">>,
    [{contract_modification,
        {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
            {creation,
                {payproc_ContractParams, undefined,
                    {domain_ContractTemplateRef, 1},
                    {domain_PaymentInstitutionRef, 1},
                    {legal_entity,
                        {russian_legal_entity,
                            {domain_RussianLegalEntity, <<"Hoofs & Horns OJSC">>,
                                <<"1234509876">>, <<"1213456789012">>,
                                <<"Nezahualcoyotl 109 Piso 8, O'Centro, 06082, MEXICO">>, <<"NaN">>,
                                <<"Director">>, <<"Someone">>, <<"100$ banknote">>,
                                {domain_RussianBankAccount, <<"4276300010908312893">>,
                                    <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}}}}}},
        {contract_modification,
            {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
                {payout_tool_modification,
                    {payproc_PayoutToolModificationUnit, <<"1CR1Y2ZcrA1">>,
                        {creation,
                            {payproc_PayoutToolParams,
                                {domain_CurrencyRef, <<"RUB">>},
                                {russian_bank_account,
                                    {domain_RussianBankAccount, <<"4276300010908312893">>,
                                        <<"SomeBank">>, <<"123129876">>, <<"66642666">>}}}}}}}},
        {shop_modification,
            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                {creation,
                    {payproc_ShopParams,
                        {domain_CategoryRef, 1},
                        {url, <<>>},
                        {domain_ShopDetails, <<"Battle Ready Shop">>, undefined},
                        <<"1CR1Y2ZcrA0">>, <<"1CR1Y2ZcrA1">>}}}},
        {shop_modification,
            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                {shop_account_creation,
                    {payproc_ShopAccountParams, {domain_CurrencyRef, <<"RUB">>}}}}}]
]).

-define(ARGS2, [{mg_stateproc_CallArgs,
    {bin,
        <<131, 104, 4, 100, 0, 11, 116, 104, 114, 105, 102, 116, 95, 99, 97, 108, 108,
            100, 0, 16, 112, 97, 114, 116, 121, 95, 109, 97, 110, 97, 103, 101, 109, 101,
            110, 116, 104, 2, 100, 0, 15, 80, 97, 114, 116, 121, 77, 97, 110, 97, 103,
            101, 109, 101, 110, 116, 100, 0, 11, 67, 114, 101, 97, 116, 101, 67, 108, 97,
            105, 109, 109, 0, 0, 2, 145, 11, 0, 2, 0, 0, 0, 11, 49, 67, 83, 72, 84, 104, 84,
            69, 74, 56, 52, 15, 0, 3, 12, 0, 0, 0, 4, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67,
            83, 72, 84, 106, 75, 108, 51, 52, 75, 12, 0, 2, 12, 0, 1, 12, 0, 2, 8, 0, 1, 0, 0,
            0, 1, 0, 12, 0, 3, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 1, 12, 0, 1, 12, 0, 1, 11, 0, 1, 0, 0,
            0, 18, 72, 111, 111, 102, 115, 32, 38, 32, 72, 111, 114, 110, 115, 32, 79, 74,
            83, 67, 11, 0, 2, 0, 0, 0, 10, 49, 50, 51, 52, 53, 48, 57, 56, 55, 54, 11, 0, 3, 0,
            0, 0, 13, 49, 50, 49, 51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 11, 0, 4, 0, 0, 0,
            48, 78, 101, 122, 97, 104, 117, 97, 108, 99, 111, 121, 111, 116, 108, 32, 49,
            48, 57, 32, 80, 105, 115, 111, 32, 56, 44, 32, 67, 101, 110, 116, 114, 111,
            44, 32, 48, 54, 48, 56, 50, 44, 32, 77, 69, 88, 73, 67, 79, 11, 0, 5, 0, 0, 0, 3,
            78, 97, 78, 11, 0, 6, 0, 0, 0, 8, 68, 105, 114, 101, 99, 116, 111, 114, 11, 0, 7,
            0, 0, 0, 7, 83, 111, 109, 101, 111, 110, 101, 11, 0, 8, 0, 0, 0, 13, 49, 48, 48,
            36, 32, 98, 97, 110, 107, 110, 111, 116, 101, 12, 0, 9, 11, 0, 1, 0, 0, 0, 19,
            52, 50, 55, 54, 51, 48, 48, 48, 49, 48, 57, 48, 56, 51, 49, 50, 56, 57, 51, 11,
            0, 2, 0, 0, 0, 8, 83, 111, 109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9, 49,
            50, 51, 49, 50, 57, 56, 55, 54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54,
            54, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106,
            75, 108, 51, 52, 75, 12, 0, 2, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84,
            106, 75, 108, 51, 52, 76, 12, 0, 2, 12, 0, 1, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82,
            85, 66, 0, 12, 0, 2, 12, 0, 1, 11, 0, 1, 0, 0, 0, 19, 52, 50, 55, 54, 51, 48, 48,
            48, 49, 48, 57, 48, 56, 51, 49, 50, 56, 57, 51, 11, 0, 2, 0, 0, 0, 8, 83, 111,
            109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9, 49, 50, 51, 49, 50, 57, 56, 55,
            54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54, 54, 0, 0, 0, 0, 0, 0, 0, 0, 12,
            0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 77, 12, 0,
            2, 12, 0, 5, 12, 0, 1, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 0, 0, 12, 0,
            2, 11, 0, 1, 0, 0, 0, 17, 66, 97, 116, 116, 108, 101, 32, 82, 101, 97, 100, 121,
            32, 83, 104, 111, 112, 0, 11, 0, 3, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75,
            108, 51, 52, 75, 11, 0, 4, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52,
            76, 0, 0, 0, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108,
            51, 52, 77, 12, 0, 2, 12, 0, 12, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82, 85, 66, 0, 0, 0,
            0, 0, 0>>},
    {mg_stateproc_Machine, <<"party">>, <<"1CSHThTEJ84">>,
        [{mg_stateproc_Event, 1, <<"2019-08-13T07:52:11.080519Z">>,
            undefined,
            {arr,
                [{obj,
                    #{{str, <<"ct">>} =>
                    {str, <<"application/x-erlang-binary">>},
                        {str, <<"vsn">>} => {i, 6}}},
                    {bin,
                        <<131, 104, 2, 100, 0, 13, 112, 97, 114, 116, 121, 95,
                            99, 104, 97, 110, 103, 101, 115, 108, 0, 0, 0, 2, 104,
                            2, 100, 0, 13, 112, 97, 114, 116, 121, 95, 99, 114,
                            101, 97, 116, 101, 100, 104, 4, 100, 0, 20, 112, 97,
                            121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121, 67,
                            114, 101, 97, 116, 101, 100, 109, 0, 0, 0, 11, 49, 67,
                            83, 72, 84, 104, 84, 69, 74, 56, 52, 104, 2, 100, 0, 23,
                            100, 111, 109, 97, 105, 110, 95, 80, 97, 114, 116,
                            121, 67, 111, 110, 116, 97, 99, 116, 73, 110, 102,
                            111, 109, 0, 0, 0, 12, 104, 103, 95, 99, 116, 95, 104,
                            101, 108, 112, 101, 114, 109, 0, 0, 0, 27, 50, 48, 49,
                            57, 45, 48, 56, 45, 49, 51, 84, 48, 55, 58, 53, 50, 58,
                            49, 49, 46, 48, 55, 50, 56, 51, 53, 90, 104, 2, 100, 0,
                            16, 114, 101, 118, 105, 115, 105, 111, 110, 95, 99,
                            104, 97, 110, 103, 101, 100, 104, 3, 100, 0, 28, 112,
                            97, 121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121,
                            82, 101, 118, 105, 115, 105, 111, 110, 67, 104, 97,
                            110, 103, 101, 100, 109, 0, 0, 0, 27, 50, 48, 49, 57,
                            45, 48, 56, 45, 49, 51, 84, 48, 55, 58, 53, 50, 58, 49,
                            49, 46, 48, 55, 50, 56, 51, 53, 90, 97, 0, 106>>}]}}],
        {mg_stateproc_HistoryRange, undefined, 10, backward},
        {mg_stateproc_Content, undefined,
            {obj,
                #{{str, <<"aux_state">>} =>
                {bin,
                    <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116,
                        121, 95, 114, 101, 118, 105, 115, 105, 111, 110, 95,
                        105, 110, 100, 101, 120, 116, 0, 0, 0, 0, 100, 0, 14,
                        115, 110, 97, 112, 115, 104, 111, 116, 95, 105, 110,
                        100, 101, 120, 106>>},
                    {str, <<"ct">>} => {str, <<"application/x-erlang-binary">>}}}},
        undefined,
        {obj,
            #{{str, <<"aux_state">>} =>
            {bin,
                <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116, 121, 95,
                    114, 101, 118, 105, 115, 105, 111, 110, 95, 105, 110, 100,
                    101, 120, 116, 0, 0, 0, 0, 100, 0, 14, 115, 110, 97, 112,
                    115, 104, 111, 116, 95, 105, 110, 100, 101, 120, 106>>},
                {str, <<"ct">>} =>
                {str, <<"application/x-erlang-binary">>}}}}}]
).

format_msg({Fmt, Params}) ->
    lists:flatten(
        io_lib:format(Fmt, Params)
    ).

-spec depth_test_() -> _.
depth_test_() -> [
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, "
        "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = "
        "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', "
        "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', "
        "representative_full_name = 'Someone', representative_document = '100$ banknote', "
        "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', "
        "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...2 more..., "
        "PartyModification{shop_modification = ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = "
        "ShopModification{shop_account_creation = ShopAccountParams{currency = CurrencyRef{"
        "symbolic_code = 'RUB'}}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [...])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_depth => 0}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{...}, ..."
        "2 more..., PartyModification{...}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_depth => 1}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{...}}, ...2 more..., "
        "PartyModification{shop_modification = ShopModificationUnit{...}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_depth => 2}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{...}}}, ...2 more..., PartyModification{shop_modification = "
        "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{...}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_depth => 3}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{...}}}, ...2 more..., PartyModification{shop_modification = "
        "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{...}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_depth => 4}
            )
        )
    ),
    ?_test(
        begin
            {Result, _} =
                format_thrift_value(
                    {set, string},
                    ordsets:from_list(["a", "2", "ddd"]),
                    0, 0, #{max_length => -1, max_depth => -1}
                ),
            ?_assertEqual(
                "{'a', '2', 'ddd'}",
                lists:flatten(Result)
                )
        end
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [...], history_range = HistoryRange{...}, aux_state = Content{...}, "
        "aux_state_legacy = Value{...}}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_depth => 4}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [Event{...}], history_range = HistoryRange{limit = 10, direction = "
        "backward}, aux_state = Content{data = Value{...}}, aux_state_legacy = Value{obj = #{Value{...} => "
        "Value{...}, Value{...} => Value{...}}}}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_depth => 5}
            )
        )
    )
].

-spec length_test_() -> _.
length_test_() -> [
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, "
        "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = "
        "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', "
        "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', "
        "representative_full_name = 'Someone', representative_document = '100$ banknote', "
        "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', "
        "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...2 more..., "
        "PartyModification{shop_modification = ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = "
        "ShopModification{shop_account_creation = ShopAccountParams{currency = CurrencyRef{"
        "symbolic_code = 'RUB'}}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => -1}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, "
        "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = "
        "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', "
        "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', "
        "representative_full_name = 'Someone', representative_document = '100$ banknote', "
        "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', "
        "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...2 more..., "
        "PartyModification{shop_modification = ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = "
        "ShopModification{shop_account_creation = ShopAccountParams{currency = CurrencyRef{"
        "symbolic_code = 'RUB'}}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 2048}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = "
        "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, "
        "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = "
        "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', "
        "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', "
        "representative_full_name = 'Someone', representative_document = '100$ banknote', "
        "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = "
        "'SomeBank', bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 1024}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{"
        "contract_modification = ContractModificationUnit{...}}, ...])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 100}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{contract_modification "
        "= ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ContractModification{creation = "
        "ContractParams{template = ContractTemplateRef{id = 1}, payment_institution = PaymentInstitutionRef{id = 1}, "
        "contractor = Contractor{legal_entity = LegalEntity{russian_legal_entity = RussianLegalEntity{"
        "registered_name = 'Hoofs & Horns OJSC', registered_number = '1234509876', inn = '1213456789012', "
        "actual_address = 'Nezahualcoyotl 109 Piso 8, O\\'Centro, 06082, MEXICO', ...}}}}}}}, ...])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 512}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{"
        "ns = 'party', id = '1CSHThTEJ84', history = [Event{id = 1, created_at = '2019-08-13T07:52:11.080519Z', "
        "data = Value{arr = [Value{obj = #{Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}, "
        "Value{str = 'vsn'} => Value{i = 6}}}, Value{bin = <<249 bytes>>}]}}], history_range = "
        "HistoryRange{limit = 10, "
        "direction = backward}, aux_state = Content{data = Value{obj = #{Value{str = 'aux_state'} => "
        "Value{bin = <<52 bytes>>}, Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}}}}, "
        "aux_state_legacy = Value{obj = #{Value{str = 'aux_state'} => Value{bin = <<52 bytes>>}, Value{str = 'ct'} "
        "=> Value{str = 'application/x-erlang-binary'}}}}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 1024}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [Event{id = 1, created_at = '2019-08-13T07:52:11.080519Z', data = "
        "Value{arr = [Value{obj = #{Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}, "
        "Value{str = 'vsn'} => Value{i = 6}}}, Value{bin = <<249 bytes>>}]}}], history_range = "
        "HistoryRange{limit = 10, "
        "direction = backward}, aux_state = Content{data = Value{obj = #{Value{str = 'aux_state'} => "
        "Value{bin = <<52 bytes>>}, Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}}}}, ...}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 512}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [Event{id = 1, created_at = '2019-08-13T07:52:11.080519Z', data = "
        "Value{arr = [Value{obj = #{Value{str = 'ct'} => Value{str = 'application/x-erlang-binary'}, ...}}, "
        "...]}}], ...}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 200}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', ...}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 100}
            )
        )
    )
].

-spec depth_and_lenght_test_() -> _.
depth_and_lenght_test_() -> [
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{contract_modification "
        "= ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ContractModification{creation = "
        "ContractParams{...}}}}, ...2 more..., PartyModification{shop_modification = "
        "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{shop_account_creation = "
        "ShopAccountParams{...}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 2048, max_depth => 5}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{contract_modification "
        "= ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ContractModification{creation = "
        "ContractParams{template = ContractTemplateRef{...}, payment_institution = PaymentInstitutionRef{...}, "
        "contractor = Contractor{...}}}}}, ...2 more..., PartyModification{shop_modification = "
        "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{shop_account_creation = "
        "ShopAccountParams{currency = CurrencyRef{...}}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => 2048, max_depth => 7}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [...], history_range = HistoryRange{...}, aux_state = Content{...}, "
        "aux_state_legacy = Value{...}}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 512, max_depth => 3}
            )
        )
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<732 bytes>>}, machine = Machine{ns = 'party', "
        "id = '1CSHThTEJ84', history = [Event{...}], history_range = HistoryRange{limit = 10, "
        "direction = backward}, aux_state = Content{data = Value{...}}, aux_state_legacy = Value{obj = "
        "#{Value{...} => Value{...}, Value{...} => Value{...}}}}})",
        format_msg(
            format_call(
                mg_proto_state_processing_thrift,
                'Processor',
                'ProcessCall',
                ?ARGS2,
                #{max_length => 512, max_depth => 5}
            )
        )
    )
].

-endif.
