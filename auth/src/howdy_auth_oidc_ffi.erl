-module(howdy_auth_oidc_ffi).
-export([verify_entra/2, verify/2, protect/2, keys_new/0, keys_get/5]).
-include_lib("public_key/include/public_key.hrl").

%% Fixed Google RS256 compact-JWS verifier using OTP's public_key primitive.
%% Keys come only from Google's pinned JWKS endpoint. No algorithm negotiation,
%% header-supplied keys/URLs, detached payloads, or critical extensions.
verify(Signed, Keys) when byte_size(Signed) =< 32768, byte_size(Keys) =< 1048576 ->
    try
        [Protected, Payload, Signature] = binary:split(Signed, <<".">>, [global]),
        Header = json:decode(unbase64(Protected)),
        #{<<"alg">> := <<"RS256">>, <<"kid">> := Kid} = Header,
        true = is_binary(Kid) andalso byte_size(Kid) > 0,
        false = maps:is_key(<<"crit">>, Header),
        false = maps:is_key(<<"b64">>, Header),
        #{<<"keys">> := Candidates} = json:decode(Keys),
        [Key] = [K || K = #{<<"kid">> := Id, <<"kty">> := <<"RSA">>} <- Candidates,
                      Id =:= Kid, maps:get(<<"use">>, K, <<"sig">>) =:= <<"sig">>,
                      maps:get(<<"alg">>, K, <<"RS256">>) =:= <<"RS256">>],
        N = unbase64(maps:get(<<"n">>, Key)),
        E = unbase64(maps:get(<<"e">>, Key)),
        true = byte_size(N) >= 256 andalso byte_size(N) =< 1024,
        true = byte_size(E) > 0 andalso byte_size(E) =< 8,
        Public = #'RSAPublicKey'{modulus = binary:decode_unsigned(N),
                                 publicExponent = binary:decode_unsigned(E)},
        true = public_key:verify(<<Protected/binary, ".", Payload/binary>>,
                                 sha256, unbase64(Signature), Public),
        {ok, unbase64(Payload)}
    catch _:_ -> {error, nil} end;
verify(_, _) -> {error, nil}.

