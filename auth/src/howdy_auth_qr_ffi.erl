-module(howdy_auth_qr_ffi).
-export([svg/1]).

%% QR Code Model 2 (ISO/IEC 18004): byte mode, error correction level M, the
%% smallest version that fits, and the mask with the lowest penalty. The
%% result is a standalone SVG with the standard four-module quiet zone.

svg(Text) when is_binary(Text) ->
    case version(byte_size(Text), 1) of
        none -> {error, nil};
        V -> {ok, render(matrix(Text, V), 17 + 4 * V)}
    end.

%% Error correction codewords per block, then {blocks, data codewords each}.
ec(1) -> {10, [{1, 16}]};
ec(2) -> {16, [{1, 28}]};
ec(3) -> {26, [{1, 44}]};
ec(4) -> {18, [{2, 32}]};
ec(5) -> {24, [{2, 43}]};
ec(6) -> {16, [{4, 27}]};
ec(7) -> {18, [{4, 31}]};
ec(8) -> {22, [{2, 38}, {2, 39}]};
ec(9) -> {22, [{3, 36}, {2, 37}]};
ec(10) -> {26, [{4, 43}, {1, 44}]};
ec(11) -> {30, [{1, 50}, {4, 51}]};
ec(12) -> {22, [{6, 36}, {2, 37}]};
ec(13) -> {22, [{8, 37}, {1, 38}]};
ec(14) -> {24, [{4, 40}, {5, 41}]};
ec(15) -> {24, [{5, 41}, {5, 42}]};
ec(16) -> {28, [{7, 45}, {3, 46}]};
ec(17) -> {28, [{10, 46}, {1, 47}]};
ec(18) -> {26, [{9, 43}, {4, 44}]};
ec(19) -> {26, [{3, 44}, {11, 45}]};
ec(20) -> {26, [{3, 41}, {13, 42}]};
ec(21) -> {26, [{17, 42}]};
ec(22) -> {28, [{17, 46}]};
ec(23) -> {28, [{4, 47}, {14, 48}]};
ec(24) -> {28, [{6, 45}, {14, 46}]};
ec(25) -> {28, [{8, 47}, {13, 48}]};
ec(26) -> {28, [{19, 46}, {4, 47}]};
ec(27) -> {28, [{22, 45}, {3, 46}]};
ec(28) -> {28, [{3, 45}, {23, 46}]};
ec(29) -> {28, [{21, 45}, {7, 46}]};
ec(30) -> {28, [{19, 47}, {10, 48}]};
ec(31) -> {28, [{2, 46}, {29, 47}]};
ec(32) -> {28, [{10, 46}, {23, 47}]};
ec(33) -> {28, [{14, 46}, {21, 47}]};
ec(34) -> {28, [{14, 46}, {23, 47}]};
ec(35) -> {28, [{12, 47}, {26, 48}]};
ec(36) -> {28, [{6, 47}, {34, 48}]};
ec(37) -> {28, [{29, 46}, {14, 47}]};
ec(38) -> {28, [{13, 46}, {32, 47}]};
ec(39) -> {28, [{40, 47}, {7, 48}]};
ec(40) -> {28, [{18, 47}, {31, 48}]}.

data_capacity(V) ->
    {_, Groups} = ec(V),
    lists:sum([N * D || {N, D} <- Groups]).

count_bits(V) when V < 10 -> 8;
count_bits(_) -> 16.

version(_, 41) -> none;
version(Len, V) ->
    case 4 + count_bits(V) + 8 * Len =< 8 * data_capacity(V) of
        true -> V;
        false -> version(Len, V + 1)
    end.

%% --- Codewords ---------------------------------------------------------------

data(Text, V) ->
    Capacity = data_capacity(V),
    Bits = <<4:4, (byte_size(Text)):(count_bits(V)), Text/binary>>,
    Terminated = <<Bits/bitstring, 0:(min(4, Capacity * 8 - bit_size(Bits)))>>,
    Bytes = <<Terminated/bitstring, 0:((8 - bit_size(Terminated) rem 8) rem 8)>>,
    Fill = [case I rem 2 of 0 -> 16#EC; 1 -> 16#11 end
            || I <- lists:seq(0, Capacity - byte_size(Bytes) - 1)],
    <<Bytes/binary, (list_to_binary(Fill))/binary>>.

codewords(Text, V) ->
    {Ec, Groups} = ec(V),
    Blocks = split(data(Text, V), lists:append([lists:duplicate(N, D) || {N, D} <- Groups])),
    Divisor = divisor(Ec),
    interleave(Blocks) ++ interleave([remainder(B, Divisor) || B <- Blocks]).

split(<<>>, []) -> [];
split(Bin, [N | Ns]) ->
    <<Block:N/binary, Rest/binary>> = Bin,
    [binary_to_list(Block) | split(Rest, Ns)].

interleave(Lists) ->
    case [L || L <- Lists, L =/= []] of
        [] -> [];
        Live -> [hd(L) || L <- Live] ++ interleave([tl(L) || L <- Live])
    end.

