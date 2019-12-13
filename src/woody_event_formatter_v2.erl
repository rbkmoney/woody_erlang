-module(woody_event_formatter_v2).

-export([
    format_call/4,
    format_call/5,
    format_reply/5,
    format_exception/5,
    to_string/1
]).

-define(MAX_PRINTABLE_LIST_LENGTH, 3).
%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 40).

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
            FunctionName = to_string(Function),
            ML = maps:get(max_length, Opts1),
            MD = maps:get(max_depth, Opts1),
            MPSL = maps:get(max_pritable_string_length, Opts1),
            Result0 = <<ServiceName/binary, ":", FunctionName/binary, "(">>,
            Result1 = format_call_(ArgTypes, Arguments, Result0, inc(MD), dec(ML), MPSL, false),
            Result2 = <<Result1/binary, ")">>,
            {"~ts", [Result2]}
        % _Other ->
        %     {"~s:~s(~0tp)", [Service, Function, Arguments]}
    end.

format_call_([], [], Result, _MD, _ML, _MPSL, _AD) ->
    Result;
format_call_(_, ArgumentList, Result0, _MD, ML, _MPSL, AD) when byte_size(Result0) > ML ->
    HasMoreArguments = AD and (ArgumentList =/= []),
    Result1 = maybe_add_delimiter(HasMoreArguments, Result0),
    Result2 = maybe_add_more_marker(HasMoreArguments, Result1),
    Result2;
format_call_([Type | RestType], [Argument | RestArgs], Result0, MD, ML, MPSL, AD) ->
    {Result1, AD1} = format_argument(Type, Argument, Result0, MD, ML, MPSL, AD),
    format_call_(
        RestType,
        RestArgs,
        Result1,
        MD,
        ML,
        MPSL,
        AD1
    ).

format_argument({_Fid, _Required, _Type, _Name, undefined}, undefined, Result, _MD, _ML, _MPSL, AD) ->
    {Result, AD};
format_argument({Fid, Required, Type, Name, Default}, undefined, Result, MD, ML, MPSL, AD) ->
    format_argument({Fid, Required, Type, Name, Default}, Default, Result, MD, ML, MPSL, AD);
format_argument({_Fid, _Required, Type, Name, _Default}, Value, Result0, MD, ML, MPSL, AD) ->
    NameStr = atom_to_binary(Name, unicode),
    Result1 = maybe_add_delimiter(AD, Result0),
    Result2 = <<Result1/binary, NameStr/binary, "=">>,
    {format_thrift_value(Type, Value, Result2, MD, ML, MPSL), true}.

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
    format(ReplyType, Value, normalize_options(Opts)).
% format_exception(_Module, _Service, _Function, Value, Opts) ->
%     #{max_length := ML} = normalize_options(Opts),
%     {"~ts", [io_lib:format("~0tp", [Value], [{chars_limit, ML}])]}.

