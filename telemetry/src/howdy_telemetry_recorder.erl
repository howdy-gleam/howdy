-module(howdy_telemetry_recorder).
-behaviour(otel_span_processor).

%% A span processor that keeps finished spans in memory for the dev admin,
%% and the tables and queries behind `howdy/telemetry/recorder`.
%%
%% Spans are converted to the Gleam `Span` record as they end, in the
%% process that ends them, and stored under their trace id. A span with no
%% parent, or a parent in another service, is a root: roots are kept in end
%% order and a trace is dropped, with its spans and logs, once more than
%% `Keep` roots have arrived after it. Spans whose root never ends here are
%% swept after a few minutes.

-export([new/1, create_tables/1, sweep/1, on_start/3, on_end/2, force_flush/1]).
-export([traces/2, trace/2, logs/2, recent_logs/2, version/1, clear/1,
         record_log/6]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-define(ORPHAN_AGE_US, 300000000).
-define(MAX_LOGS, 2000).

%% The Gleam `Recorder` is `{recorder, Tables}`; the queries take the tables.
-record(tables, {spans, roots, logs, counter, keep}).

%% The tables belong to a `howdy_telemetry_recorder_owner` under the
%% package's supervisor, so a recorder made in a short-lived process still
%% outlives it. The owner exits with the process that made it, which in an
%% app is `main`. Starting the owner cannot hang: `start_child` returns an
%% error if the owner dies in `init`, and the owner is alive when we ask
%% for its tables, or the call exits.
new(Keep) ->
    case whereis(howdy_telemetry_recorder_sup) of
        undefined -> {ok, _} = application:ensure_all_started(howdy_telemetry);
        _ -> ok
    end,
    {ok, Owner} = howdy_telemetry_recorder_sup:start_owner(self(), Keep),
    howdy_telemetry_recorder_owner:tables(Owner).

%% Called by the owner, so the tables are its.
create_tables(Keep) ->
    #tables{
        spans = ets:new(howdy_telemetry_spans, [duplicate_bag, public, {write_concurrency, true}]),
        roots = ets:new(howdy_telemetry_roots, [ordered_set, public]),
        logs = ets:new(howdy_telemetry_logs, [ordered_set, public]),
        counter = counters:new(1, []),
        keep = Keep
    }.

%% -- Span processor ---------------------------------------------------------

on_start(_Ctx, Span, _Config) ->
    Span.

