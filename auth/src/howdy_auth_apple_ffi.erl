-module(howdy_auth_apple_ffi).
-export([client_secret/6]).
-include_lib("public_key/include/public_key.hrl").

%% Sign in with Apple authenticates the client with a short-lived ES256 JWT
%% signed by the developer's P-256 key (the .p8 download), not a shared secret.
%% JWS wants the raw R||S signature; OTP produces DER, so it is re-encoded.
client_secret(Pem, KeyId, TeamId, ClientId, Now, Lifetime)
  when byte_size(Pem) =< 8192, Lifetime > 0, Lifetime =< 15777000 ->
    try
        [Entry] = public_key:pem_decode(Pem),
        Key = #'ECPrivateKey'{parameters = {namedCurve, ?'secp256r1'}} =
            public_key:pem_entry_decode(Entry),
        Header = b64(json:encode(#{<<"alg">> => <<"ES256">>, <<"kid">> => KeyId})),
        Claims = b64(json:encode(#{<<"iss">> => TeamId, <<"iat">> => Now,
                                   <<"exp">> => Now + Lifetime,
                                   <<"aud">> => <<"https://appleid.apple.com">>,
                                   <<"sub">> => ClientId})),
        Signing = <<Header/binary, ".", Claims/binary>>,
        Der = public_key:sign(Signing, sha256, Key),
        #'ECDSA-Sig-Value'{r = R, s = S} = public_key:der_decode('ECDSA-Sig-Value', Der),
        Signature = b64(<<R:256/unsigned-big, S:256/unsigned-big>>),
        {ok, <<Signing/binary, ".", Signature/binary>>}
    catch _:_ -> {error, nil} end;
client_secret(_, _, _, _, _, _) -> {error, nil}.

b64(Value) -> base64:encode(iolist_to_binary(Value), #{mode => urlsafe, padding => false}).
