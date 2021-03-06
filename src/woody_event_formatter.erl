-module(woody_event_formatter).

-export([
    format_call/5,
    format_reply/5,
    format_exception/5,
    to_string/1
]).

-define(MAX_PRINTABLE_LIST_LENGTH, 3).
-define(MAX_FLOAT_DECIMALS, 8).
%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 40).
-define(MAX_LENGTH, 1000).

-type limit() :: non_neg_integer() | unlimited.

-type opts() :: #{
    max_depth => limit(),
    max_length => limit(),
    max_printable_string_length => non_neg_integer()
}.

-export_type([opts/0]).

-spec format_call(atom(), atom(), atom(), term(), opts()) -> woody_event_handler:msg().
format_call(Module, Service, Function, Arguments, Opts) ->
    Opts1 = normalize_options(Opts),
    ServiceName = to_string(Service),
    FunctionName = to_string(Function),
    Result0 = <<ServiceName/binary, ":", FunctionName/binary, "(">>,
    Result =
        try Module:function_info(Service, Function, params_type) of
            {struct, struct, ArgTypes} ->
                ML = maps:get(max_length, Opts1),
                MD = maps:get(max_depth, Opts1),
                MPSL = maps:get(max_printable_string_length, Opts1),
                Result1 = format_arguments(ArgTypes, Arguments, 1, Result0, MD, dec(ML), MPSL, false),
                <<Result1/binary, ")">>
        catch
            error:badarg ->
                Result1 = format_verbatim(Arguments, Result0, Opts1),
                <<Result1/binary, ")">>
        end,
    {"~ts", [Result]}.

format_arguments([], _, _, Result, _MD, _ML, _MPSL, _AD) ->
    Result;
format_arguments(Types, _, _, Result0, _MD, ML, _MPSL, AD) when byte_size(Result0) > ML ->
    HasMoreArguments = AD and (Types =/= []),
    Result1 = maybe_add_delimiter(HasMoreArguments, Result0),
    Result2 = maybe_add_more_marker(HasMoreArguments, Result1),
    Result2;
