-module(howdy_telemetry_logs).

%% A logger handler that ties log lines to traces. It runs in the process
%% that logs, so it sees that process's current span:
%%
%% - Warnings and worse become `log` events on the current span, so they
%%   show up in any tracing backend next to the work that caused them.
%% - A crash report from a process with no span of its own becomes a failed
%%   `process crash` span, so crashes outside requests are not lost.
%% - Every line goes to the recorders, if any, for the dev admin.

-export([log/2, message/1, current_ids/0]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(MAX_MESSAGE, 4096).
-define(MAX_REASON, 512).
-define(REASON_DEPTH, 5).

%% A crash report carries the process's state, mailbox, dictionary and the
%% arguments of the call that failed, any of which may hold a secret. The
%% full text goes only to the recorders, for the dev admin; what reaches a
%% span, and so an exporter, is the exception class and a shallow print of
%% the reason.
%%
%% The handler is installed at level `all`, so most lines that reach it
%% have nowhere to go: no span to attach to and no recorder to keep them.
%% Those return before the message is formatted.
log(Event = #{level := Level}, #{config := #{recorders := []}}) ->
    case current_ids() of
        undefined ->
            _ = crash_span(Event);
        Ids ->
            case logger:compare_levels(Level, warning) of
                lt -> ok;
                _ -> span_log(Event, Ids)
            end
    end,
    ok;
log(Event = #{level := Level, meta := Meta}, #{config := #{recorders := Recorders}}) ->
    {Message, {TraceId, SpanId}} = case current_ids() of
        undefined -> {message(Event), crash_span(Event)};
        Ids -> span_log(Event, Ids)
    end,
    At = maps:get(time, Meta, erlang:system_time(microsecond)),
    [howdy_telemetry_recorder:record_log(R, TraceId, SpanId, At, Level, Message) || R <- Recorders],
    ok.

%% Attach a warning or worse to the current span as an event, and hand
%% back the formatted message for the recorders.
span_log(Event = #{level := Level}, Ids) ->
    Message = message(Event),
    span_event(Level, case exception(Event) of
                          undefined -> Message;
                          {Class, Reason} -> <<Class/binary, ": ", Reason/binary>>
                      end),
    {Message, Ids}.

message(Event) ->
    Formatted = logger_formatter:format(Event, #{single_line => true, template => [msg]}),
    Binary = unicode:characters_to_binary(Formatted),
    case byte_size(Binary) > ?MAX_MESSAGE of
        true -> <<(string:slice(Binary, 0, ?MAX_MESSAGE))/binary, "…"/utf8>>;
        false -> Binary
    end.

%% The ids of the current span, if it is being recorded.
current_ids() ->
    case otel_tracer:current_span_ctx() of
        SpanCtx = #span_ctx{trace_id = TraceId, span_id = SpanId} ->
            case otel_span:is_recording(SpanCtx) of
                true -> {TraceId, SpanId};
                false -> undefined
            end;
        _ ->
            undefined
    end.

span_event(Level, Message) ->
    case logger:compare_levels(Level, warning) of
        lt -> ok;
        _ ->
            otel_span:add_event(otel_tracer:current_span_ctx(), <<"log">>,
                                #{<<"log.severity">> => atom_to_binary(Level),
                                  <<"log.message">> => Message})
    end.

crash_span(Event = #{meta := #{error_logger := #{type := crash_report}}}) ->
    {Class, Reason} = case exception(Event) of
        undefined -> {<<"exit">>, <<"process crashed">>};
        Found -> Found
    end,
    Tracer = opentelemetry:get_application_tracer('howdy@telemetry'),
    SpanCtx = otel_tracer:start_span(otel_ctx:new(), Tracer, <<"process crash">>,
                                     #{attributes => #{<<"exception.type">> => Class,
                                                       <<"exception.message">> => Reason}}),
    otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"process crashed">>),
    otel_span:end_span(SpanCtx),
    case otel_span:is_recording(SpanCtx) orelse SpanCtx#span_ctx.trace_flags band 1 =:= 1 of
        true -> {SpanCtx#span_ctx.trace_id, SpanCtx#span_ctx.span_id};
        false -> {undefined, undefined}
    end;
crash_span(_Event) ->
    {undefined, undefined}.

%% The class and reason of a `proc_lib` crash report, as short binaries.
%% The stack trace that `gen_server` and friends fold into the exit reason
%% is dropped with the rest of the report: its frames carry call arguments.
exception(#{meta := #{error_logger := #{type := crash_report}},
            msg := {report, #{report := [Report | _]}}}) when is_list(Report) ->
    case lists:keyfind(error_info, 1, Report) of
        {error_info, {Class, Reason, _Stack}} ->
            {atom_to_binary(Class), reason(Reason)};
        _ ->
            undefined
    end;
exception(_Event) ->
    undefined.

reason({Reason, [Frame | _]}) when tuple_size(Frame) =:= 4, is_atom(element(1, Frame)), is_atom(element(2, Frame)) ->
    reason(Reason);
reason(Reason) ->
    Printed = unicode:characters_to_binary(io_lib:format("~0tP", [Reason, ?REASON_DEPTH])),
    case byte_size(Printed) > ?MAX_REASON of
        true -> <<(string:slice(Printed, 0, ?MAX_REASON))/binary, "…"/utf8>>;
        false -> Printed
    end.
