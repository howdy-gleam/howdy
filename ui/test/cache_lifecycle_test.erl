-module(cache_lifecycle_test).
-export([cold_start_test/0, owner_restart_test/0, startup_failure_test/0]).
-export([cold_start/0, owner_restart/0, startup_failure/0]).
-export([restart_under_load_test/0, restart_under_load/0]).
-export([export_determinism_test/0, export_determinism/0]).

%% Each case needs a genuinely cold application, without disturbing other
%% tests' cached classes. Use an isolated VM with the same compiled code.
cold_start_test() -> isolated(cold_start).
owner_restart_test() -> isolated(owner_restart).
restart_under_load_test() -> isolated(restart_under_load).
startup_failure_test() -> isolated(startup_failure).
export_determinism_test() -> isolated(export_determinism).

export_determinism() ->
    undefined = ets:whereis(howdy_ui_classes),
    Export = 'howdy@ui@export':new('howdy@ui@theme':default_themes()),
    Cold = 'howdy@ui@export':to_css(Export),
    %% Export must not populate or consult the rendering registry.
    undefined = ets:whereis(howdy_ui_classes),
    ['howdy@ui@internal@stylesheet':class_name(Class)
     || Class <- lists:reverse('howdy@ui':classes())],
    Cold = 'howdy@ui@export':to_css(Export),
    ok.

isolated(Scenario) ->
    Expression = "try cache_lifecycle_test:" ++ atom_to_list(Scenario) ++
        "() of ok -> halt(0) "
        "catch C:R:S -> io:format(\"~p:~p~n~p~n\", [C,R,S]), halt(1) end.",
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {args, ["+S", "4", "-noshell", "-pa"] ++ code:get_path() ++
                ["-eval", Expression]}]),
    try collect(Port, [], erlang:monotonic_time(millisecond) + 15000)
    after try port_close(Port) catch error:badarg -> ok end
    end.

collect(Port, Output, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} -> collect(Port, [Data | Output], Deadline);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Code}} ->
            error({child_failed, Code, iolist_to_binary(lists:reverse(Output))})
    after Remaining -> error({child_timeout, iolist_to_binary(lists:reverse(Output))})
    end.

cold_start() ->
    undefined = ets:whereis(howdy_ui_classes),
    Parent = self(),
    Workers = [spawn_monitor(fun() ->
        receive go -> ok end,
        Name = integer_to_binary(N),
        nil = howdy_ui_ffi:register(Name, Name),
        true = howdy_ui_ffi:known(Name),
        Name = howdy_ui_ffi:css_for([Name]),
        Parent ! {done, self()}
    end) || N <- lists:seq(1, 100)],
    [Pid ! go || {Pid, _} <- Workers],
    [receive
        {done, Pid} -> ok;
        {'DOWN', Ref, process, Pid, Reason} -> error({worker_failed, Reason})
     after 5000 -> error(cold_start_timeout)
     end || {Pid, Ref} <- Workers],
    [receive {'DOWN', Ref, process, Pid, normal} -> ok
     after 5000 -> error(worker_exit_timeout)
     end || {Pid, Ref} <- Workers],
    %% All rendering callers have exited; their classes must remain available.
    100 = ets:info(howdy_ui_classes, size),
    Owner = ets:info(howdy_ui_classes, owner),
    {howdy_ui_cache, Owner, worker, _} = lists:keyfind(
        howdy_ui_cache, 1, supervisor:which_children(howdy_ui_supervisor)),
    true = is_process_alive(Owner),
    ok.

