%% A connection listening for PostgreSQL `NOTIFY` on one channel, for
%% howdy/database/postgres.listen.
%%
%% The listener is linked to the process that started it and stops when that
%% process exits. It holds a notification connection of its own, not one of
%% the pool's: `howdy_database_notifications`, pgo's `pgo_notifications`
%% with fixes. pgo reconnects that connection when it drops and
%% listens again; if the pgo process itself exits, the listener starts a new
%% one. Notifications sent while it was not connected are missed, which is
%% why callers keep a slower poll as well.
-module(howdy_database_listen).
-export([remember/2, settings_for/1, settings/8, start/3, stop/1]).

-define(SETTINGS(Name), {?MODULE, Name}).

%% -- Settings ------------------------------------------------------------------

%% Remember the settings of a pool this package opened, so a listener can
%% connect the same way without looking inside pgo.
remember(PoolName, Settings) ->
    persistent_term:put(?SETTINGS(PoolName), Settings),
    nil.

%% The pgo settings for a Gloo Repo on PostgreSQL: those remembered for its
%% pool, or, for a pool opened elsewhere, those found inside pgo.
settings_for(Repo) ->
    case postgres_pool(Repo) of
        {ok, Name} ->
            case persistent_term:get(?SETTINGS(Name), undefined) of
                undefined -> pool_config(Name);
                Settings -> {ok, Settings}
            end;
        {error, nil} ->
            {error, nil}
    end.

%% The pool behind a Gloo Repo on PostgreSQL. Reads Gloo's public adapter
%% record.
postgres_pool({repo, Adapter}) when element(1, Adapter) =:= adapter ->
    case element(3, Adapter) of
        {pg_connection, {pool, Name}, _} when is_atom(Name) -> {ok, Name};
        _ -> {error, nil}
    end;
postgres_pool(_) ->
    {error, nil}.

%% FALLBACK, for a pool this package did not open. pgo has no public way to
%% read a running pool's settings, so this walks its supervision tree: the
%% pool process is linked to its `pgo_pool_sup`, whose `connection_sup`
%% child spec carries the settings as its last argument. Every step is
%% guarded, so a pgo whose shape has changed gives `{error, nil}`.
pool_config(Name) ->
    try
        case whereis(Name) of
            undefined ->
                {error, nil};
            Pool ->
                case process_info(Pool, links) of
                    {links, Links} ->
                        find_config([Pid || Pid <- Links, is_pid(Pid), is_pool_sup(Pid)]);
                    _ ->
                        {error, nil}
                end
        end
    catch
        _:_ -> {error, nil}
    end.

is_pool_sup(Pid) ->
    try proc_lib:initial_call(Pid) of
        {pgo_pool_sup, _, _} -> true;
        {supervisor, pgo_pool_sup, _} -> true;
        _ -> false
    catch
        _:_ -> false
    end.

find_config([]) ->
    {error, nil};
find_config([Sup | Rest]) ->
    try supervisor:get_childspec(Sup, connection_sup) of
        {ok, #{start := {pgo_connection_sup, start_link, [_, _, _, Config]}}} when is_map(Config) ->
            {ok, Config};
        _ ->
            find_config(Rest)
    catch
        _:_ -> find_config(Rest)
    end.

%% The public fields of a `pog.Config`, as pgo's settings, the way pog
%% itself builds them.
settings(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion) ->
    {SslActivated, SslOptions} = ssl_options(Host, Ssl),
    Settings = #{
        host => Host,
        port => Port,
        database => Database,
        user => User,
        ssl => SslActivated,
        ssl_options => SslOptions,
        connection_parameters => Parameters,
        socket_options => case IpVersion of ipv6 -> [inet6]; _ -> [] end
    },
    case Password of
        {some, Pw} -> Settings#{password => Pw};
        none -> Settings
    end.

ssl_options(_Host, ssl_disabled) ->
    {false, []};