%% Reed-Solomon over GF(2^8) with the QR polynomial x^8+x^4+x^3+x^2+1.
mul(X, Y) -> mul(X, Y, 7, 0).
mul(_, _, -1, Z) -> Z;
mul(X, Y, I, Z) ->
    Shifted = (Z bsl 1) bxor ((Z bsr 7) * 16#11D),
    mul(X, Y, I - 1, Shifted bxor (((Y bsr I) band 1) * X)).

divisor(Degree) ->
    {Result, _} = lists:foldl(
        fun(_, {R, Root}) ->
            {[mul(A, Root) bxor B || {A, B} <- lists:zip(R, tl(R) ++ [0])], mul(Root, 2)}
        end,
        {lists:duplicate(Degree - 1, 0) ++ [1], 1},
        lists:seq(1, Degree)),
    Result.

remainder(Data, Divisor) ->
    lists:foldl(
        fun(Byte, R) ->
            Factor = Byte bxor hd(R),
            [X bxor mul(D, Factor) || {X, D} <- lists:zip(tl(R) ++ [0], Divisor)]
        end,
        lists:duplicate(length(Divisor), 0),
        Data).

%% --- Layout ------------------------------------------------------------------

%% Modules as #{{X, Y} => Dark}; function modules are never masked.
matrix(Text, V) ->
    Size = 17 + 4 * V,
    Function = maps:from_list([{{X, Y}, D} || {X, Y, D} <- patterns(V, Size)]),
    Bits = [B =:= 1 || Byte <- codewords(Text, V), <<B:1>> <= <<Byte>>],
    Free = zigzag(Size, Function),
    Data = place(Free, Bits, #{}),
    Candidates = [begin
                      Masked = maps:map(fun({X, Y}, D) -> D xor mask(K, X, Y) end, Data),
                      M = maps:merge(maps:merge(Function, Masked), format(K, Size)),
                      {penalty(M, Size), M}
                  end || K <- lists:seq(0, 7)],
    %% A stable sort keeps the lowest mask number among equal penalties.
    [{_, Best} | _] = lists:keysort(1, Candidates),
    Best.

place([], _, Acc) -> Acc;
place([P | Ps], [], Acc) -> place(Ps, [], Acc#{P => false});
place([P | Ps], [B | Bs], Acc) -> place(Ps, Bs, Acc#{P => B}).

zigzag(Size, Function) ->
    [{X, Y} || Right <- columns(Size - 1),
               Vert <- lists:seq(0, Size - 1),
               J <- [0, 1],
               X <- [Right - J],
               Y <- [case (Right + 1) band 2 of 0 -> Size - 1 - Vert; _ -> Vert end],
               not maps:is_key({X, Y}, Function)].

columns(R) when R < 1 -> [];
columns(6) -> columns(5);
columns(R) -> [R | columns(R - 2)].

%% Later entries overwrite earlier ones, as when drawn in this order.
patterns(V, Size) ->
    Timing = lists:append([[{6, I, I rem 2 =:= 0}, {I, 6, I rem 2 =:= 0}]
                           || I <- lists:seq(0, Size - 1)]),
    Finders = [{X + DX, Y + DY, max(abs(DX), abs(DY)) rem 2 =:= 1 orelse max(abs(DX), abs(DY)) =:= 0}
               || {X, Y} <- [{3, 3}, {Size - 4, 3}, {3, Size - 4}],
                  DX <- lists:seq(-4, 4), DY <- lists:seq(-4, 4),
                  X + DX >= 0, X + DX < Size, Y + DY >= 0, Y + DY < Size],
    Positions = alignment(V, Size),
    Last = length(Positions) - 1,
    Alignment = [{X + DX, Y + DY, max(abs(DX), abs(DY)) =/= 1}
                 || {I, X} <- lists:enumerate(0, Positions),
                    {J, Y} <- lists:enumerate(0, Positions),
                    not ({I, J} =:= {0, 0} orelse {I, J} =:= {0, Last} orelse {I, J} =:= {Last, 0}),
                    DX <- lists:seq(-2, 2), DY <- lists:seq(-2, 2)],
    Format = [{X, Y, D} || {{X, Y}, D} <- maps:to_list(format(0, Size))],
    Timing ++ Finders ++ Alignment ++ Format ++ version_info(V, Size).

alignment(1, _) -> [];
alignment(V, Size) ->
    Count = V div 7 + 2,
    Step = (V * 8 + Count * 3 + 5) div (Count * 4 - 4) * 2,
    [6 | lists:reverse([Size - 7 - I * Step || I <- lists:seq(0, Count - 2)])].

%% Level M is 00; the dark module sits beside the lower-left finder.
format(Mask, Size) ->
    Data = Mask,
    Rem = lists:foldl(fun(_, R) -> (R bsl 1) bxor ((R bsr 9) * 16#537) end, Data, lists:seq(1, 10)),
    Bits = ((Data bsl 10) bor Rem) bxor 16#5412,
    Bit = fun(I) -> (Bits bsr I) band 1 =:= 1 end,
    maps:from_list(
        [{{8, I}, Bit(I)} || I <- lists:seq(0, 5)] ++
        [{{8, 7}, Bit(6)}, {{8, 8}, Bit(7)}, {{7, 8}, Bit(8)}] ++
        [{{14 - I, 8}, Bit(I)} || I <- lists:seq(9, 14)] ++
        [{{Size - 1 - I, 8}, Bit(I)} || I <- lists:seq(0, 7)] ++
        [{{8, Size - 15 + I}, Bit(I)} || I <- lists:seq(8, 14)] ++
        [{{8, Size - 8}, true}]).

version_info(V, _) when V < 7 -> [];
version_info(V, Size) ->
    Rem = lists:foldl(fun(_, R) -> (R bsl 1) bxor ((R bsr 11) * 16#1F25) end, V, lists:seq(1, 12)),
    Bits = (V bsl 12) bor Rem,
    lists:append([begin
                      D = (Bits bsr I) band 1 =:= 1,
                      A = Size - 11 + I rem 3,
                      B = I div 3,
                      [{A, B, D}, {B, A, D}]
                  end || I <- lists:seq(0, 17)]).

mask(0, X, Y) -> (X + Y) rem 2 =:= 0;
mask(1, _, Y) -> Y rem 2 =:= 0;
mask(2, X, _) -> X rem 3 =:= 0;
mask(3, X, Y) -> (X + Y) rem 3 =:= 0;
mask(4, X, Y) -> (X div 3 + Y div 2) rem 2 =:= 0;
mask(5, X, Y) -> X * Y rem 2 + X * Y rem 3 =:= 0;
mask(6, X, Y) -> (X * Y rem 2 + X * Y rem 3) rem 2 =:= 0;
mask(7, X, Y) -> ((X + Y) rem 2 + X * Y rem 3) rem 2 =:= 0.

%% --- Mask penalty ------------------------------------------------------------

penalty(M, Size) ->
    Seq = lists:seq(0, Size - 1),
    Rows = [[maps:get({X, Y}, M) || X <- Seq] || Y <- Seq],
    Cols = [[maps:get({X, Y}, M) || Y <- Seq] || X <- Seq],
    Lines = Rows ++ Cols,
    Runs = lists:sum([run_penalty(L) || L <- Lines]),
    Finder = lists:sum([finder_penalty([false, false, false, false | L] ++ [false, false, false, false])
                        || L <- Lines]),
    Boxes = 3 * length([1 || X <- lists:seq(0, Size - 2), Y <- lists:seq(0, Size - 2),
                             begin
                                 C = maps:get({X, Y}, M),
                                 C =:= maps:get({X + 1, Y}, M) andalso C =:= maps:get({X, Y + 1}, M)
                                     andalso C =:= maps:get({X + 1, Y + 1}, M)
                             end]),
    Dark = length([1 || R <- Rows, D <- R, D]),
    Total = Size * Size,
    K = (abs(Dark * 20 - Total * 10) + Total - 1) div Total - 1,
    Runs + Boxes + Finder + K * 10.

run_penalty([]) -> 0;
run_penalty([C | Rest]) -> run_penalty(Rest, C, 1).
run_penalty([C | Rest], C, N) -> run_penalty(Rest, C, N + 1);
run_penalty(Rest, _, N) ->
    Here = case N >= 5 of true -> N - 2; false -> 0 end,
    Here + run_penalty(Rest).

finder_penalty(L) when length(L) < 11 -> 0;
finder_penalty([_ | Rest] = L) ->
    Window = lists:sublist(L, 11),
    Hit = Window =:= [true, false, true, true, true, false, true, false, false, false, false]
        orelse Window =:= [false, false, false, false, true, false, true, true, true, false, true],
    (case Hit of true -> 40; false -> 0 end) + finder_penalty(Rest).

%% --- Output ------------------------------------------------------------------

render(M, Size) ->
    W = integer_to_binary(Size + 8),
    Path = [runs([maps:get({X, Y}, M) || X <- lists:seq(0, Size - 1)], 0, Y)
            || Y <- lists:seq(0, Size - 1)],
    iolist_to_binary([
        <<"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 ">>, W, <<" ">>, W,
        <<"\" shape-rendering=\"crispEdges\"><rect width=\"">>, W, <<"\" height=\"">>, W,
        <<"\" fill=\"#fff\"/><path fill=\"#000\" d=\"">>, Path, <<"\"/></svg>">>]).

runs([], _, _) -> [];
runs([false | Rest], X, Y) -> runs(Rest, X + 1, Y);
runs(Row, X, Y) ->
    {Dark, Rest} = lists:splitwith(fun(D) -> D end, Row),
    N = integer_to_binary(length(Dark)),
    [<<"M">>, integer_to_binary(X + 4), <<" ">>, integer_to_binary(Y + 4),
     <<"h">>, N, <<"v1h-">>, N, <<"z">> | runs(Rest, X + length(Dark), Y)].
