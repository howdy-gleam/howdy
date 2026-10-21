%% File and date helpers for howdy_storage: reading a file a part at a
%% time, hashing a file without holding it in memory, and HTTP dates.
-module(howdy_storage_ffi).
-export([read_part/3, md5_file/1, parse_http_date/1, random_name/0,
         delete_empty_directory/1]).

%% Size bytes of the file at Path from Offset, or fewer at its end.
read_part(Path, Offset, Size) ->
    case file:open(Path, [read, raw, binary]) of
        {ok, File} ->
            try file:pread(File, Offset, Size) of
                {ok, Data} -> {ok, Data};
                eof -> {ok, <<>>};
                {error, Reason} -> {error, describe(Reason)}
            after
                file:close(File)
            end;
        {error, Reason} -> {error, describe(Reason)}
    end.

%% The MD5 of a file as lowercase hex, read in 1 MiB pieces.
md5_file(Path) ->
    case file:open(Path, [read, raw, binary, {read_ahead, 1048576}]) of
        {ok, File} ->
            try md5_loop(File, crypto:hash_init(md5))
            after file:close(File)
            end;
        {error, Reason} -> {error, describe(Reason)}
    end.

md5_loop(File, State) ->
    case file:read(File, 1048576) of
        {ok, Data} -> md5_loop(File, crypto:hash_update(State, Data));
        eof -> {ok, binary:encode_hex(crypto:hash_final(State), lowercase)};
        {error, Reason} -> {error, describe(Reason)}
    end.

describe(Reason) ->
    unicode:characters_to_binary(file:format_error(Reason)).

%% Remove a directory only if it is empty.
delete_empty_directory(Path) ->
    case file:del_dir(Path) of
        ok -> {ok, nil};
        {error, _} -> {error, nil}
    end.

random_name() ->
    binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

%% An IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`, to seconds since the
%% epoch. Not `httpd_util:convert_request_date`, which shifts the result by
%% the local time zone.
parse_http_date(<<_Day:3/binary, ", ", D:2/binary, " ", Mon:3/binary, " ",
                  Y:4/binary, " ", H:2/binary, ":", Mi:2/binary, ":",
                  S:2/binary, " GMT">>) ->
    try
        Months = [<<"Jan">>, <<"Feb">>, <<"Mar">>, <<"Apr">>, <<"May">>, <<"Jun">>,
                  <<"Jul">>, <<"Aug">>, <<"Sep">>, <<"Oct">>, <<"Nov">>, <<"Dec">>],
        Month = index_of(Mon, Months, 1),
        Date = {binary_to_integer(Y), Month, binary_to_integer(D)},
        true = calendar:valid_date(Date),
        Time = {binary_to_integer(H), binary_to_integer(Mi), binary_to_integer(S)},
        Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
        {ok, calendar:datetime_to_gregorian_seconds({Date, Time}) - Epoch}
    catch
        _:_ -> {error, nil}
    end;
parse_http_date(_) ->
    {error, nil}.

index_of(Item, [Item | _], N) -> N;
index_of(Item, [_ | Rest], N) -> index_of(Item, Rest, N + 1).
