-module(howdy_jobs_ffi).
-export([now_ms/0, node_name/0, rescue/1, unique/0, raw_json/1]).
-export([join/2, wake/1, wake_after_commit/1, flush_wakes/0, ensure_wake_hook/0, wake_hook/1]).
-export([exit_reason/1, normal/0, stop_supervisor/2]).
-export([start_listener/3]).
-export([arguments/0, halt/1, getenv/1]).

now_ms() ->
    erlang:system_time(millisecond).

node_name() ->
    atom_to_binary(node()).

%% gleam_json's Json is iodata on Erlang, so JSON text that is known to be
%% valid can stand for itself.
raw_json(Text) ->
    Text.

unique() ->
    erlang:unique_integer([positive]).

%% Run F, turning a crash into an error with a description, so one job
%% that crashes is retried rather than taking anything else down.
rescue(F) ->
    try F() of
        Value -> {ok, Value}
    catch
        Class:Reason:Stacktrace ->
            {error, unicode:characters_to_binary(
                io_lib:format("~p: ~P~n~P", [Class, Reason, 30, Stacktrace, 30]))}
    end.

%% -- Waking producers ------------------------------------------------------
%%
%% Each producer joins the `pg` group of its queue in howdy's channel scope,
%% so a job inserted on any connected node wakes the producers of its queue
%% everywhere. A producer receives `{howdy_jobs_wake, Queue}`.

group(Queue) -> {howdy_jobs, Queue}.

join(Queue, Pid) ->
    howdy_channel_ffi:channel_join(group(Queue), Pid).

wake(Queue) ->
    howdy_channel_ffi:channel_broadcast(group(Queue), howdy_jobs_wake, Queue).

%% Inside a transaction a producer woken now would look before the job is
%% committed and find nothing, so the queues are noted and woken when the
%% outermost transaction ends (see `flush_wakes`).
-define(PENDING, howdy_jobs_pending_wakes).

wake_after_commit(Queue) ->
    Pending = case get(?PENDING) of
        undefined -> [];
        Queues -> Queues
    end,
    case lists:member(Queue, Pending) of
        true -> ok;
        false -> put(?PENDING, [Queue | Pending])
    end,
    nil.

flush_wakes() ->
    case erase(?PENDING) of
        undefined -> ok;
        Queues -> lists:foreach(fun wake/1, Queues)
    end,
    nil.

%% The hook howdy/database runs around each outermost transaction. It wakes
%% whatever the transaction queued once it has ended; after a rollback the
%% wake finds nothing, which is harmless. Registered once per node.
ensure_wake_hook() ->
    case persistent_term:get(howdy_jobs_wake_hook, false) of
        true ->
            nil;
        false ->
            howdy_database_ffi:around_transactions(<<"howdy_jobs">>, fun ?MODULE:wake_hook/1),
            persistent_term:put(howdy_jobs_wake_hook, true),
            nil
    end.

wake_hook(Run) ->
    try Run() after flush_wakes() end.

%% -- Stopping -----------------------------------------------------------------

exit_reason(normal) -> normal;
exit_reason(killed) -> killed;
exit_reason({abnormal, Reason}) -> Reason.

normal() -> normal.

%% Stop a supervisor the caller started and linked to, waiting for its
%% children to stop in turn.
stop_supervisor(Pid, Timeout) ->
    unlink(Pid),
    Ref = monitor(process, Pid),
    exit(Pid, shutdown),
    receive
        {'DOWN', Ref, process, Pid, _} -> nil
    after Timeout ->
        exit(Pid, kill),
        receive {'DOWN', Ref, process, Pid, _} -> nil end
    end.

%% -- Listening on PostgreSQL ----------------------------------------------------
%%
%% A job inserted by a node this one is not connected to reaches it through
%% `NOTIFY howdy_jobs, '<queue>'`, which PostgreSQL delivers when the
%% inserting transaction commits. The listener holds one connection of its
%% own, opened with the settings the app gave (`howdy/jobs.listen_via`) or,
%% failing that, those found inside the Repo's pgo pool. Without either it
%% logs once and does nothing: producers still poll.

start_listener(Repo, Settings, Notify) ->
    Pid = proc_lib:spawn_link(fun() -> listener_init(Repo, Settings, Notify) end),
    {ok, Pid}.

listener_init(Repo, Settings, Notify) ->
    process_flag(trap_exit, true),
    case listener_config(Repo, Settings) of
        {ok, Config} ->
            listener_connect(Config, Notify, 0);
        {error, nil} ->
            logger:warning(
                "howdy/jobs: could not find the PostgreSQL settings to listen for new jobs; "
                "pass them with howdy/jobs.listen_via. Producers poll instead."),
            idle()
    end.

