-module(woody_event_formatter).

-export([
    format_call/4,
    format_call/5,
    format_reply/5,
    format_reply/6,
    to_string/1
]).

-define(MAX_PRINTABLE_LIST_LENGTH, 3).
%% Binaries under size below will log as-is.
-define(MAX_BIN_SIZE, 10).

-type opts():: #{
    current_depth := neg_integer(),
    max_depth := integer()
}.

-spec format_call(atom(), atom(), atom(), term()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments) ->
    format_call(Module, Service, Function, Arguments, #{}).

-spec format_call(atom(), atom(), atom(), term(), opts()) ->
    woody_event_handler:msg().
format_call(Module, Service, Function, Arguments, Opts) ->
    Opts1 = normalize_options(Opts),
    case Module:function_info(Service, Function, params_type) of
        {struct, struct, ArgTypes} ->
            {ArgsFormat, ArgsArgs} =
                format_call_(ArgTypes, Arguments, {[], []}, Opts1),
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
    Opts1 = normalize_options(Opts),
    try
        case FormatAsException of
            false ->
                ReplyType = Module:function_info(Service, Function, reply_type),
                format_thrift_value(ReplyType, Value, Opts1);
            true ->
                {struct, struct, ExceptionTypeList} = Module:function_info(Service, Function, exceptions),
                Exception = element(1, Value),
                ExceptionType = get_exception_type(Exception, ExceptionTypeList),
                format_thrift_value(ExceptionType, Value, Opts1)
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
    format_struct(Module, Struct, Value, increment_depth(Opts));
format_thrift_value({struct, union, {Module, Struct}}, Value, Opts) ->
    format_union(Module, Struct, Value, increment_depth(Opts));
format_thrift_value({struct, exception, {Module, Struct}}, Value, Opts) ->
    format_struct(Module, Struct, Value, increment_depth(Opts));
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
format_thrift_value({list, _}, _, #{current_depth := CD, max_depth := MD})
    when MD >= 0, CD >= MD ->
    {"[...]",[]};
format_thrift_value({list, Type}, ValueList, Opts) when length(ValueList) =< ?MAX_PRINTABLE_LIST_LENGTH ->
    {Format, Params} =
        lists:foldr(
            fun(Entry, {FA, FP}) ->
                {F, P} = format_thrift_value(Type, Entry, increment_depth(Opts)),
                {[F | FA], P ++ FP}
            end,
            {[], []},
            ValueList
        ),
    {"[" ++ string:join(Format, ", ") ++ "]", Params};
format_thrift_value({list, Type}, ValueList, Opts) ->
    FirstEntry = hd(ValueList),
    {FirstFormat, FirstParams} = format_thrift_value(Type, FirstEntry, increment_depth(Opts)),
    LastEntry = hd(lists:reverse(ValueList)),
    {LastFormat, LastParams} = format_thrift_value(Type, LastEntry, increment_depth(Opts)),
    SkippedLength = length(ValueList) - 2,
    {
            "[" ++ FirstFormat ++ ", ...skipped ~b entry(-ies)..., " ++ LastFormat ++ "]",
            FirstParams ++ [SkippedLength] ++ LastParams
    };
format_thrift_value({set, _}, _, #{current_depth := CD, max_depth := MD})
    when MD >= 0, CD >= MD ->
    {"{...}",[]};
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
format_thrift_value({map, _}, _, #{current_depth := CD, max_depth := MD})
    when MD >= 0, CD >= MD ->
    {"#{...}",[]};
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
format_struct(_Module, Struct, _StructValue, #{current_depth := CD, max_depth := MD})
    when MD >= 0, CD > MD ->
    {to_string(Struct) ++ "{...}",[]};
format_struct(Module, Struct, StructValue, Opts) ->
    %% struct and exception have same structure
    {struct, _, StructMeta} = Module:struct_info(Struct),
    ValueList = tl(tuple_to_list(StructValue)), %% Remove record name
    case length(StructMeta) == length(ValueList) of
        true ->
            {Params, Values} =
                format_struct_(StructMeta, ValueList, {[], []}, increment_depth(Opts)),
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
format_union(_Module, Struct, _StructValue, #{current_depth := CD, max_depth := MD})
    when MD >= 0, CD > MD ->
    {to_string(Struct) ++ "{...}",[]};
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

normalize_options(Opts) ->
    CurrentDepth = maps:get(current_depth, Opts, 0),
    MaxDepth = maps:get(max_depth, Opts, -1),
    Opts#{
        current_depth => CurrentDepth,
        max_depth => MaxDepth
    }.

increment_depth(Opts = #{current_depth := CD}) ->
    Opts#{current_depth => CD + 1}.

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
    <<"Nezahualcoyotl 109 Piso 8, Centro, 06082, MEXICO">>, <<"NaN">>,
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
    {payproc_ShopAccountParams, {domain_CurrencyRef, <<"RUB">>}}}}}]]
    ).

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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{",
            "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ",
            "ContractModification{creation = ContractParams{template = ContractTemplateRef{id = 1}, ",
            "payment_institution = PaymentInstitutionRef{id = 1}, contractor = Contractor{legal_entity = ",
            "LegalEntity{russian_legal_entity = RussianLegalEntity{registered_name = 'Hoofs & Horns OJSC', ",
            "registered_number = '1234509876', inn = '1213456789012', actual_address = 'Nezahualcoyotl 109 Piso 8, ",
            "Centro, 06082, MEXICO', post_address = 'NaN', representative_position = 'Director', ",
            "representative_full_name = 'Someone', representative_document = '100$ banknote', ",
            "russian_bank_account = RussianBankAccount{account = '4276300010908312893', bank_name = 'SomeBank', ",
            "bank_post_account = '123129876', bank_bik = '66642666'}}}}}}}}, ...skipped 2 entry(-ies)..., ",
            "PartyModification{shop_modification = ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ",
            "ShopModification{shop_account_creation = ShopAccountParams{currency = CurrencyRef{",
            "symbolic_code = 'RUB'}}}}}])"
        ]),
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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [...])"
        ]),
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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{...}, ...skipped ",
            "2 entry(-ies)..., PartyModification{...}])"
        ]),
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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{",
            "contract_modification = ContractModificationUnit{...}}, ...skipped 2 entry(-ies)..., ",
            "PartyModification{shop_modification = ShopModificationUnit{...}}])"
        ]),
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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{",
            "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ",
            "ContractModification{...}}}, ...skipped 2 entry(-ies)..., PartyModification{shop_modification = ",
            "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{...}}}])"
        ]),
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
        lists:flatten([
            "PartyManagement:CreateClaim(party_id = '1CR1Xziml7o', changeset = [PartyModification{",
            "contract_modification = ContractModificationUnit{id = '1CR1Y2ZcrA0', modification = ",
            "ContractModification{...}}}, ...skipped 2 entry(-ies)..., PartyModification{shop_modification = ",
            "ShopModificationUnit{id = '1CR1Y2ZcrA2', modification = ShopModification{...}}}])"
        ]),
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
        lists:flatten([
            "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<...>>}, machine = Machine{ns = 'party', ",
            "id = '1CSHThTEJ84', history = [...], history_range = HistoryRange{...}, aux_state = Content{...}, ",
            "aux_state_legacy = Value{...}}})"
        ]),
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
        lists:flatten([
            "Processor:ProcessCall(a = CallArgs{arg = Value{bin = <<...>>}, machine = Machine{ns = 'party', ",
            "id = '1CSHThTEJ84', history = [Event{...}], history_range = HistoryRange{limit = 10, direction = ",
            "backward}, aux_state = Content{data = Value{...}}, aux_state_legacy = Value{obj = #{Value{...} => ",
            "Value{...}, Value{...} => Value{...}}}}})"
        ]),
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

-endif.