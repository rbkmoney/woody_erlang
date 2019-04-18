-ifndef(__OTP_20_COMPATIBILITY__).
-define(__OTP_20_COMPATIBILITY__, included).

-ifdef(OTP_RELEASE).

  -if(?OTP_RELEASE >= 21).
    -define(
      STACKTRACE(ErrorType, Error, ErrorStackTrace),
      ErrorType:Error:ErrorStackTrace ->
    ).
  -else.
    -define(
      STACKTRACE(ErrorType, Error, ErrorStackTrace),
      ErrorType:Error ->
          ErrorStackTrace = erlang:get_stacktrace(),
    ).
  -endif.

-else.

  -define(
    STACKTRACE(ErrorType, Error, ErrorStackTrace),
    ErrorType:Error ->
        ErrorStackTrace = erlang:get_stacktrace(),
  ).

-endif. % ifdef(OTP_RELEASE)

-endif. % __OTP_20_COMPATIBILITY__