idle() ->
    receive
        {'EXIT', _, Reason} -> exit(Reason);
        _ -> idle()
    end.

listener_connect(Config, Notify, Failures) ->
    Started = try pgo_notifications:start_link(Config) catch _:_ -> error end,
    case Started of
        {ok, Listener} ->
            Listening = try pgo_notifications:listen(Listener, <<"howdy_jobs">>) catch _:_ -> error end,
            case Listening of
                {Tag, _} when Tag =:= ok; Tag =:= eventually ->
                    listener_loop(Config, Listener, Notify);
                _ ->
                    stop_listener(Listener),
                    listener_retry(Config, Notify, Failures + 1)
            end;
        _ ->
            listener_retry(Config, Notify, Failures + 1)
    end.

%% Try again after a growing pause, up to a minute, logging only the first
%% failure in a run of them.
listener_retry(Config, Notify, Failures) ->
    case Failures of
        1 -> logger:warning("howdy/jobs: could not listen for new jobs on PostgreSQL; trying again. Producers poll meanwhile.");
        _ -> ok
    end,
    Pause = min(60000, 1000 * (1 bsl min(Failures, 6))),
    receive
        {'EXIT', _, Reason} when Reason =/= normal -> exit(Reason)
    after Pause ->
        listener_connect(Config, Notify, Failures)
    end.

listener_loop(Config, Listener, Notify) ->
    receive
        {notification, _, _, _, Payload} ->
            Notify(Payload),
            listener_loop(Config, Listener, Notify);
        {'EXIT', Listener, _} ->
            listener_retry(Config, Notify, 1);
        {'EXIT', _Parent, Reason} ->
            stop_listener(Listener),
            exit(Reason);
        _ ->
            listener_loop(Config, Listener, Notify)
    end.

stop_listener(Listener) ->
    try gen_statem:stop(Listener) catch _:_ -> ok end.

listener_config(_Repo, {some, {Host, Port, Database, User, Password, Ssl, Parameters, IpVersion}}) ->
    {ok, settings(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion)};
listener_config(Repo, none) ->
    case postgres_pool(Repo) of
        {ok, Pool} -> pool_config(Pool);
        {error, nil} -> {error, nil}
    end.

%% The pgo pool behind a Gloo Repo on PostgreSQL. Reads Gloo's public
%% adapter record.
postgres_pool({repo, Adapter}) when element(1, Adapter) =:= adapter ->
    case element(3, Adapter) of
        {pg_connection, {pool, Name}, _} when is_atom(Name) -> {ok, Name};
        _ -> {error, nil}
    end;
postgres_pool(_) ->
    {error, nil}.

%% pgo has no public way to read a running pool's settings, so this walks
%% its supervision tree, as howdy/admin does: the pool process is linked to
%% its `pgo_pool_sup`, whose `connection_sup` child spec carries the settings
%% as its last argument. Every step is guarded, so a pgo whose shape has
%% changed gives `{error, nil}` and producers poll instead.
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

%% The public fields of a `pog.Config`, turned into pgo's map the way pog
%% itself does.
settings(Host, Port, Database, User, Password, Ssl, Parameters, IpVersion) ->
    HostList = unicode:characters_to_list(Host),
    {SslActivated, SslOptions} = ssl_options(HostList, Ssl),
    Config = #{
        host => HostList,
        port => Port,
        database => unicode:characters_to_list(Database),
        user => unicode:characters_to_list(User),
        ssl => SslActivated,
        ssl_options => SslOptions,
        connection_parameters => Parameters,
        socket_options => case IpVersion of ipv6 -> [inet6]; _ -> [] end
    },
    case Password of
        {some, Pw} -> Config#{password => unicode:characters_to_list(Pw)};
        none -> Config
    end.

ssl_options(_Host, ssl_disabled) ->
    {false, []};
ssl_options(_Host, ssl_unverified) ->
    {true, [{verify, verify_none}]};
ssl_options(Host, ssl_verified) ->
    {true, [
        {verify, verify_peer},
        {cacerts, public_key:cacerts_get()},
        {server_name_indication, Host},
        {customize_hostname_check, [
            {match_fun, public_key:pkix_verify_hostname_match_fun(https)}
        ]}
    ]}.

%% -- Command line -----------------------------------------------------------------

arguments() ->
    [unicode:characters_to_binary(A) || A <- init:get_plain_arguments()].

halt(Code) -> erlang:halt(Code).

getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
