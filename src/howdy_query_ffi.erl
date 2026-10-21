%% Query string parsing for howdy/query.
-module(howdy_query_ffi).
-export([parse_query/1]).

%% -- Query strings ---------------------------------------------------------------
%%
%% One pass over the query string, no library calls: `&` separates pairs, the
%% first `=` separates key from value, `+` is a space and `%XY` a byte. A `%`
%% with fewer than two bytes after it in the same part is literal; with two
%% that are not both hex it is an error, as is anything that is not UTF-8
%% once decoded. A
%% pair without `=` has an empty value. Results match gleam/uri.parse_query
%% (OTP's uri_string:dissect_query), which the test suite fuzzes against,
%% with one deliberate difference: `&#` is literal here. OTP treats it as an
%% HTML numeric character reference, decoding `&#65;` to `A` in some
%% positions and crashing on `&#` at the end of the string.
-define(IS_HEX(C), ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))).

parse_query(<<>>) ->
    {ok, []};
parse_query(Query) ->
    try
        {ok, query_key(Query, <<>>, false, [])}
    catch throw:invalid_query ->
        {error, nil}
    end.

%% Escaped tracks whether a percent-escape was decoded into the current
%% part; only then can the bytes be invalid UTF-8, since raw characters are
%% matched as UTF-8 as they are consumed.
query_key(<<$&, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<>>, false, [{query_part(Key, Escaped), <<>>} | Acc]);
query_key(<<$=, Rest/binary>>, Key, Escaped, Acc) ->
    query_value(Rest, query_part(Key, Escaped), <<>>, false, Acc);
query_key(<<>>, Key, Escaped, Acc) ->
    lists:reverse([{query_part(Key, Escaped), <<>>} | Acc]);
query_key(<<$+, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<Key/binary, $\s>>, Escaped, Acc);
query_key(<<$%, H, L, Rest/binary>>, Key, _Escaped, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    query_key(Rest, <<Key/binary, (hex(H) * 16 + hex(L))>>, true, Acc);
query_key(<<$%, H, L, _/binary>>, _Key, _Escaped, _Acc)
        when H =/= $&, H =/= $=, L =/= $&, L =/= $= ->
    throw(invalid_query);
query_key(<<C/utf8, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<Key/binary, C/utf8>>, Escaped, Acc);
query_key(_, _Key, _Escaped, _Acc) ->
    throw(invalid_query).

query_value(<<$&, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_key(Rest, <<>>, false, [{Key, query_part(Value, Escaped)} | Acc]);
query_value(<<>>, Key, Value, Escaped, Acc) ->
    lists:reverse([{Key, query_part(Value, Escaped)} | Acc]);
query_value(<<$+, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_value(Rest, Key, <<Value/binary, $\s>>, Escaped, Acc);
query_value(<<$%, H, L, Rest/binary>>, Key, Value, _Escaped, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    query_value(Rest, Key, <<Value/binary, (hex(H) * 16 + hex(L))>>, true, Acc);
query_value(<<$%, H, L, _/binary>>, _Key, _Value, _Escaped, _Acc)
        when H =/= $&, L =/= $& ->
    throw(invalid_query);
query_value(<<C/utf8, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_value(Rest, Key, <<Value/binary, C/utf8>>, Escaped, Acc);
query_value(_, _Key, _Value, _Escaped, _Acc) ->
    throw(invalid_query).

query_part(Part, false) ->
    Part;
query_part(Part, true) ->
    case unicode:characters_to_binary(Part) of
        Part -> Part;
        _ -> throw(invalid_query)
    end.

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10.
