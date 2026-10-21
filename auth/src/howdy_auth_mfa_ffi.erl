-module(howdy_auth_mfa_ffi).
-export([new_secret/0, otp/0, backup/0, seal/3, open/3, verify_totp/4]).

new_secret() -> base32(crypto:strong_rand_bytes(20)).
otp() -> pad(binary:decode_unsigned(crypto:strong_rand_bytes(8)) rem 1000000).
backup() -> base32(crypto:strong_rand_bytes(10)).

seal(Key, Owner, Plain) ->
    try
        Nonce = crypto:strong_rand_bytes(12),
        {Cipher, Tag} = crypto:crypto_one_time_aead(aes_256_gcm, un64(Key), Nonce, Plain, Owner, 16, true),
        {ok, b64(<<Nonce/binary, Tag/binary, Cipher/binary>>)}
    catch _:_ -> {error, nil} end.
open(Key, Owner, Encoded) ->
    try
        <<Nonce:12/binary, Tag:16/binary, Cipher/binary>> = un64(Encoded),
        Plain = crypto:crypto_one_time_aead(aes_256_gcm, un64(Key), Nonce, Cipher, Owner, Tag, false),
        true = is_binary(Plain),
        {ok, Plain}
    catch _:_ -> {error, nil} end.

%% RFC 6238 SHA-1, six digits, 30-second step, +/- one step of clock skew.
%% A successful step must exceed the last accepted step (global replay fence).
verify_totp(Seed, Code, After, Now) when byte_size(Code) =:= 6, Now >= 0 ->
    try
        true = lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Code)),
        Key = unbase32(Seed),
        Current = Now div 30,
        Matches = [Step || Step <- [Current - 1, Current, Current + 1],
                           Step >= 0, Step > After,
                           crypto:hash_equals(totp(Key, Step), Code)],
        case Matches of [] -> {error, nil}; _ -> {ok, lists:max(Matches)} end
    catch _:_ -> {error, nil} end;
verify_totp(_, _, _, _) -> {error, nil}.
totp(Key, Step) ->
    Hash = crypto:mac(hmac, sha, Key, <<Step:64/unsigned-big>>),
    Offset = binary:last(Hash) band 15,
    <<_:Offset/binary, Value:32/unsigned-big, _/binary>> = Hash,
    pad((Value band 16#7fffffff) rem 1000000).
pad(N) -> list_to_binary(io_lib:format("~6..0B", [N])).
base32(Bytes) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    << <<(binary:at(Alphabet, N))>> || <<N:5>> <= Bytes >>.
unbase32(Text) ->
    Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567",
    << <<(index(C, Alphabet, 0)):5>> || <<C>> <= Text >>.
index(C, [C|_], N) -> N;
index(C, [_|Rest], N) -> index(C, Rest, N + 1).
b64(Bytes) -> base64:encode(Bytes, #{mode => urlsafe, padding => false}).
un64(Text) -> base64:decode(Text, #{mode => urlsafe, padding => false}).
