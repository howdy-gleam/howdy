%% Signing for howdy/flash: an HMAC over the cookie's payload, and a
%% comparison that takes the same time however much of it matches.
-module(howdy_flash_ffi).
-export([hmac/2, equal/2]).

hmac(Key, Data) ->
    crypto:mac(hmac, sha256, Key, Data).

equal(A, B) when byte_size(A) =:= byte_size(B) ->
    crypto:hash_equals(A, B);
equal(_, _) ->
    false.
