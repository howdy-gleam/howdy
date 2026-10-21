-module(howdy_telemetry_ffi).
-export([idle/0, start/5, flush/0, getenv/1, check_sdk_shape/0]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(HANDLER, howdy_telemetry).
-define(FORMATTER_KEY, {?MODULE, default_formatter}).

%% Stop the SDK application, whether it is the one that started at boot or
%% the one `start` configured, and fall back to the API's no-op tracer,
%% exactly as if no SDK were installed: nothing is recorded or sent, and a
%% trace arriving from another service passes through untouched rather
%% than being marked as not sampled.
idle() ->
    _ = logger:remove_handler(?HANDLER),
    restore_formatter(),
    _ = application:stop(opentelemetry),
    forget_tracers(),
    true = opentelemetry:set_default_tracer({otel_tracer_noop, []}),
    nil.

%% Exporters arrive as the Gleam constructors of `howdy/telemetry.Exporter`:
%% `{otlp, Endpoint, Headers}` and `{record, Recorder}`. Ratio is an option.
start(Service, Attributes, Exporters, Ratio, JsonLogs) ->
    case os:getenv("OTEL_SDK_DISABLED") of
        "true" ->
            idle(),
            {ok, nil};
        _ ->
            Processors = [processor(Exporter) || Exporter <- Exporters],
            application:set_env(opentelemetry, processors, Processors),
            application:set_env(opentelemetry, sampler, sampler(Ratio)),
            application:set_env(opentelemetry, resource, resource(Service, Attributes)),
            Recorders = [Recorder || {record, Recorder} <- Exporters],
            case restart_sdk() of
                ok ->
                    logs(Recorders),
                    json_logs(JsonLogs),
                    {ok, nil};
                {error, Reason} ->
                    {error, unicode:characters_to_binary(io_lib:format("~0tp", [Reason]))}
            end
    end.

processor({otlp, Endpoint, Headers}) ->
    Config0 = #{protocol => http_protobuf},
    Config1 = case Endpoint of
        {some, Url} -> Config0#{endpoints => [binary_to_list(Url)]};
        none -> Config0
    end,
    Config = case Headers of
        [] -> Config1;
        _ -> Config1#{headers => [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers]}
    end,
    {otel_batch_processor, #{exporter => {opentelemetry_exporter, Config}}};
processor({record, Recorder}) ->
    {howdy_telemetry_recorder, #{recorder => Recorder}}.

%% Parent based, so a request that arrives already sampled, or not, by the
%% service that called it keeps that decision.
sampler(none) ->
    {parent_based, #{root => always_on}};
sampler({some, Ratio}) ->
    {parent_based, #{root => {trace_id_ratio_based, Ratio}}}.

%% The SDK's resource detectors read this app env and merge it over what
%% they detect. OTEL_SERVICE_NAME, when set, wins over the name given in
%% code, so one build can report under different names in different places;
%% the detector gives it that precedence itself.
resource(Service, Attributes) ->
    [{'service.name', Service} | [{binary_to_atom(K), V} || {K, V} <- Attributes]].

%% The SDK's documented way to reconfigure is to change its app env and
%% restart it: it reads the env in `opentelemetry_app:start`, builds the
%% global tracer provider from it and makes that provider the default
%% tracer. Spans open across the restart are lost, which is why `start`
%% belongs early in `main`.
restart_sdk() ->
    _ = application:stop(opentelemetry),
    forget_tracers(),
    case application:ensure_all_started(opentelemetry) of
        {ok, _} -> ok;
        {error, Reason} -> {error, Reason}
    end.

%% -- The SDK's private shape -------------------------------------------------
%%
%% Tracers hold their provider's sampler and processors, and the API caches
%% one per application in persistent_term, under a key layout the API does
%% not expose. There is no public way to drop that cache, and the SDK does
%% not drop it when it restarts, so an application's tracer would keep
%% pointing at the old provider. This is the only place that depends on
%% the layout; `check_sdk_shape` proves it at boot.
-define(TRACER_KEY(Name), {opentelemetry, ?GLOBAL_TRACER_PROVIDER_NAME, tracer, Name}).

forget_tracers() ->
    [persistent_term:erase(Key)
     || {Key = ?TRACER_KEY(Name), _} <- persistent_term:get(),
        Name =/= '$__default_tracer'],
    ok.

%% Set a tracer through the public API and check it landed where
%% `forget_tracers` looks. Fails the boot of `howdy_telemetry` with a
%% message naming the problem if the API has changed its layout.
check_sdk_shape() ->
    Probe = howdy_telemetry_probe,
    Tracer = {otel_tracer_noop, []},
    true = opentelemetry:set_tracer(Probe, Tracer),
    Key = ?TRACER_KEY({Probe, <<>>, undefined}),
    case persistent_term:get(Key, missing) of
        Tracer ->
            persistent_term:erase(Key),
            ok;
        Found ->
            error({howdy_telemetry,
                   "opentelemetry_api no longer caches tracers in persistent_term "
                   "under {opentelemetry, Provider, tracer, Name}; update "
                   "howdy_telemetry_ffi:forget_tracers/0 to match the installed version",
                   #{expected_key => Key, found => Found}})
    end.

%% -- Logging -----------------------------------------------------------------

logs(Recorders) ->
    _ = logger:remove_handler(?HANDLER),
    ok = logger:add_handler(?HANDLER, howdy_telemetry_logs,
                            #{level => all,
                              config => #{recorders => Recorders}}).

%% Remember the formatter `json_logs` replaces, so `idle` can put it back.
json_logs(false) ->
    ok;
json_logs(true) ->
    case logger:get_handler_config(default) of
        {ok, #{formatter := {howdy_telemetry_json, _}}} ->
            ok;
        {ok, #{formatter := Previous}} ->
            persistent_term:put(?FORMATTER_KEY, Previous),
            _ = logger:update_handler_config(default, formatter, {howdy_telemetry_json, #{}}),
            ok;
        _ ->
            ok
    end.

restore_formatter() ->
    case persistent_term:get(?FORMATTER_KEY, undefined) of
        undefined ->
            ok;
        Previous ->
            persistent_term:erase(?FORMATTER_KEY),
            case logger:get_handler_config(default) of
                {ok, #{formatter := {howdy_telemetry_json, _}}} ->
                    _ = logger:update_handler_config(default, formatter, Previous),
                    ok;
                _ ->
                    ok
            end
    end.

flush() ->
    _ = otel_tracer_provider:force_flush(),
    nil.

%% An empty variable counts as unset, as the OpenTelemetry spec asks.
getenv(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        "" -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.