unbase64(Value) -> base64:decode(Value, #{mode => url, padding => false}).

protect(Run, Message) ->
    try Run()
    catch _:_ -> {error, {internal, Message}} end.

%% Provider signing keys and discovery documents: one named public table
%% owned by howdy_auth_tables, partitioned by the reference each `keys_new`
%% returns and then by the URL a body came from. Rows are
%% {{Ref, Key}, Body, Until}, with Until in `howdy_auth_ffi:now/0` seconds.
%%
%% Fetching is single-flight without any lock process: the caller that
%% installs the {{fetching, Ref, Key}, Pid} marker (ets:insert_new decides
%% the race) performs the fetch in its own process, and everyone else who
%% needs that key meanwhile either serves the previous body if one is not
%% too stale (stale-while-revalidate) or registers as a waiter and receives
%% the leader's result as a message. A waiter monitors the leader, so a
%% leader that dies mid-fetch is replaced rather than waited for; a marker
%% left by a dead leader is cleared by whoever finds it. Fetches run in the
%% caller because a transport may only be usable from there (tests play the
%% provider from the test process).
-define(KEYS, howdy_auth_provider_keys).
%% How long past its lifetime a body is still served while a fresh one is
%% being fetched. Bounded so a provider that stays down does not keep
%% signing keys alive indefinitely.
-define(STALE_GRACE, 3600).
%% Longer than any transport timeout, so a waiter never outlives its leader's
%% fetch by much.
-define(WAIT_MS, 15000).

keys_new() ->
    _ = howdy_auth_tables:ensure(?KEYS),
    make_ref().

%% Fetch :: fun(() -> {ok, {Body, Until}} | {error, Reason}); Failed is the
%% error a waiter reports when the leader's outcome cannot be learned.
keys_get(Ref, Key, Refresh, Fetch, Failed) ->
    _ = case ets:whereis(?KEYS) of
        undefined -> howdy_auth_tables:ensure(?KEYS);
        _ -> ok
    end,
    Now = howdy_auth_ffi:now(),
    Cached = keys_lookup(Ref, Key),
    case Cached of
        {ok, Body, Until} when not Refresh, Until > Now -> {ok, Body};
        _ ->
            case keys_claim(Ref, Key) of
                leader -> keys_lead(Ref, Key, Fetch);
                reentrant -> keys_store(Ref, Key, Fetch());
                {follow, Leader} ->
                    case Cached of
                        {ok, Body, Until} when not Refresh, Until + ?STALE_GRACE > Now -> {ok, Body};
                        _ -> keys_follow(Ref, Key, Leader, Refresh, Fetch, Failed)
                    end
            end
    end.

keys_lookup(Ref, Key) ->
    try ets:lookup(?KEYS, {Ref, Key}) of
        [{_, Body, Until}] -> {ok, Body, Until};
        [] -> none
    catch error:badarg -> none end.

keys_store(Ref, Key, {ok, {Body, Until}}) ->
    try ets:insert(?KEYS, {{Ref, Key}, Body, Until}) catch error:badarg -> ok end,
    {ok, Body};
keys_store(_Ref, _Key, {error, _} = Error) ->
    Error.

keys_claim(Ref, Key) ->
    Marker = {fetching, Ref, Key},
    try ets:insert_new(?KEYS, {Marker, self()}) of
        true -> leader;
        false ->
            case ets:lookup(?KEYS, Marker) of
                [{_, Pid}] when Pid =:= self() -> reentrant;
                [{_, Pid}] ->
                    case is_process_alive(Pid) of
                        true -> {follow, Pid};
                        false ->
                            ets:delete_object(?KEYS, {Marker, Pid}),
                            keys_claim(Ref, Key)
                    end;
                [] -> keys_claim(Ref, Key)
            end
    catch error:badarg -> leader end.

keys_lead(Ref, Key, Fetch) ->
    try Fetch() of
        Result -> keys_finish(Ref, Key, keys_store(Ref, Key, Result))
    catch Class:Reason:Stack ->
        keys_finish(Ref, Key, {error, nil}),
        erlang:raise(Class, Reason, Stack)
    end.

%% Withdraw the marker, then hand the result to every waiter still
%% registered. ets:take makes each waiter's row a token exactly one side
%% wins: a waiter that takes its own row first knows no message will come.
keys_finish(Ref, Key, Result) ->
    try
        ets:delete(?KEYS, {fetching, Ref, Key}),
        Waiters = ets:select(?KEYS, [{{{waiter, Ref, Key, '$1'}}, [], ['$1']}]),
        lists:foreach(fun(Pid) ->
            case ets:take(?KEYS, {waiter, Ref, Key, Pid}) of
                [] -> ok;
                [_] -> Pid ! {?MODULE, Ref, Key, Result}
            end
        end, Waiters)
    catch error:badarg -> ok end,
    Result.

keys_follow(Ref, Key, Leader, Refresh, Fetch, Failed) ->
    Marker = {fetching, Ref, Key},
    Row = {waiter, Ref, Key, self()},
    Monitor = monitor(process, Leader),
    Registered = try
        ets:insert(?KEYS, {Row}),
        ets:lookup(?KEYS, Marker) =:= [{Marker, Leader}]
    catch error:badarg -> false end,
    Retry = fun() ->
        demonitor(Monitor, [flush]),
        keys_get(Ref, Key, Refresh, Fetch, Failed)
    end,
    Receive = fun() ->
        receive
            {?MODULE, Ref, Key, Result} ->
                demonitor(Monitor, [flush]),
                Result
        after ?WAIT_MS ->
            demonitor(Monitor, [flush]),
            Failed
        end
    end,
    case Registered of
        true ->
            receive
                {?MODULE, Ref, Key, Result} ->
                    demonitor(Monitor, [flush]),
                    Result;
                {'DOWN', Monitor, process, Leader, _} ->
                    %% The leader's own message, had it finished, would have
                    %% arrived first. Clear what it left and take over.
                    _ = try ets:delete_object(?KEYS, {Marker, Leader}), ets:take(?KEYS, Row)
                        catch error:badarg -> ok end,
                    keys_get(Ref, Key, Refresh, Fetch, Failed)
            after ?WAIT_MS ->
                case keys_withdraw(Row) of
                    false -> Receive();
                    true -> demonitor(Monitor, [flush]), Failed
                end
            end;
        false ->
            %% The leader finished (or the table went) between our lookup and
            %% registration. If it already took our row a message follows.
            case keys_withdraw(Row) of
                false -> Receive();
                true -> Retry()
            end
    end.

%% True when this waiter took its own row back, so no message is coming; a
%% table that has gone counts as that too.
keys_withdraw(Row) ->
    try ets:take(?KEYS, Row) =/= [] catch error:badarg -> true end.

%% Microsoft keys are scoped to either one issuer or the tenant template.
%% Filter before the shared signature verifier so an unrelated tenant key
%% cannot establish an identity even if its signature is otherwise valid.
verify_entra(Signed, Keys) when byte_size(Signed) =< 32768, byte_size(Keys) =< 1048576 ->
    try
        [_, Encoded, _] = binary:split(Signed, <<".">>, [global]),
        #{<<"iss">> := Issuer, <<"tid">> := Tenant} = json:decode(unbase64(Encoded)),
        true = is_binary(Issuer) andalso is_binary(Tenant),
        #{<<"keys">> := Candidates} = json:decode(Keys),
        Scoped = [K || K = #{<<"issuer">> := Scope} <- Candidates,
                       is_binary(Scope),
                       binary:replace(Scope, <<"{tenantid}">>, Tenant, [global]) =:= Issuer],
        verify(Signed, iolist_to_binary(json:encode(#{<<"keys">> => Scoped})))
    catch _:_ -> {error, nil} end;
verify_entra(_, _) -> {error, nil}.