ssl_options(_Host, ssl_unverified) ->
    {true, [{verify, verify_none}]};
ssl_options(Host, ssl_verified) ->
    {true, [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, unicode:characters_to_list(Host)},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ]}.

%% -- Listening -------------------------------------------------------------------

%% Start a listener linked to the caller. It returns once the first attempt
%% to listen has been answered, or after five seconds, so a notification
%% sent after this returns is heard whenever the server is up.
start(Settings0, Channel, Notify) ->
    % pgo's pool takes a binary host, but its notification connection hands
    % the host straight to gen_tcp, which wants a string.
    Settings = case Settings0 of
        #{host := Host} when is_binary(Host) -> Settings0#{host := unicode:characters_to_list(Host)};
        _ -> Settings0
    end,
    Parent = self(),
    Ready = make_ref(),
    Pid = proc_lib:spawn_link(fun() -> init(Parent, Ready, Settings, Channel, Notify) end),
    receive
        {Ready, Pid} -> ok
    after 5000 ->
        ok
    end,
    Pid.

stop(Pid) ->
    Pid ! {?MODULE, stop},
    nil.

init(Parent, Ready, Settings, Channel, Notify) ->
    process_flag(trap_exit, true),
    Conn = connect(Settings, Channel, 0),
    Parent ! {Ready, self()},
    loop(Parent, Settings, Channel, Notify, Conn, 0).

%% Start pgo's notification connection and listen on it. pgo connects in
%% the background, so this answers `ok` once listening, or `eventually`
%% when the server cannot be reached yet: pgo listens when it gets there.
connect(Settings, Channel, Failures) ->
    Started = try howdy_database_notifications:start_link(Settings) catch _:_ -> error end,
    case Started of
        {ok, Conn} ->
            Listening = try howdy_database_notifications:listen(Conn, Channel) catch _:_ -> error end,
            case Listening of
                {Tag, _} when Tag =:= ok; Tag =:= eventually ->
                    Conn;
                _ ->
                    warn(Channel, Failures),
                    stop_conn(Conn),
                    retry(Failures),
                    undefined
            end;
        _ ->
            warn(Channel, Failures),
            retry(Failures),
            undefined
    end.

%% Log only the first failure in a run of them.
warn(Channel, 0) ->
    logger:warning("howdy/database: could not listen on the PostgreSQL channel ~ts; trying again", [Channel]);
warn(_, _) ->
    ok.

%% Try again after a growing pause, up to a minute.
retry(Failures) ->
    erlang:send_after(min(60000, 1000 bsl min(Failures, 6)), self(), {?MODULE, retry}).

loop(Parent, Settings, Channel, Notify, Conn, Failures) ->
    receive
        {notification, Conn, _, _, Payload} ->
            try
                Notify(Payload)
            catch
                Class:Reason:Stacktrace ->
                    logger:error("howdy/database: a listener on ~ts crashed: ~p",
                                 [Channel, {Class, Reason, Stacktrace}])
            end,
            loop(Parent, Settings, Channel, Notify, Conn, 0);
        {'EXIT', Parent, Reason} ->
            stop_conn(Conn),
            exit(Reason);
        {'EXIT', Conn, _} when Conn =/= undefined ->
            retry(0),
            loop(Parent, Settings, Channel, Notify, undefined, Failures);
        {?MODULE, retry} when Conn =:= undefined ->
            New = connect(Settings, Channel, Failures + 1),
            Next = case New of undefined -> Failures + 1; _ -> 0 end,
            loop(Parent, Settings, Channel, Notify, New, Next);
        {?MODULE, stop} ->
            stop_conn(Conn),
            unlink(Parent),
            exit(normal);
        _ ->
            loop(Parent, Settings, Channel, Notify, Conn, Failures)
    end.

stop_conn(undefined) ->
    ok;
stop_conn(Conn) ->
    unlink(Conn),
    try gen_statem:stop(Conn) catch _:_ -> ok end.
