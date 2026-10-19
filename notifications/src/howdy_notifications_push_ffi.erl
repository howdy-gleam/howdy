%% Cryptography for howdy/notifications/web_push: P-256 keys, ECDH, HMAC,
%% AES-128-GCM and ES256 signatures, all from OTP's crypto.
-module(howdy_notifications_push_ffi).
-export([generate_keys/0, public_key/1, ecdh/2, hmac/2, encrypt/3,
         sign/2, verify/3, random_bytes/1, decrypt/4]).

%% {Public, Private}: a 65 byte uncompressed point and a 32 byte scalar.
generate_keys() ->
    crypto:generate_key(ecdh, prime256v1).

%% The public key of a private key, or an error if it is not one.
public_key(Private) when byte_size(Private) =:= 32 ->
    try crypto:generate_key(ecdh, prime256v1, Private) of
        {Public, _} -> {ok, Public}
    catch
        _:_ -> {error, nil}
    end;
public_key(_) ->
    {error, nil}.

ecdh(TheirPublic, MyPrivate) ->
    try
        {ok, crypto:compute_key(ecdh, TheirPublic, MyPrivate, prime256v1)}
    catch
        _:_ -> {error, nil}
    end.

hmac(Key, Data) ->
    crypto:mac(hmac, sha256, Key, Data).

%% AES-128-GCM with no associated data: the ciphertext with its tag after it.
encrypt(Key, Nonce, Plaintext) ->
    {Ciphertext, Tag} =
        crypto:crypto_one_time_aead(aes_128_gcm, Key, Nonce, Plaintext, <<>>, true),
    <<Ciphertext/binary, Tag/binary>>.

%% The reverse, for tests.
decrypt(Key, Nonce, Sealed, TagSize) ->
    Size = byte_size(Sealed) - TagSize,
    <<Ciphertext:Size/binary, Tag/binary>> = Sealed,
    case crypto:crypto_one_time_aead(aes_128_gcm, Key, Nonce, Ciphertext, <<>>, Tag, false) of
        error -> {error, nil};
        Plaintext -> {ok, Plaintext}
    end.

%% An ES256 signature as JWS wants it: r and s, 32 bytes each, rather than
%% the DER that crypto gives.
sign(Message, Private) ->
    Der = crypto:sign(ecdsa, sha256, Message, [Private, prime256v1]),
    {'ECDSA-Sig-Value', R, S} = public_key:der_decode('ECDSA-Sig-Value', Der),
    <<R:256, S:256>>.

verify(Message, <<R:256, S:256>>, Public) ->
    Der = public_key:der_encode('ECDSA-Sig-Value', {'ECDSA-Sig-Value', R, S}),
    crypto:verify(ecdsa, sha256, Message, Der, [Public, prime256v1]);
verify(_, _, _) ->
    false.

random_bytes(Size) ->
    crypto:strong_rand_bytes(Size).