owner_restart() ->
    {ok, _} = application:ensure_all_started(howdy_ui),
    nil = howdy_ui_ffi:register(<<"before">>, <<".before{}">>),
    Owner = ets:info(howdy_ui_classes, owner),
    true = is_pid(Owner),
    Ref = monitor(process, Owner),
    exit(Owner, kill),
    receive {'DOWN', Ref, process, Owner, killed} -> ok
    after 5000 -> error(owner_exit_timeout)
    end,
    %% The heir holds the table in the meantime, so nothing is lost.
    true = howdy_ui_ffi:known(<<"before">>),
    wait_for_owner(Owner, 500),
    {howdy_ui_cache, New, worker, _} = lists:keyfind(
        howdy_ui_cache, 1, supervisor:which_children(howdy_ui_supervisor)),
    New = ets:info(howdy_ui_classes, owner),
    nil = howdy_ui_ffi:register(<<"restored">>, <<".restored{}">>),
    <<".before{}\n\n.restored{}">> = howdy_ui_ffi:all_css(),
    ok = application:stop(howdy_ui),
    undefined = ets:whereis(howdy_ui_classes),
    {ok, _} = application:ensure_all_started(howdy_ui),
    false = howdy_ui_ffi:known(<<"restored">>),
    nil = howdy_ui_ffi:register(<<"fresh">>, <<".fresh{}">>),
    <<".fresh{}">> = howdy_ui_ffi:css_for([<<"fresh">>]),
    ok.

%% Renderers keep going while the owner is killed, twice, and lose nothing.
restart_under_load() ->
    {ok, _} = application:ensure_all_started(howdy_ui),
    Parent = self(),
    Classes = 'howdy@ui':classes(),
    Workers = [spawn_monitor(fun() -> render_loop(N, Classes, 0, Parent) end)
               || N <- lists:seq(1, 8)],
    [begin
        timer:sleep(50),
        Owner = ets:info(howdy_ui_classes, owner),
        exit(Owner, kill),
        wait_for_owner(Owner, 500)
     end || _ <- [1, 2]],
    timer:sleep(50),
    [Pid ! stop || {Pid, _} <- Workers],
    Counts = [receive
        {done, Pid, Count} -> Count;
        {'DOWN', Ref, process, Pid, Reason} -> error({worker_failed, Reason})
     after 5000 -> error(worker_timeout)
     end || {Pid, Ref} <- Workers],
    true = lists:all(fun(Count) -> Count > 0 end, Counts),
    %% Every class registered before, during and after the restarts is kept.
    true = lists:all(fun({N, Count}) ->
        lists:all(fun(I) -> howdy_ui_ffi:known(class_of(N, I)) end,
                  lists:seq(1, Count))
    end, lists:zip(lists:seq(1, 8), Counts)),
    Names = ['howdy@ui@internal@stylesheet':class_name(C) || C <- Classes],
    true = lists:all(fun(Name) -> howdy_ui_ffi:known(Name) end, Names),
    ok.

render_loop(N, Classes, Count, Parent) ->
    receive stop -> Parent ! {done, self(), Count}
    after 0 ->
        I = Count + 1,
        Name = class_of(N, I),
        nil = howdy_ui_ffi:register(Name, Name),
        true = howdy_ui_ffi:known(Name),
        Name = howdy_ui_ffi:css_for([Name]),
        [_ | _] = ['howdy@ui@internal@stylesheet':class_name(C) || C <- Classes],
        render_loop(N, Classes, I, Parent)
    end.

class_of(N, I) ->
    <<"w", (integer_to_binary(N))/binary, "-", (integer_to_binary(I))/binary>>.

%% Until a new howdy_ui_cache holds the table; in between, the heir does.
wait_for_owner(_, 0) -> error(owner_restart_timeout);
wait_for_owner(Old, Attempts) ->
    case {whereis(howdy_ui_cache), ets:info(howdy_ui_classes, owner)} of
        {New, New} when is_pid(New), New =/= Old -> ok;
        _ -> timer:sleep(10), wait_for_owner(Old, Attempts - 1)
    end.

startup_failure() ->
    %% A conflicting table must produce an error, never an unbounded wait.
    howdy_ui_classes = ets:new(howdy_ui_classes, [named_table]),
    {error, _} = application:ensure_all_started(howdy_ui),
    ok.
