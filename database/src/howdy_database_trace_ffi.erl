-module(howdy_database_trace_ffi).
-export([query_start/0, query_end/3]).

%% Gloo reports a query as a start event and an end or error event, both in
%% the process running it. Remember when each started, on a per-process
%% stack, and open the span when it ends, backdated to the start.
%%
%% A query only gets a span inside a span that is being recorded. Without
%% that rule every background poll, such as the admin's live grid, would be
%% a trace of its own.

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(STACK, howdy_database_query_starts).

query_start() ->
    Start = case otel_span:is_recording(otel_tracer:current_span_ctx()) of
        true -> opentelemetry:timestamp();
        false -> skip
    end,
    put(?STACK, [Start | stack()]),
    nil.

%% Outcome is `{ok, Rows}` or `{error, nil}`. A driver's error text can hold
%% the values of the row being written, so it is not recorded.
query_end(System, Sql, Outcome) ->
    case stack() of
        [] ->
            nil;
        [skip | Rest] ->
            put(?STACK, Rest),
            nil;
        [Start | Rest] ->
            put(?STACK, Rest),
            record(System, Sql, Start, Outcome),
            nil
    end.

stack() ->
    case get(?STACK) of
        undefined -> [];
        Stack -> Stack
    end.

record(System, Sql, Start, Outcome) ->
    Tracer = opentelemetry:get_application_tracer('howdy@database'),
    {Operation, Target} = summary(Sql),
    Name = case Target of
        undefined -> Operation;
        _ -> <<Operation/binary, " ", Target/binary>>
    end,
    Attributes0 = #{<<"db.system.name">> => System,
                    <<"db.query.text">> => Sql,
                    <<"db.operation.name">> => Operation},
    Attributes1 = case Target of
        undefined -> Attributes0;
        _ -> Attributes0#{<<"db.collection.name">> => Target}
    end,
    Attributes = case Outcome of
        {ok, Rows} -> Attributes1#{<<"db.response.returned_rows">> => Rows};
        {error, nil} -> Attributes1#{<<"error.type">> => <<"database_error">>}
    end,
    SpanCtx = otel_tracer:start_span(Tracer, Name, #{kind => client,
                                                     start_time => Start,
                                                     attributes => Attributes}),
    case Outcome of
        {error, nil} -> otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"database operation failed">>);
        _ -> ok
    end,
    otel_span:end_span(SpanCtx).

%% The operation and the table it works on, for the span's name, as
%% OpenTelemetry's database conventions ask: `SELECT app_notes`.
summary(Sql) ->
    case re:run(Sql, "^\\s*(\\w+)", [{capture, all_but_first, binary}]) of
        {match, [Word]} ->
            Operation = string:uppercase(Word),
            {Operation, target(Operation, Sql)};
        nomatch ->
            {<<"QUERY">>, undefined}
    end.

target(Operation, Sql) ->
    Pattern = case Operation of
        <<"SELECT">> -> "\\bFROM\\s+\"?([\\w.]+)";
        <<"DELETE">> -> "\\bFROM\\s+\"?([\\w.]+)";
        <<"INSERT">> -> "\\bINTO\\s+\"?([\\w.]+)";
        <<"UPDATE">> -> "^\\s*UPDATE\\s+\"?([\\w.]+)";
        _ -> undefined
    end,
    case Pattern of
        undefined ->
            undefined;
        _ ->
            case re:run(Sql, Pattern, [caseless, {capture, all_but_first, binary}]) of
                {match, [Table]} -> Table;
                nomatch -> undefined
            end
    end.