on_end(Span = #span{trace_id = TraceId, parent_span_id = Parent,
                    parent_span_is_remote = Remote, kind = Kind, end_time = End},
       #{recorder := {recorder, T}}) ->
    try
        Converted = convert(Span),
        ets:insert(T#tables.spans, {TraceId, Converted}),
        %% The SDK copies a remote parent's is_remote flag to every span
        %% below it, so only a server or consumer span continuing a remote
        %% trace counts as a root.
        Root = Parent =:= undefined orelse
            (Remote =:= true andalso (Kind =:= server orelse Kind =:= consumer)),
        case Root of
            true ->
                ets:insert(T#tables.roots, {{End, TraceId, Span#span.span_id}, Converted}),
                counters:add(T#tables.counter, 1, 1),
                evict(T);
            false ->
                ok
        end,
        true
    catch
        %% The recorder's owner has gone, as happens between tests.
        error:badarg -> dropped
    end;
on_end(_Span, _Config) ->
    dropped.

force_flush(_Config) ->
    ok.

evict(T = #tables{roots = Roots, keep = Keep}) ->
    case ets:info(Roots, size) > Keep of
        true ->
            case ets:first(Roots) of
                '$end_of_table' ->
                    ok;
                Key = {_, TraceId, _} ->
                    ets:delete(Roots, Key),
                    drop_trace(T, TraceId),
                    evict(T)
            end;
        false ->
            ok
    end.

%% Keep the trace while another of its roots is still held, as happens when
%% two requests continue the same remote trace.
drop_trace(#tables{spans = Spans, roots = Roots, logs = Logs}, TraceId) ->
    case ets:match(Roots, {{'_', TraceId, '_'}, '_'}, 1) of
        '$end_of_table' ->
            ets:delete(Spans, TraceId),
            ets:match_delete(Logs, {'_', TraceId, '_', '_', '_', '_'});
        _ ->
            ok
    end.

%% Drop traces with no root that have not grown for a while, such as the
%% children of a span that never ended.
sweep(T = #tables{spans = Spans, roots = Roots}) ->
    Now = erlang:system_time(microsecond),
    Latest = ets:foldl(fun({TraceId, Span}, Acc) ->
                               End = element(7, Span) + element(8, Span),
                               maps:update_with(TraceId, fun(E) -> max(E, End) end, End, Acc)
                       end, #{}, Spans),
    maps:foreach(fun(TraceId, End) ->
                         Rooted = ets:match(Roots, {{'_', TraceId, '_'}, '_'}, 1) =/= '$end_of_table',
                         case not Rooted andalso Now - End > ?ORPHAN_AGE_US of
                             true -> drop_trace(T, TraceId);
                             false -> ok
                         end
                 end, Latest).

%% -- Conversion to the Gleam records ------------------------------------------

convert(#span{trace_id = TraceId, span_id = SpanId, parent_span_id = Parent,
              name = Name, kind = Kind, start_time = Start, end_time = End,
              attributes = Attributes, events = Events, links = Links,
              status = Status, instrumentation_scope = Scope}) ->
    {span,
     hex_trace(TraceId),
     hex_span(SpanId),
     case Parent of
         undefined -> none;
         _ -> {some, hex_span(Parent)}
     end,
     text(Name),
     kind(Kind),
     wall_us(Start),
     erlang:convert_time_unit(End - Start, native, microsecond),
     attributes(Attributes),
     [{event, text(EventName), wall_us(At), attributes(EventAttributes)}
      || #event{system_time_native = At, name = EventName, attributes = EventAttributes} <- otel_events:list(Events)],
     [{hex_trace(LinkTrace), hex_span(LinkSpan)}
      || #link{trace_id = LinkTrace, span_id = LinkSpan} <- otel_links:list(Links)],
     status(Status),
     case Scope of
         #instrumentation_scope{name = ScopeName} when ScopeName =/= undefined -> text(ScopeName);
         _ -> <<>>
     end}.

hex_trace(Id) -> iolist_to_binary(io_lib:format("~32.16.0b", [Id])).
hex_span(Id) -> iolist_to_binary(io_lib:format("~16.16.0b", [Id])).

wall_us(Monotonic) ->
    erlang:convert_time_unit(Monotonic + erlang:time_offset(), native, microsecond).

kind(Kind) when Kind =:= server; Kind =:= client; Kind =:= producer; Kind =:= consumer -> Kind;
kind(_) -> internal.

status(#status{code = ?OTEL_STATUS_ERROR, message = Message}) -> {failed, text(Message)};
status(#status{code = ?OTEL_STATUS_OK}) -> succeeded;
status(_) -> unset.

attributes(undefined) ->
    [];
attributes(Attributes) ->
    lists:sort([{text(K), value(V)} || {K, V} <- maps:to_list(otel_attributes:map(Attributes))]).

value(V) when is_binary(V) -> {text, V};
value(V) when is_boolean(V) -> {boolean, V};
value(V) when is_atom(V) -> {text, atom_to_binary(V)};
value(V) when is_integer(V) -> {integer, V};
value(V) when is_float(V) -> {number, V};
value(V) when is_list(V) -> {many, [value(X) || X <- V]};
value(V) -> {text, iolist_to_binary(io_lib:format("~0tp", [V]))}.

text(V) when is_binary(V) -> V;
text(V) when is_atom(V) -> atom_to_binary(V);
text(V) -> unicode:characters_to_binary(io_lib:format("~0tp", [V])).

%% -- Queries ----------------------------------------------------------------

%% The newest roots first, each with how many spans its trace has and how
%% many of them failed.
traces(T, Limit) ->
    newest(T, ets:last(T#tables.roots), Limit, []).

newest(_T, '$end_of_table', _Limit, Acc) ->
    lists:reverse(Acc);
newest(_T, _Key, 0, Acc) ->
    lists:reverse(Acc);
newest(T, Key = {_, TraceId, _}, Limit, Acc) ->
    Next = ets:prev(T#tables.roots, Key),
    case ets:lookup(T#tables.roots, Key) of
        [{_, Root}] ->
            Spans = [S || {_, S} <- ets:lookup(T#tables.spans, TraceId)],
            Failed = length([S || S <- Spans, is_tuple(element(12, S))]),
            newest(T, Next, Limit - 1, [{trace, Root, length(Spans), Failed} | Acc]);
        [] ->
            newest(T, Next, Limit, Acc)
    end.

%% Every span of a trace, earliest first.
trace(T, TraceId) ->
    case ets:lookup(T#tables.spans, trace_key(TraceId)) of
        [] -> {error, nil};
        Found -> {ok, lists:keysort(7, [S || {_, S} <- Found])}
    end.

trace_key(Hex) ->
    try binary_to_integer(Hex, 16) catch error:badarg -> undefined end.

logs(T, TraceId) ->
    Key = trace_key(TraceId),
    [log_record(L) || L <- ets:match_object(T#tables.logs, {'_', Key, '_', '_', '_', '_'})].

recent_logs(T, Limit) ->
    last_logs(T#tables.logs, ets:last(T#tables.logs), Limit, []).

last_logs(_Tab, '$end_of_table', _Limit, Acc) -> Acc;
last_logs(_Tab, _Key, 0, Acc) -> Acc;
last_logs(Tab, Key, Limit, Acc) ->
    [L] = ets:lookup(Tab, Key),
    last_logs(Tab, ets:prev(Tab, Key), Limit - 1, [log_record(L) | Acc]).

log_record({_Key, TraceId, SpanId, At, Level, Message}) ->
    {log, At, atom_to_binary(Level), Message,
     case TraceId of undefined -> none; _ -> {some, hex_trace(TraceId)} end,
     case SpanId of undefined -> none; _ -> {some, hex_span(SpanId)} end}.

%% Goes up by one whenever a trace is recorded, so a page can tell whether
%% it has anything new to show.
version(T) ->
    counters:get(T#tables.counter, 1).

clear(T) ->
    ets:delete_all_objects(T#tables.spans),
    ets:delete_all_objects(T#tables.roots),
    ets:delete_all_objects(T#tables.logs),
    counters:add(T#tables.counter, 1, 1),
    nil.

record_log({recorder, T}, TraceId, SpanId, At, Level, Message) ->
    try
        Logs = T#tables.logs,
        ets:insert(Logs, {erlang:unique_integer([monotonic]), TraceId, SpanId, At, Level, Message}),
        case ets:info(Logs, size) > ?MAX_LOGS of
            true -> ets:delete(Logs, ets:first(Logs));
            false -> ok
        end
    catch
        error:badarg -> ok
    end.