format_arguments([Type | RestType], Arguments, I, Result0, MD, ML, MPSL, AD) ->
    Argument = element(I, Arguments),
    {Result1, AD1} = format_argument(Type, Argument, Result0, MD, ML, MPSL, AD),
    format_arguments(
        RestType,
        Arguments,
        I + 1,
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

-spec format_reply(atom(), atom(), atom(), term(), woody:options()) -> woody_event_handler:msg().
format_reply(Module, Service, Function, Value, Opts) ->
    ReplyType = Module:function_info(Service, Function, reply_type),
    format(ReplyType, Value, normalize_options(Opts)).

-spec format_exception(atom(), atom(), atom(), term(), opts()) -> woody_event_handler:msg().
format_exception(Module, Service, Function, Value, Opts) when is_tuple(Value) ->
    {struct, struct, ExceptionTypeList} = Module:function_info(Service, Function, exceptions),
    Exception = element(1, Value),
    ReplyType = get_exception_type(Exception, ExceptionTypeList),
    format(ReplyType, Value, normalize_options(Opts));
format_exception(_Module, _Service, _Function, Value, Opts) ->
    {"~ts", [format_verbatim(Value, <<>>, normalize_options(Opts))]}.

format(ReplyType, Value, #{max_length := ML, max_depth := MD, max_printable_string_length := MPSL}) ->
    try
        ReplyValue = format_thrift_value(ReplyType, Value, <<>>, MD, ML, MPSL),
        {"~ts", [ReplyValue]}
    catch
        E:R:S ->
            Details = genlib_format:format_exception({E, R, S}),
            _ = logger:warning("EVENT FORMATTER ERROR: ~ts", [Details]),
            {"~ts", [format_verbatim(Value, <<>>, MD, ML)]}
    end.

-spec format_thrift_value(term(), term(), binary(), limit(), limit(), non_neg_integer()) -> binary().
format_thrift_value(Type, Value, Result, MD, ML, MPSL) ->
    try
        format_thrift_value_(Type, Value, Result, MD, ML, MPSL)
    catch
        error:_ -> format_verbatim(Value, Result, MD, ML)
    end.

format_thrift_value_({struct, struct, []}, Value, Result, MD, ML, _MPSL) ->
    %% {struct,struct,[]} === thrift's void
    %% so just return Value
    format_verbatim(Value, Result, MD, ML);
format_thrift_value_({struct, struct, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_struct(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value_({struct, union, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_union(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value_({struct, exception, {Module, Struct}}, Value, Result, MD, ML, MPSL) ->
    format_struct(Module, Struct, Value, Result, dec(MD), ML, MPSL);
format_thrift_value_({enum, {_Module, _Struct}}, Value, Result, _MD, _ML, _MPSL) ->
    ValueString = to_string(Value),
    <<Result/binary, ValueString/binary>>;
format_thrift_value_(string, Value, Result, _MD, ML, MPSL) when is_binary(Value) ->
    format_string(Value, Result, ML, MPSL);
format_thrift_value_({list, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "[...]">>;
format_thrift_value_({list, Type}, ValueList, Result0, MD, ML, MPSL) ->
    Result1 = format_thrift_list(Type, ValueList, <<Result0/binary, "[">>, dec(MD), dec(ML), MPSL),
    <<Result1/binary, "]">>;
format_thrift_value_({set, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "{...}">>;
format_thrift_value_({set, Type}, SetofValues, Result0, MD, ML, MPSL) ->
    Result1 = format_thrift_set(Type, SetofValues, <<Result0/binary, "{">>, dec(MD), dec(ML), MPSL),
    <<Result1/binary, "}">>;
format_thrift_value_({map, _}, _, Result, 0, _ML, _MPSL) ->
    <<Result/binary, "#{...}">>;
format_thrift_value_({map, KeyType, ValueType}, Map, Result0, MD, ML, MPSL) ->
    Result1 = format_map(KeyType, ValueType, Map, <<Result0/binary, "#{">>, dec(MD), dec(ML), MPSL, false),
    <<Result1/binary, "}">>;
format_thrift_value_(bool, false, Result, _MD, _ML, _MPSL) ->
    <<Result/binary, "false">>;
format_thrift_value_(bool, true, Result, _MD, _ML, _MPSL) ->
    <<Result/binary, "true">>;
format_thrift_value_(_Type, Value, Result, _MD, _ML, _MPSL) when is_integer(Value) ->
    ValueStr = erlang:integer_to_binary(Value),
    <<Result/binary, ValueStr/binary>>;
format_thrift_value_(_Type, Value, Result, _MD, _ML, _MPSL) when is_float(Value) ->
    ValueStr = erlang:float_to_binary(Value, [{decimals, ?MAX_FLOAT_DECIMALS}, compact]),
    <<Result/binary, ValueStr/binary>>.

format_thrift_list(Type, ValueList, Result, MD, ML, MPSL) when length(ValueList) =< ?MAX_PRINTABLE_LIST_LENGTH ->
    format_list(Type, ValueList, Result, MD, ML, MPSL, false);
format_thrift_list(Type, [FirstEntry | Rest], Result0, MD, ML, MPSL) ->
    LastEntry = lists:last(Rest),
    Result1 = format_thrift_value_(Type, FirstEntry, Result0, MD, ML, MPSL),
    case byte_size(Result1) < ML of
        true ->
            SkippedLength = erlang:integer_to_binary(length(Rest) - 1),
            Result2 = <<Result1/binary, ",...", SkippedLength/binary, " more...,">>,
            case byte_size(Result2) < ML of
                true ->
                    format_thrift_value_(Type, LastEntry, Result2, MD, ML, MPSL);
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
            fun({_, _, Type = {struct, exception, {Module, Exception}}, _, _}) ->
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

-spec format_struct(atom(), atom(), term(), binary(), non_neg_integer(), non_neg_integer(), opts()) -> binary().
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
            <<Result1/binary, "}">>;
        false ->
            % TODO when is this possible?
            format_verbatim(StructValue, Result0, MD, ML)
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

-spec format_union(atom(), atom(), term(), binary(), non_neg_integer(), non_neg_integer(), opts()) -> binary().
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

dec(unlimited) -> unlimited;
dec(0) -> 0;
dec(N) -> N - 1.

format_verbatim(Term, Result, #{max_length := ML, max_depth := MD}) ->
    format_verbatim(Term, Result, MD, ML).

format_verbatim(Term, Result, MD, ML) ->
    Opts = [
        {line_length, 0},
        {depth,
            case MD of
                unlimited -> -1;
                _ -> MD
            end},
        {chars_limit,
            case ML of
                unlimited -> -1;
                _ -> max_(0, ML - byte_size(Result))
            end},
        {encoding, unicode}
    ],
    Printout = erlang:iolist_to_binary(io_lib_pretty:print(Term, Opts)),
    <<Result/binary, Printout/binary>>.

max_(A, B) when A > B -> A;
max_(_, B) -> B.

min_(A, B) when A < B -> A;
min_(_, B) -> B.

-spec format_string(binary(), binary(), limit(), non_neg_integer()) -> binary().
format_string(Value, Result, ML, MPSL) ->
    case is_printable(Value, dec(dec(ML)), byte_size(Result), MPSL) of
        Slice when is_binary(Slice) ->
            try_format_printable_string(Value, Slice, Result);
        non_printable ->
            format_non_printable_string(Value, Result)
    end.

is_printable(<<>> = Slice, _ML, _CL, _MPSL) ->
    Slice;
is_printable(Value, ML, CL, MPSL) ->
    %% Try to get slice of first MPSL bytes from Value,
    %% assuming success means Value is printable string
    %% NOTE: Empty result means non-printable Value
    try string:slice(Value, 0, compute_slice_length(ML, CL, MPSL)) of
        <<>> ->
            non_printable;
        Slice ->
            Slice
    catch
        _:_ ->
            %% Completely wrong binary data drives to crash in string internals,
            %% mark such data as non-printable instead
            non_printable
    end.

compute_slice_length(unlimited, _CL, MPSL) ->
    MPSL;
compute_slice_length(ML, CL, MPSL) ->
    % length("<<X bytes>>") = 11
    max_(12, min_(ML - CL, MPSL)).

-spec try_format_printable_string(binary(), binary(), binary()) -> binary().
try_format_printable_string(Value, Slice, Result0) ->
    Result1 = <<Result0/binary, "'">>,
    case escape_printable_string(Slice, Result1) of
        Result2 when is_binary(Result2) ->
            case byte_size(Slice) == byte_size(Value) of
                true -> <<Result2/binary, "'">>;
                false -> <<Result2/binary, "...'">>
            end;
        non_printable ->
            format_non_printable_string(Value, Result0)
    end.

format_non_printable_string(Value, Result) ->
    SizeStr = erlang:integer_to_binary(byte_size(Value)),
    <<Result/binary, "<<", SizeStr/binary, " bytes>>">>.

-spec escape_printable_string(binary(), binary()) -> binary() | non_printable.
escape_printable_string(<<>>, Result) ->
    Result;
escape_printable_string(<<$', String/binary>>, Result) ->
    escape_printable_string(String, <<Result/binary, "\\'">>);
escape_printable_string(<<C/utf8, String/binary>>, Result) ->
    case printable_char(C) of
        ws -> escape_printable_string(String, <<Result/binary, " ">>);
        pr -> escape_printable_string(String, <<Result/binary, C/utf8>>);
        no -> non_printable
    end.

%% Stolen from:
%% https://github.com/erlang/otp/blob/acc3b04/lib/stdlib/src/io_lib_pretty.erl#L886
printable_char($\n) ->
    ws;
printable_char($\r) ->
    ws;
printable_char($\t) ->
    ws;
printable_char($\v) ->
    ws;
printable_char($\b) ->
    ws;
printable_char($\f) ->
    ws;
printable_char($\e) ->
    ws;
printable_char(C) when
    C >= $\s andalso C =< $~ orelse
        C >= 16#A0 andalso C < 16#D800 orelse
        C > 16#DFFF andalso C < 16#FFFE orelse
        C > 16#FFFF andalso C =< 16#10FFFF
->
    pr;
printable_char(_) ->
    no.

-spec to_string(binary() | atom()) -> binary().
to_string(Value) when is_binary(Value) ->
    Value;
to_string(Value) when is_atom(Value) ->
    erlang:atom_to_binary(Value, unicode);
to_string(_) ->
    error(badarg).

normalize_options(Opts) ->
    maps:merge(
        #{
            max_depth => unlimited,
            max_length => ?MAX_LENGTH,
            max_printable_string_length => ?MAX_BIN_SIZE
        },
        Opts
    ).

maybe_add_delimiter(false, Result) ->
    Result;
maybe_add_delimiter(true, Result) ->
    <<Result/binary, ",">>.

maybe_add_more_marker(false, Result) ->
    Result;
maybe_add_more_marker(true, Result) ->
    <<Result/binary, "...">>.

format_list(_Type, [], Result, _MD, _ML, _MPSL, _AD) ->
    Result;
format_list(Type, [Entry | ValueList], Result0, MD, ML, MPSL, AD) ->
    Result1 = maybe_add_delimiter(AD, Result0),
    Result2 = format_thrift_value_(Type, Entry, Result1, MD, ML, MPSL),
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
    Result2 = format_thrift_value_(KeyType, Key, Result1, MD, ML, MPSL),
    Result3 = format_thrift_value_(ValueType, Value, <<Result2/binary, "=">>, MD, ML, MPSL),
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

-define(ARGS,
    {undefined, <<"1CR1Xziml7o">>, [
        {contract_modification,
            {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
                {creation,
                    {payproc_ContractParams, undefined, {domain_ContractTemplateRef, 1},
                        {domain_PaymentInstitutionRef, 1},
                        {legal_entity,
                            {russian_legal_entity,
                                {domain_RussianLegalEntity, <<"Hoofs & Horns OJSC">>, <<"1234509876">>,
                                    <<"1213456789012">>, <<"Nezahualcoyotl 109 Piso 8, O'Centro, 06082, MEXICO">>,
                                    <<"NaN">>, <<"Director">>, <<"Someone">>, <<"100$ banknote">>,
                                    {domain_RussianBankAccount, <<"4276300010908312893">>, <<"SomeBank">>,
                                        <<"123129876">>, <<"66642666">>}}}}}}}},
        {contract_modification,
            {payproc_ContractModificationUnit, <<"1CR1Y2ZcrA0">>,
                {payout_tool_modification,
                    {payproc_PayoutToolModificationUnit, <<"1CR1Y2ZcrA1">>,
                        {creation,
                            {payproc_PayoutToolParams, {domain_CurrencyRef, <<"RUB">>},
                                {russian_bank_account,
                                    {domain_RussianBankAccount, <<"4276300010908312893">>, <<"SomeBank">>,
                                        <<"123129876">>, <<"66642666">>}}}}}}}},
        {shop_modification,
            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                {creation,
                    {payproc_ShopParams, {domain_CategoryRef, 1}, {url, <<>>},
                        {domain_ShopDetails, <<"Battle Ready Shop">>, undefined}, <<"1CR1Y2ZcrA0">>,
                        <<"1CR1Y2ZcrA1">>}}}},
        {shop_modification,
            {payproc_ShopModificationUnit, <<"1CR1Y2ZcrA2">>,
                {shop_account_creation, {payproc_ShopAccountParams, {domain_CurrencyRef, <<"RUB">>}}}}}
    ]}
).

-define(ARGS2,
    {{mg_stateproc_CallArgs,
        {bin,
            <<131, 104, 4, 100, 0, 11, 116, 104, 114, 105, 102, 116, 95, 99, 97, 108, 108, 100, 0, 16, 112, 97, 114,
                116, 121, 95, 109, 97, 110, 97, 103, 101, 109, 101, 110, 116, 104, 2, 100, 0, 15, 80, 97, 114, 116, 121,
                77, 97, 110, 97, 103, 101, 109, 101, 110, 116, 100, 0, 11, 67, 114, 101, 97, 116, 101, 67, 108, 97, 105,
                109, 109, 0, 0, 2, 145, 11, 0, 2, 0, 0, 0, 11, 49, 67, 83, 72, 84, 104, 84, 69, 74, 56, 52, 15, 0, 3,
                12, 0, 0, 0, 4, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 75, 12, 0, 2,
                12, 0, 1, 12, 0, 2, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 3, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 1, 12, 0, 1, 12, 0,
                1, 11, 0, 1, 0, 0, 0, 18, 72, 111, 111, 102, 115, 32, 38, 32, 72, 111, 114, 110, 115, 32, 79, 74, 83,
                67, 11, 0, 2, 0, 0, 0, 10, 49, 50, 51, 52, 53, 48, 57, 56, 55, 54, 11, 0, 3, 0, 0, 0, 13, 49, 50, 49,
                51, 52, 53, 54, 55, 56, 57, 48, 49, 50, 11, 0, 4, 0, 0, 0, 48, 78, 101, 122, 97, 104, 117, 97, 108, 99,
                111, 121, 111, 116, 108, 32, 49, 48, 57, 32, 80, 105, 115, 111, 32, 56, 44, 32, 67, 101, 110, 116, 114,
                111, 44, 32, 48, 54, 48, 56, 50, 44, 32, 77, 69, 88, 73, 67, 79, 11, 0, 5, 0, 0, 0, 3, 78, 97, 78, 11,
                0, 6, 0, 0, 0, 8, 68, 105, 114, 101, 99, 116, 111, 114, 11, 0, 7, 0, 0, 0, 7, 83, 111, 109, 101, 111,
                110, 101, 11, 0, 8, 0, 0, 0, 13, 49, 48, 48, 36, 32, 98, 97, 110, 107, 110, 111, 116, 101, 12, 0, 9, 11,
                0, 1, 0, 0, 0, 19, 52, 50, 55, 54, 51, 48, 48, 48, 49, 48, 57, 48, 56, 51, 49, 50, 56, 57, 51, 11, 0, 2,
                0, 0, 0, 8, 83, 111, 109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9, 49, 50, 51, 49, 50, 57, 56, 55,
                54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54, 54, 0, 0, 0, 0, 0, 0, 0, 0, 12, 0, 4, 11, 0, 1, 0,
                0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 75, 12, 0, 2, 12, 0, 4, 11, 0, 1, 0, 0, 0, 11, 49,
                67, 83, 72, 84, 106, 75, 108, 51, 52, 76, 12, 0, 2, 12, 0, 1, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82, 85,
                66, 0, 12, 0, 2, 12, 0, 1, 11, 0, 1, 0, 0, 0, 19, 52, 50, 55, 54, 51, 48, 48, 48, 49, 48, 57, 48, 56,
                51, 49, 50, 56, 57, 51, 11, 0, 2, 0, 0, 0, 8, 83, 111, 109, 101, 66, 97, 110, 107, 11, 0, 3, 0, 0, 0, 9,
                49, 50, 51, 49, 50, 57, 56, 55, 54, 11, 0, 4, 0, 0, 0, 8, 54, 54, 54, 52, 50, 54, 54, 54, 0, 0, 0, 0, 0,
                0, 0, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 77, 12, 0, 2, 12, 0,
                5, 12, 0, 1, 8, 0, 1, 0, 0, 0, 1, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 0, 0, 12, 0, 2, 11, 0, 1, 0, 0, 0, 17,
                66, 97, 116, 116, 108, 101, 32, 82, 101, 97, 100, 121, 32, 83, 104, 111, 112, 0, 11, 0, 3, 0, 0, 0, 11,
                49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 75, 11, 0, 4, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108,
                51, 52, 76, 0, 0, 0, 0, 12, 0, 6, 11, 0, 1, 0, 0, 0, 11, 49, 67, 83, 72, 84, 106, 75, 108, 51, 52, 77,
                12, 0, 2, 12, 0, 12, 12, 0, 1, 11, 0, 1, 0, 0, 0, 3, 82, 85, 66, 0, 0, 0, 0, 0, 0>>},
        {mg_stateproc_Machine, <<"party">>, <<"1CSHThTEJ84">>,
            [
                {mg_stateproc_Event, 1, <<"2019-08-13T07:52:11.080519Z">>, undefined,
                    {arr, [
                        {obj, #{
                            {str, <<"ct">>} =>
                                {str, <<"application/x-erlang-binary">>},
                            {str, <<"vsn">>} => {i, 6}
                        }},
                        {bin,
                            <<131, 104, 2, 100, 0, 13, 112, 97, 114, 116, 121, 95, 99, 104, 97, 110, 103, 101, 115, 108,
                                0, 0, 0, 2, 104, 2, 100, 0, 13, 112, 97, 114, 116, 121, 95, 99, 114, 101, 97, 116, 101,
                                100, 104, 4, 100, 0, 20, 112, 97, 121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121, 67,
                                114, 101, 97, 116, 101, 100, 109, 0, 0, 0, 11, 49, 67, 83, 72, 84, 104, 84, 69, 74, 56,
                                52, 104, 2, 100, 0, 23, 100, 111, 109, 97, 105, 110, 95, 80, 97, 114, 116, 121, 67, 111,
                                110, 116, 97, 99, 116, 73, 110, 102, 111, 109, 0, 0, 0, 12, 104, 103, 95, 99, 116, 95,
                                104, 101, 108, 112, 101, 114, 109, 0, 0, 0, 27, 50, 48, 49, 57, 45, 48, 56, 45, 49, 51,
                                84, 48, 55, 58, 53, 50, 58, 49, 49, 46, 48, 55, 50, 56, 51, 53, 90, 104, 2, 100, 0, 16,
                                114, 101, 118, 105, 115, 105, 111, 110, 95, 99, 104, 97, 110, 103, 101, 100, 104, 3,
                                100, 0, 28, 112, 97, 121, 112, 114, 111, 99, 95, 80, 97, 114, 116, 121, 82, 101, 118,
                                105, 115, 105, 111, 110, 67, 104, 97, 110, 103, 101, 100, 109, 0, 0, 0, 27, 50, 48, 49,
                                57, 45, 48, 56, 45, 49, 51, 84, 48, 55, 58, 53, 50, 58, 49, 49, 46, 48, 55, 50, 56, 51,
                                53, 90, 97, 0, 106>>}
                    ]}}
            ],
            {mg_stateproc_HistoryRange, undefined, 10, backward},
            {mg_stateproc_Content, undefined,
                {obj, #{
                    {str, <<"aux_state">>} =>
                        {bin,
                            <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116, 121, 95, 114, 101, 118, 105, 115,
                                105, 111, 110, 95, 105, 110, 100, 101, 120, 116, 0, 0, 0, 0, 100, 0, 14, 115, 110, 97,
                                112, 115, 104, 111, 116, 95, 105, 110, 100, 101, 120, 106>>},
                    {str, <<"ct">>} => {str, <<"application/x-erlang-binary">>}
                }}},
            undefined,
            {obj, #{
                {str, <<"aux_state">>} =>
                    {bin,
                        <<131, 116, 0, 0, 0, 2, 100, 0, 20, 112, 97, 114, 116, 121, 95, 114, 101, 118, 105, 115, 105,
                            111, 110, 95, 105, 110, 100, 101, 120, 116, 0, 0, 0, 0, 100, 0, 14, 115, 110, 97, 112, 115,
                            104, 111, 116, 95, 105, 110, 100, 101, 120, 106>>},
                {str, <<"ct">>} =>
                    {str, <<"application/x-erlang-binary">>}
            }}}}}
).

format_msg({Fmt, Params}) ->
    lists:flatten(
        io_lib:format(Fmt, Params)
    ).

-spec depth_test_() -> _.
depth_test_() ->
    [
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
                    #{}
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
        ?_assertEqual(
            <<"{'2','a','ddd'}">>,
            format_thrift_value(
                {set, string},
                ordsets:from_list([<<"a">>, <<"2">>, <<"ddd">>]),
                <<>>,
                unlimited,
                unlimited,
                ?MAX_PRINTABLE_LIST_LENGTH
            )
        ),
        ?_assertEqual(
            "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
            "id='1CSHThTEJ84',history=[Event{...}],history_range=HistoryRange{...},aux_state=Content{...},"
            "aux_state_legacy=Value{...}}})",
            format_msg(
                format_call(
                    mg_proto_state_processing_thrift,
                    'Processor',
                    'ProcessCall',
                    ?ARGS2,
                    #{max_depth => 3}
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
                    #{max_depth => 4}
                )
            )
        )
    ].

-spec length_test_() -> _.
length_test_() ->
    [
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
            "actual_address='Nezahualcoyotl 109 Piso 8,...',...}}}}}}},...])",
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

-spec depth_and_length_test_() -> _.
depth_and_length_test_() ->
    [
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
                    #{max_length => 2048, max_depth => 6}
                )
            )
        ),
        ?_assertEqual(
            "Processor:ProcessCall(a=CallArgs{arg=Value{bin=<<732 bytes>>},machine=Machine{ns='party',"
            "id='1CSHThTEJ84',history=[Event{...}],history_range=HistoryRange{...},aux_state=Content{...},"
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
                    #{max_length => 512, max_depth => 4}
                )
            )
        )
    ].

-spec verbatim_test_() -> _.
verbatim_test_() ->
    [
        ?_assertEqual(
            "PartyManagement:CallMissingFunction("
            "{undefined,<<\"1CR1Xziml7o\">>,[{contract_modification,{payproc_ContractModificationUnit,"
            "<<\"1CR1\"...>>,{...}}},{contract_modification,{payproc_ContractModificationUnit,<<...>>,"
            "...}},{shop_modification,{payproc_ShopModificationUnit,...}}|...]}"
            ")",
            format_msg(
                format_call(
                    dmsl_payment_processing_thrift,
                    'PartyManagement',
                    'CallMissingFunction',
                    ?ARGS,
                    #{max_length => 256}
                )
            )
        )
    ].

-spec printability_test_() -> _.
printability_test_() ->
    [
        ?_assertEqual(
            <<"'Processor:ProcessCall'">>,
            format_string(<<"Processor:ProcessCall">>, <<>>, unlimited, 100)
        ),
        ?_assertEqual(
            <<"'Processor   ProcessCall'">>,
            format_string(<<"Processor\r\n\tProcessCall">>, <<>>, unlimited, 100)
        ),
        ?_assertEqual(
            <<"<<42 bytes>>">>,
            format_string(<<0:42/integer-unit:8>>, <<>>, unlimited, 100)
        ),
        ?_assertEqual(
            <<"<<59 bytes>>">>,
            format_string(
                <<16#1c, 0, 0, 0, "request_additional_data", 0, 0, 0, "PSE420XXVRG4X2Z31207107142808">>,
                <<>>,
                unlimited,
                100
            )
        ),
        ?_assertEqual(
            <<"<<7 bytes>>">>,
            format_string(<<15, 0, 1, 0, 0, 0, 3>>, <<>>, unlimited, 100)
        )
    ].

-spec limited_printability_test_() -> _.
limited_printability_test_() ->
    [
        ?_assertEqual(
            <<"'Processor:ProcessC...'">>,
            format_string(<<"Processor:ProcessCall">>, <<>>, 20, 100)
        )
    ].

-endif.
