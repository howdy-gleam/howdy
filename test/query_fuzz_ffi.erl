-module(query_fuzz_ffi).
-export([matches_stdlib/0]).

%% howdy_query_ffi:parse_query must agree with gleam/uri.parse_query on every
%% input: the probed edge cases, then random strings over an alphabet dense
%% in the characters that matter.
matches_stdlib() ->
    Fixed = [<<>>, <<"a">>, <<"a=">>, <<"=a">>, <<"a=1&&b=2">>, <<"&a=1">>, <<"a=1&">>,
             <<"a=b=c">>, <<"a+b=c+d">>, <<"a%20b=%C3%A9">>, <<"a=%zz">>, <<"a=%C3">>,
             <<"a=%">>, <<"a;b=1">>, <<"a=1#x">>, <<"é=ü"/utf8>>, <<"a=1&a=2">>,
             <<"a%3Db=c%26d">>, <<"%">>, <<"a=b c">>, <<"a=%25">>, <<"a=%2">>, <<"a%">>,
             <<"a=%%20">>, <<"a=%2G">>, <<"a=%e2%82%ac">>, <<"a=%ff">>, <<"a=\x01">>,
             <<233, $=, 252>>, <<"a=%C3%A9%">>, <<"+=+">>, <<"%2B=%2b">>, <<"a=%F0%9F%98%80">>],
    lists:foreach(fun compare/1, Fixed),
    {ok, [{<<>>, <<>>}, {<<"#">>, <<>>}]} = howdy_query_ffi:parse_query(<<"&#">>),
    {ok, [{<<"a">>, <<"1">>}, {<<"#65;b">>, <<"2">>}]} = howdy_query_ffi:parse_query(<<"a=1&#65;b=2">>),
    {ok, [{<<>>, <<>>}, {<<"#65;">>, <<>>}]} = howdy_query_ffi:parse_query(<<"&#65;">>),
    Alphabet = [$a, $b, $z, $A, $0, $9, $%, $%, $%, $+, $&, $=, $;, $\s, $G, $f, $F, $2, $#, $/,
                <<"é"/utf8>>, <<"€"/utf8>>, <<233>>],
    rand:seed(exsss, {1, 2, 3}),
    lists:foreach(fun(_) ->
        Len = rand:uniform(12) - 1,
        Q = iolist_to_binary([lists:nth(rand:uniform(length(Alphabet)), Alphabet) || _ <- lists:seq(1, Len)]),
        compare(Q)
    end, lists:seq(1, 30000)),
    nil.

%% OTP reads `&#` as an HTML numeric character reference, inconsistently
%% and sometimes crashing; howdy keeps it literal, so those inputs are
%% checked separately below rather than against the stdlib.
compare(Q) ->
    case binary:match(Q, <<"&#">>) of
        nomatch ->
            Expected = gleam_stdlib:parse_query(Q),
            case howdy_query_ffi:parse_query(Q) of
                Expected -> ok;
                Actual -> error({query_mismatch, Q, Expected, Actual})
            end;
        _ ->
            ok
    end.
