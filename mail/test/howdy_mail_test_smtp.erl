%% A gen_smtp server session for tests: accepts everything except a few
%% magic recipients, checks one set of credentials when AUTH is offered, and
%% sends each message to the collector process. flaky@example.com is refused
%% with a temporary error on the first attempt through the server only.
-module(howdy_mail_test_smtp).
-export([
    init/4, handle_HELO/2, handle_EHLO/3, handle_MAIL/2, handle_MAIL_extension/2,
    handle_RCPT/2, handle_RCPT_extension/2, handle_DATA/4, handle_RSET/1,
    handle_VRFY/2, handle_other/3, handle_AUTH/4, handle_STARTTLS/1,
    handle_info/2, handle_error/3, code_change/3, terminate/2
]).

init(Hostname, _SessionCount, _Address, Options) ->
    {ok, [Hostname, " ESMTP howdy test"], Options}.

handle_HELO(_Hostname, State) -> {ok, 655360, State}.

handle_EHLO(_Hostname, Extensions, State) ->
    case proplists:get_value(auth, State, false) of
        true -> {ok, Extensions ++ [{"AUTH", "PLAIN LOGIN"}], State};
        false -> {ok, Extensions, State}
    end.

handle_MAIL(_From, State) ->
    atomics:add(proplists:get_value(attempts, State), 1, 1),
    {ok, State}.
handle_MAIL_extension(_Extension, State) -> {ok, State}.

handle_RCPT(<<"refused@example.com">>, State) -> {error, "550 No such recipient", State};
handle_RCPT(<<"later@example.com">>, State) -> {error, "451 Try again later", State};
handle_RCPT(<<"flaky@example.com">>, State) ->
    case atomics:get(proplists:get_value(attempts, State), 1) of
        1 -> {error, "451 Try again later", State};
        _ -> {ok, State}
    end;
handle_RCPT(_To, State) -> {ok, State}.
handle_RCPT_extension(_Extension, State) -> {ok, State}.

handle_DATA(From, To, Data, State) ->
    proplists:get_value(collector, State) ! {howdy_mail_test_smtp, From, To, Data},
    {ok, "queued as TEST123", State}.

handle_RSET(State) -> State.
handle_VRFY(_Address, State) -> {error, "252 no", State}.
handle_other(Verb, _Args, State) -> {["500 unknown ", Verb], State}.

handle_AUTH(Type, <<"user@example.com">>, <<"s3cret">>, State) when Type =:= login; Type =:= plain ->
    {ok, State};
handle_AUTH(_Type, _Username, _Password, _State) ->
    error.

handle_STARTTLS(State) -> State.
handle_info(_Info, State) -> {noreply, State}.
handle_error(_Class, _Details, State) -> {ok, State}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(Reason, State) -> {ok, Reason, State}.
