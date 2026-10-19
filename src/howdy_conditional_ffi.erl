%% HTTP dates and entity tag hashes for howdy/conditional.
-module(howdy_conditional_ffi).
-export([http_date/1, parse_http_date/1, digest/1]).

%% The first 128 bits of the SHA-256 of `Bin`: plenty to tell versions of
%% one resource apart, and short enough to keep the header small.
digest(Bin) ->
    <<Head:16/binary, _/binary>> = crypto:hash(sha256, Bin),
    Head.

%% Seconds since the epoch as an IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`.
%% Formatted here rather than with `httpd_util:rfc1123_date/1`, which takes
%% local time and shifts it.
http_date(Seconds) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    Day = element(calendar:day_of_the_week(Y, Mo, D),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Month = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}),
    unicode:characters_to_binary(
        io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
                      [Day, D, Month, Y, H, Mi, S])).

%% An HTTP date to seconds since the epoch, in any of the three formats
%% RFC 9110 requires recipients to accept: the IMF-fixdate servers send,
%% `Sun, 06 Nov 1994 08:49:37 GMT`, and the obsolete RFC 850,
%% `Sunday, 06-Nov-94 08:49:37 GMT`, and asctime, `Sun Nov  6 08:49:37 1994`.
%% `if-unmodified-since` guards writes, so a date that is not understood
%% must not quietly let one through. `httpd_util:convert_request_date` is
%% not used because it shifts the result by the local time zone.
parse_http_date(Date) ->
    try
        {ok, seconds(fields(Date))}
    catch
        _:_ -> {error, nil}
    end.

fields(<<_:3/binary, ", ", D:2/binary, " ", Mon:3/binary, " ", Y:4/binary, " ",
         Time:8/binary, " GMT">>) ->
    {b2i(Y), Mon, b2i(D), Time};
fields(<<_:3/binary, " ", Mon:3/binary, " ", D:2/binary, " ", Time:8/binary, " ",
         Y:4/binary>>) ->
    {b2i(Y), Mon, b2i(string:trim(D, leading)), Time};
fields(Date) ->
    [_Weekday, <<D:2/binary, "-", Mon:3/binary, "-", YY:2/binary, " ",
                 Time:8/binary, " GMT">>] = binary:split(Date, <<", ">>),
    {{two_digit, b2i(YY)}, Mon, b2i(D), Time}.

%% A two-digit year is in this century, unless that puts the timestamp more
%% than 50 years in the future: then it is the most recent past year with
%% those digits (RFC 9110, section 5.6.7). The whole timestamp is compared,
%% not just the year.
seconds({{two_digit, YY}, Mon, D, Time}) ->
    {{Now, _, _}, _} = calendar:universal_time(),
    Candidate = seconds({Now - Now rem 100 + YY, Mon, D, Time}),
    Limit = erlang:system_time(second) + fifty_years(),
    case Candidate > Limit of
        true -> seconds({Now - Now rem 100 + YY - 100, Mon, D, Time});
        false -> Candidate
    end;
seconds({Y, Mon, D, <<H:2/binary, ":", Mi:2/binary, ":", S:2/binary>>}) ->
    Date = {Y, month(Mon), D},
    true = calendar:valid_date(Date),
    {Hour, Minute, Second} = {b2i(H), b2i(Mi), b2i(S)},
    %% 60 is a leap second, which the calendar module has no room for; it
    %% is the same instant as the next second, which is all a comparison
    %% with a modification time needs.
    true = Hour < 24 andalso Minute < 60 andalso Second =< 60,
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    calendar:datetime_to_gregorian_seconds({Date, {0, 0, 0}}) - Epoch
        + Hour * 3600 + Minute * 60 + Second.

%% Fifty years from today, in seconds, leap days included.
fifty_years() ->
    {{Y, M, D}, Time} = calendar:universal_time(),
    Later = case calendar:valid_date(Y + 50, M, D) of
        true -> {Y + 50, M, D};
        false -> {Y + 50, M, D - 1}
    end,
    calendar:datetime_to_gregorian_seconds({Later, Time})
        - calendar:datetime_to_gregorian_seconds({{Y, M, D}, Time}).

b2i(Bin) -> binary_to_integer(Bin).

month(<<"Jan">>) -> 1;
month(<<"Feb">>) -> 2;
month(<<"Mar">>) -> 3;
month(<<"Apr">>) -> 4;
month(<<"May">>) -> 5;
month(<<"Jun">>) -> 6;
month(<<"Jul">>) -> 7;
month(<<"Aug">>) -> 8;
month(<<"Sep">>) -> 9;
month(<<"Oct">>) -> 10;
month(<<"Nov">>) -> 11;
month(<<"Dec">>) -> 12.