format(ReplyType, Value, #{max_length := ML, max_depth := MD, max_pritable_string_length := MPSL}) ->
    % try
        ReplyFmt = format_thrift_value(ReplyType, Value, <<>>, MD, ML, MPSL),
        {"~ts", [ReplyFmt]}.
    % catch
    %     E:R:S ->
    %         WarningDetails = genlib_format:format_exception({E, R, S}),
    %         logger:warning("EVENT FORMATTER ERROR: ~tp", [WarningDetails]),
    %         {"~ts", [io_lib:format("~0tp", [Value], [{chars_limit, ML}])]}
    % end.

-spec format_thrift_value(term(), term(), binary(), non_neg_integer(), non_neg_integer(), opts()) ->
    binary().
format_thrift_value({struct, struct, []}, Value, Result, _MD, ML, _MPSL) ->
    %% {struct,struct,[]} === thrift's void
    %% so just return Value
    FmtOpts = compute_format_opts(ML, byte_size(Result)),
    ValueString = iolist_to_binary(io_lib:format("~0tp", [Value], FmtOpts)),
    <<Result/binary, ValueString/binary>>;
format_thrift_value({struct, struct, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_struct(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value({struct, union, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_union(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value({struct, exception, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_struct(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value({enum, {_Module, _Struct}}, Value, Result, _MD, _ML, _MPSL) ->
    ValueString = to_string(Value),
    <<Result/binary, ValueString/binary>>;
format_thrift_value(string, Value, Result0, _MD, ML, MPSL) ->
    case is_printable(Value, ML, byte_size(Result0), MPSL) of
        Slice when is_binary(Slice) ->
            Result1 = escape_printable_string(Slice, <<Result0/binary, "'">>),
            case byte_size(Slice) == byte_size(Value) of
                true -> <<Result1/binary, "'">>;
                false -> <<Result1/binary, "...'">>
            end;
        not_printable ->
            format_non_printable_string(Value, Result0)
    end;
% format_thrift_value(string, Value, _CurDepth, CL, _Opts) ->
%     ValueString = value_to_string(Value),
%     Length = length(ValueString),
%     {["'", ValueString, "'"], CL + Length + 2}; %% 2 = length("''")
format_thrift_value({list, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "[...]">>;
format_thrift_value({list, Type}, ValueList, Result0, MD, ML, MPSL) ->
    Result1 = format_thrift_list(Type, ValueList, <<Result0/binary, "[">>, dec(MD), dec(ML), MPSL),
    <<Result1/binary, "]">>;
format_thrift_value({set, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "{...}">>;
format_thrift_value({set, Type}, SetofValues, Result0, MD, ML, MPSL) ->
    Result1 = format_thrift_set(Type, SetofValues, <<Result0/binary, "{">>, dec(MD), dec(ML), MPSL),
    <<Result1/binary, "}">>;
format_thrift_value({map, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "#{...}">>;
format_thrift_value({map, KeyType, ValueType}, Map, Result0, MD, ML, MPSL) ->
    Result1 = format_map(KeyType, ValueType, Map, <<Result0/binary, "#{">>, dec(MD), dec(ML), MPSL, false),
    <<Result1/binary, "}">>;
format_thrift_value(bool, false, Result, _MD, _ML, _MPSL) ->
    <<Result/binary, "false">>;
format_thrift_value(bool, true, Result, _MD, _ML, _MPSL) ->
    <<Result/binary, "true">>;
format_thrift_value(_Type, Value, Result, _MD, _ML, _MPSL) when is_integer(Value) ->
    ValueStr = erlang:integer_to_binary(Value),
    <<Result/binary, ValueStr/binary>>;
format_thrift_value(_Type, Value, Result, _MD, _ML, _MPSL) when is_float(Value) ->
    ValueStr = erlang:float_to_binary(Value),
    <<Result/binary, ValueStr/binary>>.

format_thrift_list(Type, ValueList, Result, MD, ML, MPSL) when length(ValueList) =< ?MAX_PRINTABLE_LIST_LENGTH ->
    format_list(Type, ValueList, Result, MD, ML, MPSL, false);
format_thrift_list(Type, [FirstEntry | Rest], Result0, MD, ML, MPSL) ->
    LastEntry = lists:last(Rest),
    Result1 = format_thrift_value(Type, FirstEntry, Result0, MD, ML, MPSL),
    case byte_size(Result1) < ML of
        true ->
            SkippedLength = erlang:integer_to_binary(length(Rest) - 1),
            Result2 = <<Result1/binary, ",...", SkippedLength/binary, " more...,">>,
            case byte_size(Result2) < ML of
                true ->
                    format_thrift_value(Type, LastEntry, Result2, MD, ML, MPSL);
                false ->
                    <<Result2/binary, "...">>
            end;
        false ->
            <<Result1/binary, ",...">>
    end.

format_thrift_set(Type, SetofValues, Result, MD, ML, MPSL) ->
    %% Actually ordsets is a list so leave this implementation as-is
    ValueList = ordsets:to_list(SetofValues),
    format_list(Type, ValueList, Result, MD, ML, MPSL, false).

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

-spec format_struct(atom(), atom(), term(), binary(), non_neg_integer(), non_neg_integer(), opts()) ->
    binary().
format_struct(_Module, Struct, _StructValue, Result, 0, _ML, _MPSL) ->
    StructName = atom_to_binary(Struct, unicode),
    <<Result/binary, StructName/binary, "{...}">>;
format_struct(Module, Struct, StructValue, Result0, MD, ML, MPSL) ->
    %% struct and exception have same structure
    {struct, _, StructMeta} = Module:struct_info(Struct),
    case length(StructMeta) == tuple_size(StructValue) - 1 of
        true ->
            StructName = atom_to_binary(Struct, unicode),
            Result1 = format_struct_(
                StructMeta,
                StructValue,
                2,
                <<Result0/binary, StructName/binary, "{">>,
                MD,
                dec(ML),
                MPSL,
                false
            ),
            <<Result1/binary, "}">>
        % false ->
        %     % TODO when is this possible?
        %     FmtOpts = compute_format_opts(ML, byte_size(Result0)),
        %     Params = erlang:iolist_to_binary(io_lib:format("~0tp", [StructValue], FmtOpts)),
        %     <<Result0/binary, Params/binary>>
    end.

format_struct_([], S, I, Result, _MD, _ML, _MPSL, _AD) when I > tuple_size(S) ->
    Result;
format_struct_(_Types, _S, _I, Result0, _MD, ML, _MPSL, AD) when byte_size(Result0) > ML ->
    Result1 = maybe_add_delimiter(AD, Result0),
    <<Result1/binary, "...">>;
format_struct_([Type | RestTypes], S, I, Result0, MD, ML, MPSL, AD) ->
    Value = erlang:element(I, S),
    {Result1, AD1} = format_argument(Type, Value, Result0, MD, ML, MPSL, AD),
    format_struct_(
        RestTypes,
        S,
        I + 1,
        Result1,
        MD,
        ML,
        MPSL,
        AD1
    ).

-spec format_union(atom(), atom(), term(), binary(), non_neg_integer(), non_neg_integer(), opts()) ->
    binary().
format_union(_Module, Struct, _StructValue, Result, 0, _ML, _MPSL) ->
    StructName = atom_to_binary(Struct, unicode),
    <<Result/binary, StructName/binary, "{...}">>;
format_union(Module, Struct, {Type, UnionValue}, Result0, MD, ML, MPSL) ->
    {struct, union, StructMeta} = Module:struct_info(Struct),
    UnionMeta = lists:keyfind(Type, 4, StructMeta),
    StructName = atom_to_binary(Struct, unicode),
    Result1 = <<Result0/binary, StructName/binary, "{">>,
    case byte_size(Result1) > ML of
        false ->
            {Result2, _} = format_argument(
                UnionMeta,
                UnionValue,
                Result1,
                MD,
                dec(ML),
                MPSL,
                false
            ),
            <<Result2/binary, "}">>;
        true ->
            <<Result1/binary, "...}">>
    end.

format_non_printable_string(Value, Result) ->
    SizeStr = erlang:integer_to_binary(byte_size(Value)),
    <<Result/binary, "<<", SizeStr/binary, " bytes>>">>.

is_printable(<<>> = Slice, _ML, _CL, _MPSL) ->
    Slice;
is_printable(Value, ML, CL, MPSL) ->
    %% Try to get slice of first MPSL bytes from Value,
    %% assuming success means Value is printable string
    %% NOTE: Empty result means non-printable Value
    try string:slice(Value, 0, compute_slice_length(ML, CL, MPSL)) of
        <<>> ->
            not_printable;
        Slice ->
            Slice
    catch
        _:_ ->
            %% Completely wrong binary data drives to crash in string internals,
            %% mark such data as non-printable instead
            not_printable
    end.

dec(unlimited) -> unlimited;
dec(0) -> 0;
dec(N) -> N - 1.

inc(unlimited) -> unlimited;
inc(N) -> N + 1.

compute_format_opts(unlimited, _CL) ->
    [];
compute_format_opts(ML, CL) ->
    [{chars_limit, max_(0, ML - CL)}].

compute_slice_length(unlimited, _CL, MPSL) ->
    MPSL;
compute_slice_length(ML, CL, MPSL) ->
    max_(12, min_(ML - CL, MPSL)). % length("<<X bytes>>") = 11

max_(A, B) when A > B -> A;
max_(_, B) -> B.

min_(A, B) when A < B -> A;
min_(_, B) -> B.

-spec escape_printable_string(binary(), binary()) -> binary().
escape_printable_string(<<>>, Result) ->
    Result;
escape_printable_string(<<$', String/binary>>, Result) ->
    escape_printable_string(String, <<Result/binary, "\\'">>);
escape_printable_string(<<C/utf8, String/binary>>, Result) ->
    case unicode_util:is_whitespace(C) of
        true  -> escape_printable_string(String, <<Result/binary, " ">>);
        false -> escape_printable_string(String, <<Result/binary, C/utf8>>)
    end.

-spec to_string(binary() | atom()) -> binary().
to_string(Value) when is_binary(Value) ->
    Value;
to_string(Value) when is_atom(Value) ->
    erlang:atom_to_binary(Value, unicode);
to_string(_) ->
    error(badarg).

normalize_options(Opts) ->
    maps:merge(#{
        max_depth => unlimited,
        max_length => unlimited,
        max_pritable_string_length => ?MAX_BIN_SIZE
    }, Opts).

maybe_add_delimiter(false, Result) ->
    Result;
maybe_add_delimiter(true, Result) ->
    <<Result/binary, ",">>.

maybe_add_more_marker(false, Result) ->
    Result;
maybe_add_more_marker(true, Result) ->
    <<Result/binary, "...">>.

format_list(_Type, [], Result, _MD, _ML, _MPSL, _IsFirst) ->
    Result;
format_list(Type, [Entry | ValueList], Result0, MD, ML, MPSL, IsFirst) ->
    Result1 = maybe_add_delimiter(IsFirst, Result0),
    Result2 = format_thrift_value(Type, Entry, Result1, MD, ML, MPSL),
    case byte_size(Result2) of
        CL when ML > CL ->
            format_list(Type, ValueList, Result2, MD, ML, MPSL, true);
        _ ->
            MaybeAddMoreMarker = length(ValueList) =/= 0,
            stop_format(MaybeAddMoreMarker, Result2)
    end.

format_map(_KeyType, _ValueType, Map, Result, _MD, _ML, _MPSL, _AD) when map_size(Map) =:= 0 ->
    Result;
format_map(KeyType, ValueType, Map, Result0, MD, ML, MPSL, AD) ->
    MapIterator = maps:iterator(Map),
    format_map_(KeyType, ValueType, maps:next(MapIterator), Result0, MD, ML, MPSL, AD).

format_map_(KeyType, ValueType, {Key, Value, MapIterator}, Result0, MD, ML, MPSL, AD) ->
    Result1 = maybe_add_delimiter(AD, Result0),
    Result2 = format_thrift_value(KeyType, Key, Result1, MD, ML, MPSL),
    Result3 = format_thrift_value(ValueType, Value, <<Result2/binary, "=">>, MD, ML, MPSL),
    Next = maps:next(MapIterator),
    case byte_size(Result3) of
        CL when ML > CL ->
            format_map_(KeyType, ValueType, Next, Result3, MD, ML, MPSL, true);
        _ ->
            MaybeAddMoreMarker = Next =/= none,
            stop_format(MaybeAddMoreMarker, Result3)
    end;
format_map_(_, _, _, Result, _, _, _, _) ->
    Result.

stop_format(MaybeAddMoreMarker, Result0) ->
    Result1 = maybe_add_delimiter(MaybeAddMoreMarker, Result0),
    Result2 = maybe_add_more_marker(MaybeAddMoreMarker, Result1),
    Result2.

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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{creation=ContractParams{template=ContractTemplateRef{id=1},"
        "payment_institution=PaymentInstitutionRef{id=1},contractor=Contractor{legal_entity="
        "LegalEntity{russian_legal_entity=RussianLegalEntity{registered_name='Hoofs & Horns OJSC',"
        "registered_number='1234509876',inn='1213456789012',actual_address='Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 060...',post_address='NaN',representative_position='Director',"
        "representative_full_name='Someone',representative_document='100$ banknote',"
        "russian_bank_account=RussianBankAccount{account='4276300010908312893',bank_name='SomeBank',"
        "bank_post_account='123129876',bank_bik='66642666'}}}}}}}},...2 more...,"
        "PartyModification{shop_modification=ShopModificationUnit{id='1CR1Y2ZcrA2',modification="
        "ShopModification{shop_account_creation=ShopAccountParams{currency=CurrencyRef{"
        "symbolic_code='RUB'}}}}}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[...])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{...},..."
        "2 more...,PartyModification{...}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{...}},...2 more...,"
        "PartyModification{shop_modification=ShopModificationUnit{...}}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{...}}},...2 more...,PartyModification{shop_modification="
        "ShopModificationUnit{id='1CR1Y2ZcrA2',modification=ShopModification{...}}}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{...}}},...2 more...,PartyModification{shop_modification="
        "ShopModificationUnit{id='1CR1Y2ZcrA2',modification=ShopModification{...}}}])",
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
            Result =
                format_thrift_value(
                    {set, string},
                    ordsets:from_list([<<"a">>, <<"2">>, <<"ddd">>]),
                    <<>>,
                    0,
                    unlimited,
                    #{max_length => unlimited, max_depth => unlimited, max_pritable_string_length => ?MAX_BIN_SIZE}
                ),
            ?_assertEqual( "{'a', '2', 'ddd'}", Result)
        end
    ),
    ?_assertEqual(
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[...],history_range=HistoryRange{...},aux_state=Content{...},"
        "aux_state_legacy=Value{...}}})",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[Event{...}],history_range=HistoryRange{limit=10,direction="
        "backward},aux_state=Content{data=Value{...}},aux_state_legacy=Value{obj=#{Value{...}="
        "Value{...},Value{...}=Value{...}}}}})",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{creation=ContractParams{template=ContractTemplateRef{id=1},"
        "payment_institution=PaymentInstitutionRef{id=1},contractor=Contractor{legal_entity="
        "LegalEntity{russian_legal_entity=RussianLegalEntity{registered_name='Hoofs & Horns OJSC',"
        "registered_number='1234509876',inn='1213456789012',actual_address='Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 060...',post_address='NaN',representative_position='Director',"
        "representative_full_name='Someone',representative_document='100$ banknote',"
        "russian_bank_account=RussianBankAccount{account='4276300010908312893',bank_name='SomeBank',"
        "bank_post_account='123129876',bank_bik='66642666'}}}}}}}},...2 more...,"
        "PartyModification{shop_modification=ShopModificationUnit{id='1CR1Y2ZcrA2',modification="
        "ShopModification{shop_account_creation=ShopAccountParams{currency=CurrencyRef{"
        "symbolic_code='RUB'}}}}}])",
        format_msg(
            format_call(
                dmsl_payment_processing_thrift,
                'PartyManagement',
                'CreateClaim',
                ?ARGS,
                #{max_length => unlimited}
            )
        )
    ),
    ?_assertEqual(
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{creation=ContractParams{template=ContractTemplateRef{id=1},"
        "payment_institution=PaymentInstitutionRef{id=1},contractor=Contractor{legal_entity="
        "LegalEntity{russian_legal_entity=RussianLegalEntity{registered_name='Hoofs & Horns OJSC',"
        "registered_number='1234509876',inn='1213456789012',actual_address='Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 060...',post_address='NaN',representative_position='Director',"
        "representative_full_name='Someone',representative_document='100$ banknote',"
        "russian_bank_account=RussianBankAccount{account='4276300010908312893',bank_name='SomeBank',"
        "bank_post_account='123129876',bank_bik='66642666'}}}}}}}},...2 more...,"
        "PartyModification{shop_modification=ShopModificationUnit{id='1CR1Y2ZcrA2',modification="
        "ShopModification{shop_account_creation=ShopAccountParams{currency=CurrencyRef{"
        "symbolic_code='RUB'}}}}}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{id='1CR1Y2ZcrA0',modification="
        "ContractModification{creation=ContractParams{template=ContractTemplateRef{id=1},"
        "payment_institution=PaymentInstitutionRef{id=1},contractor=Contractor{legal_entity="
        "LegalEntity{russian_legal_entity=RussianLegalEntity{registered_name='Hoofs & Horns OJSC',"
        "registered_number='1234509876',inn='1213456789012',actual_address='Nezahualcoyotl 109 Piso 8, "
        "O\\'Centro, 060...',post_address='NaN',representative_position='Director',"
        "representative_full_name='Someone',representative_document='100$ banknote',"
        "russian_bank_account=RussianBankAccount{account='4276300010908312893',bank_name="
        "'SomeBank',bank_post_account='123129876',bank_bik='66642666'}}}}}}}},...2 more...,"
        "PartyModification{shop_modification=ShopModificationUnit{id='1CR1Y2ZcrA2',"
        "modification=ShopModification{shop_account_creation=ShopAccountParams{"
        "currency=CurrencyRef{symbolic_code='RUB'}}}}}])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{"
        "contract_modification=ContractModificationUnit{...}},...])",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{contract_modification"
        "=ContractModificationUnit{id='1CR1Y2ZcrA0',modification=ContractModification{creation="
        "ContractParams{template=ContractTemplateRef{id=1},payment_institution=PaymentInstitutionRef{id=1},"
        "contractor=Contractor{legal_entity=LegalEntity{russian_legal_entity=RussianLegalEntity{"
        "registered_name='Hoofs & Horns OJSC',registered_number='1234509876',inn='1213456789012',"
        "actual_address='Nezahualcoyotl 109 Piso 8, O...',...}}}}}}},...])",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{"
        "ns='party',id='1CSHThTEJ84',history=[Event{id=1,created_at='2019-08-13T07:52:11.080519Z',"
        "data=Value{arr=[Value{obj=#{Value{str='ct'}=Value{str='application/x-erlang-binary'},"
        "Value{str='vsn'}=Value{i=6}}},Value{bin=<<249 bytes>>}]}}],history_range="
        "HistoryRange{limit=10,"
        "direction=backward},aux_state=Content{data=Value{obj=#{Value{str='aux_state'}="
        "Value{bin=<<52 bytes>>},Value{str='ct'}=Value{str='application/x-erlang-binary'}}}},"
        "aux_state_legacy=Value{obj=#{Value{str='aux_state'}=Value{bin=<<52 bytes>>},Value{str='ct'}"
        "=Value{str='application/x-erlang-binary'}}}}})",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[Event{id=1,created_at='2019-08-13T07:52:11.080519Z',data="
        "Value{arr=[Value{obj=#{Value{str='ct'}=Value{str='application/x-erlang-binary'},"
        "Value{str='vsn'}=Value{i=6}}},Value{bin=<<249 bytes>>}]}}],history_range="
        "HistoryRange{limit=10,"
        "direction=backward},aux_state=Content{data=Value{obj=#{Value{str='aux_state'}="
        "Value{bin=<<52 bytes>>},Value{str='ct'}=Value{str='application/x-erlang-binary'}}}},"
        "aux_state_legacy=Value{...}}})",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[Event{id=1,created_at='2019-08-13T07:52:11.080519Z',data="
        "Value{arr=[Value{obj=#{Value{...}=Value{...},...}},...]}}],...}})",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',...}})",
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{contract_modification"
        "=ContractModificationUnit{id='1CR1Y2ZcrA0',modification=ContractModification{creation="
        "ContractParams{...}}}},...2 more...,PartyModification{shop_modification="
        "ShopModificationUnit{id='1CR1Y2ZcrA2',modification=ShopModification{shop_account_creation="
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
        "PartyManagement:CreateClaim(party_id='1CR1Xziml7o',changeset=[PartyModification{contract_modification"
        "=ContractModificationUnit{id='1CR1Y2ZcrA0',modification=ContractModification{creation="
        "ContractParams{template=ContractTemplateRef{...},payment_institution=PaymentInstitutionRef{...},"
        "contractor=Contractor{...}}}}},...2 more...,PartyModification{shop_modification="
        "ShopModificationUnit{id='1CR1Y2ZcrA2',modification=ShopModification{shop_account_creation="
        "ShopAccountParams{currency=CurrencyRef{...}}}}}])",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[...],history_range=HistoryRange{...},aux_state=Content{...},"
        "aux_state_legacy=Value{...}}})",
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
        "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
        "id='1CSHThTEJ84',history=[Event{...}],history_range=HistoryRange{limit=10,"
        "direction=backward},aux_state=Content{data=Value{...}},aux_state_legacy=Value{obj="
        "#{Value{...}=Value{...},Value{...}=Value{...}}}}})",
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
