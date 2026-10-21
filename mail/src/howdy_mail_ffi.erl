-module(howdy_mail_ffi).
-export([smtp_send/10, rescue/1, send_to/3]).

%% Send one message through gen_smtp and sort the outcome into
%% {ok, Receipt}, {error, {temporary, Reason}} or {error, {permanent, Reason}}.
smtp_send(Host, Port, Tls, Username, Password, Timeout, Helo, From, To, Body) ->
    case application:ensure_all_started(ssl) of
        {ok, _} ->
            deliver(Host, Port, Tls, Username, Password, Timeout, Helo, From, To, Body);
        {error, Reason} ->
            {error, {temporary, describe({ssl_not_started, Reason})}}
    end.

deliver(Host, Port, Tls, Username, Password, Timeout, Helo, From, To, Body) ->
    HostList = unicode:characters_to_list(Host),
    Security =
        case Tls of
            plain -> [{ssl, false}, {tls, never}];
            {start_tls_mode, Verify} ->
                [{ssl, false}, {tls, always}, {tls_options, tls_options(HostList, Verify)}];
            {implicit_mode, Verify} ->
                %% gen_smtp passes `sockopts`, not `tls_options`, to
                %% ssl:connect for implicit TLS.
                [{ssl, true}, {tls, never}, {sockopts, tls_options(HostList, Verify)}]
        end,
    Auth =
        case {Username, Password} of
            {{some, User}, {some, Pass}} ->
                [{auth, always},
                 {username, unicode:characters_to_list(User)},
                 {password, unicode:characters_to_list(Pass)}];
            _ ->
                [{auth, never}]
        end,
    Hostname =
        case Helo of
            {some, Name} -> [{hostname, unicode:characters_to_list(Name)}];
            none -> []
        end,
    Options =
        [{relay, HostList},
         {port, Port},
         {no_mx_lookups, true},
         {retries, 0},
         {timeout, Timeout}]
        ++ Security ++ Auth ++ Hostname,
    try gen_smtp_client:send_blocking({From, To, Body}, Options) of
        Receipt when is_binary(Receipt) ->
            {ok, string:trim(Receipt)};
        {error, _Type, Failure} ->
            {error, classify(Failure)};
        {error, no_relay} ->
            {error, {permanent, <<"no SMTP host configured">>}};
        {error, invalid_port} ->
            {error, {permanent, <<"invalid SMTP port">>}};
        {error, no_credentials} ->
            {error, {permanent, <<"SMTP credentials are incomplete">>}};
        Other ->
            {error, {temporary, describe(Other)}}
    catch
        Class:Reason ->
            {error, {temporary, describe({Class, Reason})}}
    end.

tls_options(Host, true) ->
    [{verify, verify_peer},
     {cacerts, public_key:cacerts_get()},
     {depth, 10},
     {versions, ['tlsv1.2', 'tlsv1.3']},
     {server_name_indication, Host},
     {customize_hostname_check,
      [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}];
tls_options(_Host, false) ->
    [{verify, verify_none}, {versions, ['tlsv1.2', 'tlsv1.3']}].

classify({permanent_failure, _Host, auth_failed}) ->
    {permanent, <<"authentication failed">>};
classify({permanent_failure, _Host, ssl_not_started}) ->
    {permanent, <<"the ssl application is not running">>};
classify({permanent_failure, _Host, Message}) ->
    {permanent, reply(Message)};
classify({temporary_failure, _Host, tls_failed}) ->
    {temporary, <<"TLS handshake failed; check the server's certificate and the TLS mode">>};
classify({temporary_failure, _Host, Message}) ->
    {temporary, reply(Message)};
classify({missing_requirement, _Host, tls}) ->
    {permanent, <<"the server does not offer STARTTLS">>};
classify({missing_requirement, _Host, auth}) ->
    {permanent, <<"the server does not offer a supported AUTH method">>};
classify({network_failure, Host, {error, Reason}}) ->
    {temporary,
     iolist_to_binary(io_lib:format("could not reach ~s: ~p", [Host, Reason]))};
classify({unexpected_response, _Host, Lines}) ->
    {temporary, iolist_to_binary(["unexpected reply: " | Lines])};
classify(Other) ->
    {temporary, describe(Other)}.

reply(Message) when is_binary(Message) -> string:trim(Message);
reply(Message) -> describe(Message).

describe(Term) ->
    iolist_to_binary(io_lib:format("~0p", [Term])).

%% Run a function, turning a crash into {error, Description}.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason ->
            {error, describe({Class, Reason})}
    end.

%% Send to the process a name was looked up as, the way a send to that name
%% does. Unlike sending to the name again, it does nothing if the process
%% has exited since, rather than crashing the sender.
send_to(Pid, Name, Message) ->
    erlang:send(Pid, {Name, Message}),
    nil.
