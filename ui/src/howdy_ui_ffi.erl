-module(howdy_ui_ffi).
-export([known/1, register/2, name_of/1, remember_name/2, all_css/0, css_for/1,
         scope_begin/0, scope_end/0, note/1,
         behaviour_source/0, behaviour_path/0, rich_text_source/0]).

-define(TABLE, howdy_ui_classes).
-define(NAMES, howdy_ui_names).
-define(SCOPE, howdy_ui_scope).

%% Classes live in public ETS tables so every process can look them up
%% without going through a shared process. Reads are concurrent; the only
%% writes happen the first time a class is seen.

known(Name) ->
    with_table(fun() -> ets:member(?TABLE, Name) end).

register(Name, Css) ->
    Seq = erlang:unique_integer([monotonic]),
    with_table(fun() -> ets:insert_new(?TABLE, {Name, Seq, Css}) end),
    nil.

%% The memoised name of a class definition, if it has been seen before.
name_of(Class) ->
    with_table(fun() ->
        case ets:lookup(?NAMES, Class) of
            [{_, Name}] -> {ok, Name};
            [] -> {error, nil}
        end
    end).

remember_name(Class, Name) ->
    with_table(fun() -> ets:insert_new(?NAMES, {Class, Name}) end),
    nil.

all_css() ->
    with_table(fun() -> join(lists:keysort(2, ets:tab2list(?TABLE))) end).

%% The CSS for just these classes, in the order they were first seen.
css_for(Names) ->
    with_table(fun() ->
        Rows = lists:flatmap(fun(Name) -> ets:lookup(?TABLE, Name) end,
                             lists:usort(Names)),
        join(lists:keysort(2, Rows))
    end).

join(Rows) ->
    iolist_to_binary(lists:join(<<"\n\n">>, [Css || {_, _, Css} <- Rows])).

%% -- Render scopes -----------------------------------------------------------
%%
%% A scope records which classes a view used, so a live component can ship
%% exactly the CSS it needs. Scopes are per process and nest.

scope_begin() ->
    Stack = case get(?SCOPE) of undefined -> []; S -> S end,
    put(?SCOPE, [[] | Stack]),
    nil.

scope_end() ->
    case get(?SCOPE) of
        [Names | Rest] ->
            put(?SCOPE, Rest),
            lists:reverse(Names);
        _ ->
            []
    end.

note(Name) ->
    case get(?SCOPE) of
        [Names | Rest] -> put(?SCOPE, [[Name | Names] | Rest]);
        _ -> ok
    end,
    nil.

%% -- Table ownership ---------------------------------------------------------
%%
%% Normal Gleam startup starts the howdy_ui application and its supervised
%% table owner before rendering. Preserve lazy use from a raw Erlang caller
%% by delegating startup to OTP, which serializes concurrent starts and
%% reports failures. There is no detached owner or unbounded acknowledgement.
%%
%% The tables outlive an owner crash (see howdy_ui_cache), but the whole
%% application may be stopping or restarting under a renderer. Retry briefly
%% while the owner is not registered, and run each table access again after a
%% single badarg, which is what a table deleted mid-access raises.

-define(RETRY_FOR, 1000).
-define(RETRY_EVERY, 10).

with_table(Fun) ->
    ensure_table(),
    try Fun()
    catch error:badarg ->
        ensure_table(),
        Fun()
    end.

ensure_table() ->
    ensure_table(erlang:monotonic_time(millisecond) + ?RETRY_FOR).

ensure_table(Deadline) ->
    case ets:whereis(?TABLE) of
        undefined ->
            case application:ensure_all_started(howdy_ui) of
                {ok, _} -> await_owner(Deadline);
                {error, Reason} -> erlang:error({howdy_ui_start_failed, Reason})
            end;
        _ ->
            ok
    end.

await_owner(Deadline) ->
    try gen_server:call(howdy_ui_cache, ready, 5000) of
        ok -> ok
    catch exit:{noproc, _} ->
        case erlang:monotonic_time(millisecond) < Deadline of
            true ->
                timer:sleep(?RETRY_EVERY),
                ensure_table(Deadline);
            false ->
                erlang:error({howdy_ui_start_failed, owner_not_running})
        end
    end.

%% -- Behaviour script --------------------------------------------------------
%%
%% The browser script ships as priv/behaviour.js. It is read from the priv
%% directory the first time a page needs it and then held in persistent_term,
%% so repeated renders never touch the file again. Lazy so `gleam test` and
%% raw Erlang callers work without the application booted.

-define(SOURCE, {howdy_ui, behaviour_source}).

behaviour_source() ->
    case persistent_term:get(?SOURCE, undefined) of
        undefined ->
            Path = behaviour_path(),
            case file:read_file(Path) of
                {ok, Source} ->
                    persistent_term:put(?SOURCE, Source),
                    Source;
                {error, Reason} ->
                    erlang:error({howdy_ui_behaviour_missing, Path, Reason})
            end;
        Source ->
            Source
    end.

behaviour_path() ->
    case code:priv_dir(howdy_ui) of
        {error, bad_name} ->
            erlang:error({howdy_ui_priv_dir_missing, howdy_ui});
        Dir ->
            iolist_to_binary(filename:join(Dir, "behaviour.js"))
    end.

%% The rich text editor's bundle, read once from priv like the behaviour
%% script.
-define(RICH_TEXT, {howdy_ui, rich_text_source}).

rich_text_source() ->
    case persistent_term:get(?RICH_TEXT, undefined) of
        undefined ->
            Path = case code:priv_dir(howdy_ui) of
                {error, bad_name} ->
                    erlang:error({howdy_ui_priv_dir_missing, howdy_ui});
                Dir ->
                    filename:join(Dir, "rich_text.js")
            end,
            case file:read_file(Path) of
                {ok, Source} ->
                    persistent_term:put(?RICH_TEXT, Source),
                    Source;
                {error, Reason} ->
                    erlang:error({howdy_ui_rich_text_missing, Path, Reason})
            end;
        Source ->
            Source
    end.
