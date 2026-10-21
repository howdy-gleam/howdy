-module(howdy_telemetry_json).

%% A logger formatter that writes each log line as one JSON object, with the
%% trace and span ids of the span it was logged in, for log collectors that
%% link logs to traces.

-export([format/2, check_config/1]).

check_config(_Config) ->
    ok.

format(Event = #{level := Level, meta := Meta}, _Config) ->
    Time = maps:get(time, Meta, erlang:system_time(microsecond)),
    Base = #{<<"time">> => list_to_binary(calendar:system_time_to_rfc3339(Time, [{unit, microsecond}, {offset, "Z"}])),
             <<"level">> => atom_to_binary(Level),
             <<"message">> => howdy_telemetry_logs:message(Event)},
    WithTrace = case howdy_telemetry_logs:current_ids() of
        {TraceId, SpanId} ->
            Base#{<<"trace_id">> => iolist_to_binary(io_lib:format("~32.16.0b", [TraceId])),
                  <<"span_id">> => iolist_to_binary(io_lib:format("~16.16.0b", [SpanId]))};
        undefined ->
            Base
    end,
    Full = case Meta of
        #{mfa := {M, F, A}} ->
            WithTrace#{<<"source">> => iolist_to_binary(io_lib:format("~s:~s/~b", [M, F, A]))};
        _ ->
            WithTrace
    end,
    [json:encode(Full), $\n].
