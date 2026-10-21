-module(howdy_trace_ffi).
-export([identity/1, with_span/6, set_attributes/1, add_event/2, set_error/1,
         is_recording/0, current_ids/0, make_link/3, inject/1,
         current_context/0, with_context/2, update_name/1]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

%% Everything here goes through opentelemetry_api, which does nothing until
%% an SDK such as the one howdy_telemetry starts is running.

identity(X) -> X.

%% Kind arrives as the Gleam constructor, which is already the atom the API
%% expects: internal, server, client, producer or consumer.
with_span(Name, Kind, Attributes, Links, Headers, Run) ->
    Current = otel_ctx:get_current(),
    Ctx = case Headers of
        [] -> Current;
        _ -> otel_propagator_text_map:extract_to(Current, Headers)
    end,
    %% Gleam leaves Erlang modules out of the .app file, so look the tracer
    %% up by a Gleam module to have spans attributed to the howdy package.
    Tracer = opentelemetry:get_application_tracer('howdy@trace'),
    Opts = #{kind => Kind,
             attributes => maps:from_list(Attributes),
             links => Links},
    otel_tracer:with_span(Ctx, Tracer, Name, Opts, fun(SpanCtx) ->
        try
            Run()
        catch
            Class:Reason:Stacktrace ->
                otel_span:record_exception(SpanCtx, Class, Reason, Stacktrace, #{}),
                otel_span:set_status(SpanCtx, error, describe(Class, Reason)),
                erlang:raise(Class, Reason, Stacktrace)
        end
    end).

%% Gleam's panic, todo and let assert raise a map with a message.
describe(error, #{message := Message}) when is_binary(Message) ->
    Message;
describe(Class, Reason) ->
    unicode:characters_to_binary(io_lib:format("~p: ~0tp", [Class, Reason])).

set_attributes(Attributes) ->
    otel_span:set_attributes(otel_tracer:current_span_ctx(), maps:from_list(Attributes)),
    nil.

add_event(Name, Attributes) ->
    otel_span:add_event(otel_tracer:current_span_ctx(), Name, maps:from_list(Attributes)),
    nil.

set_error(Message) ->
    otel_span:set_status(otel_tracer:current_span_ctx(), error, Message),
    nil.

is_recording() ->
    otel_span:is_recording(otel_tracer:current_span_ctx()).

%% Only sampled spans have ids worth showing: an unsampled trace is never
%% recorded anywhere, so there is nothing to look up.
current_ids() ->
    case otel_tracer:current_span_ctx() of
        SpanCtx = #span_ctx{trace_flags = Flags} when Flags band 1 =:= 1 ->
            case otel_span:is_valid(SpanCtx) of
                true ->
                    {ok, {otel_span:hex_trace_id(SpanCtx), otel_span:hex_span_id(SpanCtx)}};
                false ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

make_link(Trace, Span, _Flags) ->
    try
        TraceId = binary_to_integer(Trace, 16),
        SpanId = binary_to_integer(Span, 16),
        case TraceId =/= 0 andalso SpanId =/= 0 of
            true -> {ok, opentelemetry:link(TraceId, SpanId, [], otel_tracestate:new())};
            false -> {error, nil}
        end
    catch
        error:badarg -> {error, nil}
    end.

inject(Headers) ->
    otel_propagator_text_map:inject(Headers).

current_context() ->
    otel_ctx:get_current().

with_context(Ctx, Run) ->
    Token = otel_ctx:attach(Ctx),
    try
        Run()
    after
        otel_ctx:detach(Token)
    end.

update_name(Name) ->
    otel_span:update_name(otel_tracer:current_span_ctx(), Name),
    nil.
