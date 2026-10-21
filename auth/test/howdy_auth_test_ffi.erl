-module(howdy_auth_test_ffi).
-export([totp_code/2, count_verifications/1, backend/0, delete_file/1, delete_session_tables/0, kill_session_owners/0,
         advance_clock/2, with_pinned_idp/3]).
-include_lib("public_key/include/public_key.hrl").

%% Run with every auth clock in this process `Ms` further ahead, then put it
%% back. Sessions, caches and rate limits then expire without sleeping.
advance_clock(Ms, Run) ->
    Before = case get(howdy_auth_clock_offset_ms) of undefined -> 0; N -> N end,
    put(howdy_auth_clock_offset_ms, Before + Ms),
    try Run()
    after put(howdy_auth_clock_offset_ms, Before)
    end.

%% Play an identity provider named `Host` over TLS on loopback for the
%% duration of `Run`, answering one request with `Body`. Returns Run's
%% result with what the provider saw: the TLS server name and the request
%% head. The name is pinned to loopback for `howdy_auth_sso_ffi` through the
%% same hook production resolves through, with the authority that signed the
%% provider's certificate as its only trusted root.
with_pinned_idp(Host, Body, Run) ->
    {ok, _} = application:ensure_all_started(ssl),
    Name = binary_to_list(Host),
    Key = {key, {rsa, 2048, 65537}},
    SubjectAltName = #'Extension'{extnID = ?'id-ce-subjectAltName', critical = false,
                                  extnValue = [{dNSName, Name}]},
    #{server_config := Server, client_config := Client} = public_key:pkix_test_data(#{
        server_chain => #{root => [Key], intermediates => [],
                          peer => [Key, {extensions, [SubjectAltName]}]},
        client_chain => #{root => [Key], intermediates => [], peer => [Key]}}),
    {ok, Listen} = ssl:listen(0, [{ip, {127, 0, 0, 1}}, binary, {active, false}, {reuseaddr, true},
                                  {cert, proplists:get_value(cert, Server)},
                                  {key, proplists:get_value(key, Server)}]),
    {ok, {_, Port}} = ssl:sockname(Listen),
    Parent = self(),
    Provider = spawn_link(fun() ->
        {ok, Accepted} = ssl:transport_accept(Listen, 5000),
        {ok, Socket} = ssl:handshake(Accepted, 5000),
        {ok, [{sni_hostname, Sni}]} = ssl:connection_information(Socket, [sni_hostname]),
        Head = request_head(Socket, <<>>),
        ok = ssl:send(Socket, ["HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: ",
                               integer_to_list(byte_size(Body)), "\r\nconnection: close\r\n\r\n", Body]),
        ssl:close(Socket),
        Seen = case Sni of undefined -> <<>>; _ -> list_to_binary(Sni) end,
        Parent ! {idp, self(), Seen, Head}
    end),
    Pinned = {{127, 0, 0, 1}, Port, proplists:get_value(cacerts, Client)},
    persistent_term:put({howdy_auth_sso_ffi, pinned}, #{Host => Pinned}),
    try
        Result = Run(),
        receive {idp, Provider, Sni, Head} -> {Result, {Sni, Head}}
        after 5000 -> error(provider_never_reached)
        end
    after
        persistent_term:erase({howdy_auth_sso_ffi, pinned}),
        ssl:close(Listen)
    end.

request_head(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {_, _} -> Acc;
        nomatch ->
            {ok, More} = ssl:recv(Socket, 0, 5000),
            request_head(Socket, <<Acc/binary, More/binary>>)
    end.

backend() ->
    case os:getenv("HOWDY_AUTH_TEST_BACKEND") of
        false -> <<"sqlite">>;
        Value -> list_to_binary(Value)
    end.

delete_file(Path) -> ok = file:delete(Path), nil.

%% The in-memory session store's tables are public, so anyone may delete
%% them: the failure a store must survive. Tests run one at a time, so every
%% such table in the VM belongs to this test or to a store no longer in use.
session_tables() ->
    [T || T <- ets:all(), ets:info(T, name) =:= howdy_auth_sessions].

delete_session_tables() ->
    lists:foreach(fun ets:delete/1, session_tables()),
    nil.

kill_session_owners() ->
    lists:foreach(fun(T) -> exit(ets:info(T, owner), kill) end, session_tables()),
    nil.


%% Count calls, not elapsed time. Test-only tracing never prints arguments.
count_verifications(Run) ->
    Parent = self(),
    Tracer = spawn(fun() -> verification_traces(Parent, 0, undefined) end),
    erlang:trace_pattern({'howdy@auth@password_hasher', verify, 2}, true, [local]),
    erlang:trace(self(), true, [call, {tracer, Tracer}]),
    try
        Result = Run(),
        erlang:trace(self(), false, [call]),
        Tracer ! finish,
        receive {verification_count, Tracer, Count} -> {Result, Count}
        after 5000 -> error(trace_timeout) end
    after
        erlang:trace(self(), false, [call]),
        erlang:trace_pattern({'howdy@auth@password_hasher', verify, 2}, false, [local]),
        exit(Tracer, kill)
    end.

verification_traces(Parent, Count, Ref) ->
    receive
        {trace, Parent, call, {'howdy@auth@password_hasher', verify, _}} -> verification_traces(Parent, Count + 1, Ref);
        finish -> verification_traces(Parent, Count, erlang:trace_delivered(Parent));
        {trace_delivered, Parent, Ref} -> Parent ! {verification_count, self(), Count}
    end.

%% Independent test authenticator, using RFC 4226 dynamic truncation.
totp_code(Seed, Seconds) ->
    Alphabet = <<"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567">>,
    Values = [begin {I,1} = binary:match(Alphabet, <<C>>), I end || <<C>> <= Seed],
    Key = << <<V:5>> || V <- Values >>,
    H = crypto:mac(hmac, sha, Key, <<(Seconds div 30):64>>),
    O = binary:last(H) band 15,
    <<_:O/binary, N:32, _/binary>> = H,
    list_to_binary(io_lib:format("~6..0B", [(N band 16#7fffffff) rem 1000000])).
