-module(howdy_auth_sso_ffi).
-export([valid_certificate/1, public_host/1, dispatch/7]).

%% Exactly one unencrypted X.509 certificate that OTP can decode. Nothing about
%% its chain or dates is judged: a SAML signing certificate is pinned, not
%% validated against an authority, and providers routinely self-sign them.
valid_certificate(Pem) when byte_size(Pem) =< 16384 ->
    try
        [{'Certificate', Der, not_encrypted}] = public_key:pem_decode(Pem),
        _ = public_key:pkix_decode_cert(Der, otp),
        true
    catch _:_ -> false end;
valid_certificate(_) -> false.

%% True when Host resolves, and only to addresses on the public internet.
public_host(Host) ->
    case public_address(Host) of
        {ok, _} -> true;
        {error, nil} -> false
    end.

%% The address to connect to when Host resolves, and only to addresses on the
%% public internet. A customer-supplied URL must not reach loopback, private
%% networks, link-local metadata services or the like. The name is resolved
%% exactly once: `dispatch/7` connects to the address vetted here, so a name
%% that re-resolves differently between check and connect (DNS rebinding)
%% changes nothing. IPv4 is preferred; a host reachable only over IPv6 must be
%% public there too.
public_address(Host) when byte_size(Host) > 0, byte_size(Host) =< 253 ->
    try
        Name = binary_to_list(Host),
        V4 = addresses(Name, inet),
        V6 = addresses(Name, inet6),
        Found = V4 ++ V6,
        case Found =/= [] andalso lists:all(fun public/1, Found) of
            true -> {ok, hd(Found)};
            false -> {error, nil}
        end
    catch _:_ -> {error, nil} end;
public_address(_) -> {error, nil}.

addresses(Name, Family) ->
    case inet:getaddrs(Name, Family) of
        {ok, Found} -> Found;
        {error, _} -> []
    end.

%% Where an HTTPS request for Host goes: {Address, Port, TrustedCAs}. Tests
%% may pin a name they play on loopback, with the authority that signed its
%% certificate, through `howdy_auth_test_ffi:with_pinned_idp/3`; nothing else
%% sets that term.
endpoint(Host) ->
    case maps:find(Host, persistent_term:get({?MODULE, pinned}, #{})) of
        {ok, Pinned} -> {ok, Pinned};
        error ->
            case public_address(Host) of
                {ok, Address} -> {ok, {Address, 443, public_key:cacerts_get()}};
                {error, nil} -> {error, nil}
            end
    end.

%% An HTTPS request to Host, connected to the address vetted for it. The URL
%% given to httpc names the address, and the request carries the original
%% name as its Host header and as the TLS server name, which is also what the
%% peer's certificate is verified against. Redirects are never followed.
dispatch(Method, Host, Path, Query, Headers, Body, TimeoutMs) ->
    case endpoint(Host) of
        {error, nil} -> {error, nil};
        {ok, {Address, Port, CaCerts}} ->
            Name = binary_to_list(Host),
            Url = "https://" ++ url_host(Address) ++ ":" ++ integer_to_list(Port)
                ++ binary_to_list(Path) ++ query(Query),
            Ssl = [{verify, verify_peer}, {cacerts, CaCerts}, {depth, 5},
                   {server_name_indication, Name},
                   {customize_hostname_check,
                    [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
            HttpOptions = [{ssl, Ssl}, {timeout, TimeoutMs}, {connect_timeout, TimeoutMs},
                           {autoredirect, false}],
            Options = [{body_format, binary}, {socket_opts, [{ipfamily, family(Address)}]}],
            Sent = [{"host", Name} | [{binary_to_list(K), binary_to_list(V)}
                                      || {K, V} <- Headers, string:lowercase(K) =/= <<"host">>]],
            Request = case Method of
                M when M =:= get; M =:= head; M =:= options -> {Url, Sent};
                _ ->
                    ContentType = case lists:keyfind("content-type", 1, Sent) of
                        {_, Type} -> Type;
                        false -> "application/octet-stream"
                    end,
                    {Url, Sent, ContentType, Body}
            end,
            case httpc:request(Method, Request, HttpOptions, Options) of
                {ok, {{_, Status, _}, Received, Answer}} ->
                    case unicode:characters_to_binary(Answer) of
                        Text when is_binary(Text) ->
                            {ok, {Status, [{list_to_binary(K), list_to_binary(V)} || {K, V} <- Received], Text}};
                        _ -> {error, nil}
                    end;
                {error, _} -> {error, nil}
            end
    end.

url_host({_, _, _, _} = Address) -> inet:ntoa(Address);
url_host(Address) -> "[" ++ inet:ntoa(Address) ++ "]".

family({_, _, _, _}) -> inet;
family(_) -> inet6.

query(none) -> "";
query({some, Query}) -> "?" ++ binary_to_list(Query).

public({0, _, _, _}) -> false;
public({10, _, _, _}) -> false;
public({100, B, _, _}) when B >= 64, B =< 127 -> false;
public({127, _, _, _}) -> false;
public({169, 254, _, _}) -> false;
public({172, B, _, _}) when B >= 16, B =< 31 -> false;
public({192, 0, 0, _}) -> false;
public({192, 0, 2, _}) -> false;
public({192, 168, _, _}) -> false;
public({198, B, _, _}) when B =:= 18; B =:= 19 -> false;
public({198, 51, 100, _}) -> false;
public({203, 0, 113, _}) -> false;
public({A, _, _, _}) when A >= 224 -> false;
public({_, _, _, _}) -> true;
%% IPv4-mapped and NAT64 addresses are judged as the IPv4 address they carry.
public({0, 0, 0, 0, 0, 16#ffff, C, D}) -> public(embedded(C, D));
public({16#64, 16#ff9b, 0, 0, 0, 0, C, D}) -> public(embedded(C, D));
%% Otherwise only global unicast, 2000::/3, less the documentation prefix.
public({16#2001, 16#db8, _, _, _, _, _, _}) -> false;
public({A, _, _, _, _, _, _, _}) when A >= 16#2000, A =< 16#3fff -> true;
public(_) -> false.

embedded(C, D) -> {C bsr 8, C band 255, D bsr 8, D band 255}.
